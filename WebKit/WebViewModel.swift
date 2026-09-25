//
//  WebViewModel.swift
//  Thinspace
//

import AppKit
import Foundation
import Observation
import WebKit

final class ConsoleLogHandler: NSObject, WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        if let body = message.body as? String {
            print("[WebView] \(body)")
        }
    }
}

final class ConversationStateHandler: NSObject, WKScriptMessageHandler {
    weak var model: WebViewModel?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let inConversation = body["inConversation"] as? Bool else { return }
        // WKScriptMessageHandler is main-actor in the SDK, so no hop is needed.
        // Identity guard matches the KVO callbacks: a message enqueued against
        // an outgoing WebView during a provider switch must not be applied to
        // the new session. Assumes a single handler-bearing WebView — a future
        // popup/auth window's messages would be silently swallowed here.
        guard let model, message.webView === model.wkWebView else { return }
        model.handleConversationState(inConversation)
    }
}

final class PrivateChatStateHandler: NSObject, WKScriptMessageHandler {
    weak var model: WebViewModel?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              let inPrivateChat = body["inPrivateChat"] as? Bool else { return }
        // Same identity guard as ConversationStateHandler, for the same reason.
        guard let model, message.webView === model.wkWebView else { return }
        model.handlePrivateChatState(inPrivateChat)
    }
}

/// Owns the single active provider session. Provider login state lives in a
/// separate persistent WebKit data store, while inactive providers have no
/// WKWebView or WebContent process.
@MainActor
@Observable
final class WebViewModel {
    /// Five minutes trades more cold summons — a full provider page reload —
    /// for not keeping a page that can reach a gigabyte resident while nothing
    /// is on screen. A visible window never suspends, whatever this value.
    private static let inactivityTimeout: TimeInterval = 5 * 60

    /// Stable identity for the provider's persistent WebKit store. Internal so
    /// the app's tests can verify separation without exposing storage publicly.
    /// A `switch` rather than a lookup table so adding a provider fails to
    /// compile instead of trapping the first time that provider is selected.
    nonisolated static func dataStoreIdentifier(for provider: LLMProvider) -> UUID {
        switch provider {
        case .claude: return UUID(uuidString: "A1C4A7DE-9F3E-4B48-96C5-7C680CB57401")!
        case .gemini: return UUID(uuidString: "6E3B9C21-D4F8-4A75-AD12-8519B7E26002")!
        case .chatgpt: return UUID(uuidString: "C8F2D5A4-7B19-4E63-AB20-94D7F6103003")!
        }
    }

    private(set) var provider: LLMProvider
    var capabilities: ProviderCapabilities { provider.capabilities }

    /// Changes identity whenever the provider changes or an idle session resumes.
    private(set) var wkWebView: WKWebView
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isAtHome = true
    private(set) var isLoading = true
    private(set) var isInConversation = false
    private(set) var isInPrivateChat = false
    private(set) var isSuspended = false

    var onConversationStarted: (() -> Void)?
    var onPrivateChatStateChanged: ((Bool) -> Void)?
    /// Fired after an idle suspension completes, so the owner can release
    /// resources that only matter while the session is live (the Chat Bar
    /// panel). Deliberately a callback: the model must not reach into
    /// AppCoordinator and pull window construction into itself.
    var onDidSuspend: (() -> Void)?

    private var adapter: any ProviderAdapter
    private let conversationStateHandler: ConversationStateHandler
    private let privateChatStateHandler: PrivateChatStateHandler
    private var backObserver: NSKeyValueObservation?
    private var forwardObserver: NSKeyValueObservation?
    private var urlObserver: NSKeyValueObservation?
    private var loadingObserver: NSKeyValueObservation?
    private var inactivityTimer: Timer?
    private var occlusionObserver: NSObjectProtocol?
    private var lastActivity = Date()
    private var suspendedURL: URL?
    private var pendingPrivateChatProvider: LLMProvider?

    /// Main window and Chat Bar both retain a representable. These records
    /// track which containers last displayed this model — without retaining
    /// them — and let the model push a replacement WebView to every live host.
    ///
    /// The broadcast matters for memory: both containers outlive every
    /// provider switch, and whichever one is off-screen would otherwise keep
    /// the previous `WKWebView` — and its WebContent process — alive until
    /// SwiftUI happened to re-run `updateNSView` on a hidden window.
    ///
    /// Entries are weak and filtered on access, so a deallocated container
    /// needs no explicit removal. `@ObservationIgnored` is required: `claimHost`
    /// runs while SwiftUI is attaching the view, and mutating observed state
    /// there would invalidate mid-update.
    @ObservationIgnored
    private var hosts: [WeakBrowserContainer] = []
    @ObservationIgnored
    private var hostOwner: WeakBrowserContainer?
    /// A summon that races a page load parks its composer actions here; the
    /// load completion delivers them, since the in-page bridges do not exist
    /// until the provider document has committed. Covers the idle-resume path,
    /// where the first ⌥Space otherwise silently dropped the captured text.
    private var pendingSelection: CapturedSelection?
    private var pendingFocus = false

    init(provider requestedProvider: LLMProvider? = nil) {
        let storedProvider = UserDefaults.standard
            .string(forKey: LLMProvider.defaultsKey)
            .flatMap(LLMProvider.init(rawValue:))
        let selectedProvider = requestedProvider ?? storedProvider ?? .claude
        let selectedAdapter = ProviderAdapters.adapter(for: selectedProvider)
        let conversationHandler = ConversationStateHandler()
        let privateChatHandler = PrivateChatStateHandler()

        provider = selectedProvider
        adapter = selectedAdapter
        conversationStateHandler = conversationHandler
        privateChatStateHandler = privateChatHandler
        wkWebView = Self.makeFullWebView(
            provider: selectedProvider,
            adapter: selectedAdapter,
            conversationStateHandler: conversationHandler,
            privateChatStateHandler: privateChatHandler
        )

        conversationStateHandler.model = self
        privateChatStateHandler.model = self
        UserDefaults.standard.set(selectedProvider.rawValue, forKey: LLMProvider.defaultsKey)
        setupObservers()
        loadHome()
        resetInactivityTimer()
        observeOcclusionChanges()
    }

    // In practice this never runs: the one instance is owned by
    // AppCoordinator.shared for the process lifetime. The model is only ever
    // referenced from the main actor, so a hypothetical last release happens
    // there too; assumeIsolated documents and enforces that.
    deinit {
        MainActor.assumeIsolated {
            inactivityTimer?.invalidate()
            if let occlusionObserver {
                NotificationCenter.default.removeObserver(occlusionObserver)
            }
            teardownObservers()
            detachAndStop(wkWebView)
        }
    }

    // MARK: - Provider session

    /// Tears down the current provider's only WebView, then creates the selected
    /// provider at its home page. Only cookies/site data survive via its data store.
    func switchProvider(to newProvider: LLMProvider) {
        resetInactivityTimer()
        guard newProvider != provider else {
            resumeIfSuspended()
            return
        }

        pendingPrivateChatProvider = nil
        suspendedURL = nil
        teardownObservers()
        detachAndStop(wkWebView)

        provider = newProvider
        adapter = ProviderAdapters.adapter(for: newProvider)
        UserDefaults.standard.set(newProvider.rawValue, forKey: LLMProvider.defaultsKey)
        isSuspended = false
        resetNavigationState(loading: true)
        wkWebView = Self.makeFullWebView(
            provider: newProvider,
            adapter: adapter,
            conversationStateHandler: conversationStateHandler,
            privateChatStateHandler: privateChatStateHandler
        )
        setupObservers()
        notifyHostsOfWebViewChange()
        loadHome()
    }

    /// Removes website records for every provider store and rebuilds the
    /// active session so no authenticated in-memory page survives the reset.
    func clearAllWebsiteData(completion: @escaping () -> Void = {}) {
        let group = DispatchGroup()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()

        for provider in LLMProvider.allCases {
            group.enter()
            Self.transientWebsiteDataStore(for: provider).removeData(
                ofTypes: dataTypes,
                modifiedSince: .distantPast
            ) {
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            if let self {
                self.rebuildActiveSessionAndLoadHome()
            }
            completion()
        }
    }

    // MARK: - Navigation and provider actions

    func loadHome() {
        resumeIfSuspended()
        pendingPrivateChatProvider = nil
        isAtHome = true
        canGoBack = false
        isInConversation = false
        handlePrivateChatState(false)
        wkWebView.load(URLRequest(url: adapter.homeURL))
    }

    // Navigating away abandons a private-chat request that was waiting for the
    // home page to finish loading. Leaving it armed would activate the private
    // chat unprompted the next time the user happened to reach a home surface.

    func goBack() {
        resumeIfSuspended()
        guard wkWebView.canGoBack else { return }
        pendingPrivateChatProvider = nil
        isAtHome = false
        wkWebView.goBack()
    }

    func goForward() {
        resumeIfSuspended()
        guard wkWebView.canGoForward else { return }
        pendingPrivateChatProvider = nil
        wkWebView.goForward()
    }

    func reload() {
        resumeIfSuspended()
        pendingPrivateChatProvider = nil
        wkWebView.reload()
    }

    func openNewChat() {
        resumeIfSuspended()
        pendingPrivateChatProvider = nil
        let wasInPrivateChat = isInPrivateChat
        handlePrivateChatState(false)
        if wasInPrivateChat {
            adapter.exitPrivateChat(in: wkWebView)
        } else {
            adapter.openNewChat(in: wkWebView)
        }
    }

    func openPrivateChat() {
        resumeIfSuspended()
        guard capabilities.contains(.privateChat) else { return }
        guard !isInPrivateChat else { return }

        if adapter.privateChatStartsAtHome {
            if let url = wkWebView.url,
               adapter.isHomeSurface(url),
               !wkWebView.isLoading {
                adapter.activatePrivateChat(in: wkWebView)
            } else {
                pendingPrivateChatProvider = provider
                isAtHome = true
                canGoBack = false
                wkWebView.load(URLRequest(url: adapter.homeURL))
            }
        } else {
            adapter.activatePrivateChat(in: wkWebView)
        }
    }

    func toggleSidebar() {
        resumeIfSuspended()
        guard capabilities.contains(.sidebar) else { return }
        adapter.toggleSidebar(in: wkWebView)
    }

    func openNewProject() {
        resumeIfSuspended()
        guard capabilities.contains(.newProject) else { return }
        adapter.openNewProject(in: wkWebView)
    }

    func loadProjects() {
        resumeIfSuspended()
        guard capabilities.contains(.projects), let url = adapter.projectsURL() else { return }
        handlePrivateChatState(false)
        wkWebView.load(URLRequest(url: url))
    }

    func loadClaudeCode() {
        resumeIfSuspended()
        guard capabilities.contains(.claudeCode), let url = adapter.codeURL() else { return }
        handlePrivateChatState(false)
        wkWebView.load(URLRequest(url: url))
    }

    func openProviderSettings() {
        resumeIfSuspended()
        guard capabilities.contains(.providerSettings) else { return }
        adapter.openProviderSettings(in: wkWebView)
    }

    func findInPage(
        _ query: String,
        forward: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        guard !query.isEmpty else {
            completion(false)
            return
        }
        resumeIfSuspended()
        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.caseSensitive = false
        configuration.wraps = true
        wkWebView.find(query, configuration: configuration) { result in
            completion(result.matchFound)
        }
    }

    func focusComposer() {
        resumeIfSuspended()
        if wkWebView.url == nil || wkWebView.isLoading {
            pendingFocus = true
            return
        }
        adapter.focusComposer(in: wkWebView)
    }

    // MARK: - Captured selection

    /// Adds the captured selection to the composer, leaving the caret above it.
    func insertCapturedSelection(_ selection: CapturedSelection) {
        if wkWebView.url == nil || wkWebView.isLoading {
            pendingSelection = selection
            return
        }
        performInsertCapturedSelection(selection)
    }

    private func performInsertCapturedSelection(_ selection: CapturedSelection) {
        guard let data = try? JSONSerialization.data(withJSONObject: [
            "text": selection.text,
            "source": selection.sourceLabel
        ]), let payload = String(data: data, encoding: .utf8) else { return }

        // Guarded because the bridge is absent until the provider page has
        // loaded, and the WebView may be showing a non-provider page.
        wkWebView.evaluateJavaScript(
            """
            if (window.__aiChatInsertSelection) {
                window.__aiChatInsertSelection(\(payload));
            }
            """,
            completionHandler: nil
        )
    }

    private func flushPendingComposerActions() {
        if pendingFocus {
            pendingFocus = false
            adapter.focusComposer(in: wkWebView)
        }
        if let selection = pendingSelection {
            pendingSelection = nil
            performInsertCapturedSelection(selection)
        }
    }

    // MARK: - Browser policy API

    func shouldOpenExternally(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if ["about", "blob", "data", "javascript"].contains(scheme) { return false }
        guard scheme == "http" || scheme == "https" else { return true }
        return adapter.classify(url) == .external
    }

    func allowsMediaCapture(from host: String) -> Bool {
        adapter.allowsMediaCapture(from: host)
    }

    // MARK: - Conversation state

    func handleConversationState(_ inConversation: Bool) {
        let wasInConversation = isInConversation
        isInConversation = inConversation
        if !wasInConversation && inConversation {
            onConversationStarted?()
        }
    }

    func handlePrivateChatState(_ inPrivateChat: Bool) {
        guard isInPrivateChat != inPrivateChat else { return }
        isInPrivateChat = inPrivateChat
        onPrivateChatStateChanged?(inPrivateChat)
    }

    // MARK: - Inactivity suspension

    func resetInactivityTimer() {
        lastActivity = Date()
        inactivityTimer?.invalidate()
        inactivityTimer = Timer.scheduledTimer(
            withTimeInterval: Self.inactivityTimeout,
            repeats: false
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.suspendIfInactive()
            }
        }
    }

    /// The app becoming fully occluded is the moment suspension is worth
    /// re-checking, so an already-idle session is released then instead of
    /// waiting out the remainder of a timer that would only fire later.
    private func observeOcclusionChanges() {
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue; assumeIsolated keeps the call
            // synchronous instead of deferring it a turn through a Task.
            MainActor.assumeIsolated {
                self?.suspendIfInactive()
            }
        }
    }

    /// A window that is merely ordered-in still reports `isVisible == true`
    /// while it sits behind another app, on another Space, or under Hide.
    /// Occlusion state is what actually reflects whether the page can be seen.
    private var hasObservableWindow: Bool {
        NSApp.windows.contains {
            $0.isVisible
                && !$0.isMiniaturized
                && $0.level <= .floating
                && $0.occlusionState.contains(.visible)
        }
    }

    private func suspendIfInactive() {
        guard !isSuspended else { return }
        guard Date().timeIntervalSince(lastActivity) >= Self.inactivityTimeout else { return }
        guard !hasObservableWindow else {
            resetInactivityTimer()
            return
        }
        suspend()
        onDidSuspend?()
    }

    /// Releases the session when the launch configuration leaves no window on
    /// screen, so a login-item launch does not keep a provider page resident.
    /// Called from AppDelegate only after the main window is provably ordered
    /// out; `hasObservableWindow` re-verifies nothing is on screen.
    func suspendForHiddenLaunch() {
        guard !isSuspended, !hasObservableWindow else { return }
        suspend()
        suspendedURL = nil   // resume must land on homeURL, as a visible launch does
    }

    private func suspend() {
        // Restored on resume so reclaiming memory never costs the user their place.
        suspendedURL = wkWebView.url.flatMap { url in
            url.scheme == "http" || url.scheme == "https" ? url : nil
        }
        isSuspended = true
        pendingPrivateChatProvider = nil
        teardownObservers()
        detachAndStop(wkWebView)
        wkWebView = Self.makeIdleWebView(provider: provider)
        resetNavigationState(loading: false)
        notifyHostsOfWebViewChange()
    }

    func resumeIfSuspended() {
        resetInactivityTimer()
        guard isSuspended else { return }
        isSuspended = false
        let restoredURL = suspendedURL ?? adapter.homeURL
        suspendedURL = nil
        resetNavigationState(loading: true)
        isAtHome = adapter.isHomeSurface(restoredURL)
        // Seeded from the URL so a Chat Bar summoned into a restored
        // conversation is sized before it is presented, instead of expanding
        // over the live page once the load finishes. Routed through the
        // handler, not assigned: a hidden panel ignores the callback and reads
        // the state when it is next prepared, and a visible one still expands.
        // The page's first publish agrees for these paths, so it adds nothing.
        handleConversationState(adapter.isConversationSurface(restoredURL))
        wkWebView = Self.makeFullWebView(
            provider: provider,
            adapter: adapter,
            conversationStateHandler: conversationStateHandler,
            privateChatStateHandler: privateChatStateHandler
        )
        setupObservers()
        wkWebView.load(URLRequest(url: restoredURL))
        notifyHostsOfWebViewChange()
    }

    // MARK: - Shared zoom and user agent

    func zoomIn() {
        resumeIfSuspended()
        setZoom(PageZoom.stepUp(from: wkWebView.pageZoom))
    }

    func zoomOut() {
        resumeIfSuspended()
        setZoom(PageZoom.stepDown(from: wkWebView.pageZoom))
    }

    func resetZoom() {
        resumeIfSuspended()
        setZoom(PageZoom.defaultZoom)
    }

    /// The one write path for zoom: snaps to the ladder, applies, persists.
    func setZoom(_ zoom: Double) {
        let snapped = PageZoom.nearest(to: zoom)
        wkWebView.pageZoom = snapped
        UserDefaults.standard.set(snapped, forKey: UserDefaultsKeys.pageZoom.rawValue)
    }

    // MARK: - WebView lifecycle

    private func rebuildActiveSessionAndLoadHome() {
        teardownObservers()
        detachAndStop(wkWebView)
        isSuspended = false
        pendingPrivateChatProvider = nil
        suspendedURL = nil
        resetNavigationState(loading: true)
        wkWebView = Self.makeFullWebView(
            provider: provider,
            adapter: adapter,
            conversationStateHandler: conversationStateHandler,
            privateChatStateHandler: privateChatStateHandler
        )
        setupObservers()
        notifyHostsOfWebViewChange()
        wkWebView.load(URLRequest(url: adapter.homeURL))
        resetInactivityTimer()
    }

    // MARK: - Host registry

    func registerHost(_ container: BrowserWebViewContainer) {
        hosts = hosts.filter { $0.value != nil && $0.value !== container }
        hosts.append(WeakBrowserContainer(container))
    }

    func claimHost(_ container: BrowserWebViewContainer) {
        registerHost(container)
        hostOwner = WeakBrowserContainer(container)
    }

    func isHostOwner(_ container: BrowserWebViewContainer) -> Bool {
        hostOwner?.value === container
    }

    /// Hands the replacement WebView to every mounted host immediately. Without
    /// this the off-screen host keeps the previous WebView alive until SwiftUI
    /// next re-runs its update, which is not guaranteed to be prompt for a
    /// hidden window. Iterates a local copy: `swapWebView` re-enters the model
    /// (attach → claim → register) and mutates `hosts` mid-broadcast.
    private func notifyHostsOfWebViewChange() {
        let webView = wkWebView
        let entries = hosts.filter { $0.value != nil }
        hosts = entries
        for entry in entries {
            entry.value?.swapWebView(to: webView)
        }
    }

    private func resetNavigationState(loading: Bool) {
        canGoBack = false
        canGoForward = false
        isAtHome = true
        isLoading = loading
        isInConversation = false
        pendingSelection = nil
        pendingFocus = false
        handlePrivateChatState(false)
    }

    private func detachAndStop(_ webView: WKWebView) {
        webView.stopLoading()
        webView.removeFromSuperview()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        let controller = webView.configuration.userContentController
        controller.removeScriptMessageHandler(forName: UserScripts.conversationStateHandler)
        controller.removeScriptMessageHandler(forName: UserScripts.privateChatStateHandler)
        #if DEBUG
        controller.removeScriptMessageHandler(forName: UserScripts.consoleLogHandler)
        #endif
        controller.removeAllUserScripts()
    }

    private static func makeFullWebView(
        provider: LLMProvider,
        adapter: any ProviderAdapter,
        conversationStateHandler: ConversationStateHandler,
        privateChatStateHandler: PrivateChatStateHandler
    ) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore(for: provider)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true

        for script in UserScripts.createAllScripts(for: adapter) {
            configuration.userContentController.addUserScript(script)
        }
        configuration.userContentController.add(
            conversationStateHandler,
            name: UserScripts.conversationStateHandler
        )
        configuration.userContentController.add(
            privateChatStateHandler,
            name: UserScripts.privateChatStateHandler
        )
        #if DEBUG
        configuration.userContentController.add(
            ConsoleLogHandler(),
            name: UserScripts.consoleLogHandler
        )
        #endif

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.allowsMagnification = true

        let savedZoom = UserDefaults.standard.double(forKey: UserDefaultsKeys.pageZoom.rawValue)
        webView.pageZoom = PageZoom.nearest(to: savedZoom)
        return webView
    }

    private static func makeIdleWebView(provider: LLMProvider) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore(for: provider)
        return WKWebView(frame: .zero, configuration: configuration)
    }

    /// Only the active provider's store is cached. Suspend/resume cycles reuse
    /// one store object instead of standing up a second networking session for
    /// the same identifier, while switching providers still drops the previous
    /// store so the provider left behind keeps nothing alive. Main-thread only.
    private static var cachedStore: (provider: LLMProvider, store: WKWebsiteDataStore)?

    private static func websiteDataStore(for provider: LLMProvider) -> WKWebsiteDataStore {
        if let cachedStore, cachedStore.provider == provider {
            return cachedStore.store
        }
        let store = WKWebsiteDataStore(forIdentifier: dataStoreIdentifier(for: provider))
        cachedStore = (provider, store)
        return store
    }

    /// Website data is removed through short-lived stores for the providers that
    /// are not active, so clearing never promotes an inactive provider's store
    /// into the cache.
    private static func transientWebsiteDataStore(
        for provider: LLMProvider
    ) -> WKWebsiteDataStore {
        if let cachedStore, cachedStore.provider == provider {
            return cachedStore.store
        }
        return WKWebsiteDataStore(forIdentifier: dataStoreIdentifier(for: provider))
    }

    private func teardownObservers() {
        backObserver?.invalidate()
        forwardObserver?.invalidate()
        urlObserver?.invalidate()
        loadingObserver?.invalidate()
        backObserver = nil
        forwardObserver = nil
        urlObserver = nil
        loadingObserver = nil
    }

    private func setupObservers() {
        teardownObservers()

        // Change deliveries only. Every caller registers these against a freshly
        // built WKWebView whose state the model has already seeded —
        // resetNavigationState on the rebuild paths, the declared defaults in
        // init — so .initial would only re-assert known values, and for
        // isLoading it would assert the wrong one (a new webview reports false
        // while a load is about to start).
        //
        // Same-value writes are skipped: @Observable's setter notifies
        // unconditionally, and a redundant canGoBack write rebuilds the whole
        // App Scene command tree.
        backObserver = wkWebView.observe(\.canGoBack, options: [.new]) {
            [weak self] webView, _ in
            DispatchQueue.main.async {
                guard let self, webView === self.wkWebView else { return }
                let canGoBack = !self.isAtHome && webView.canGoBack
                if canGoBack != self.canGoBack { self.canGoBack = canGoBack }
            }
        }
        forwardObserver = wkWebView.observe(\.canGoForward, options: [.new]) {
            [weak self] webView, _ in
            DispatchQueue.main.async {
                guard let self, webView === self.wkWebView else { return }
                let canGoForward = webView.canGoForward
                if canGoForward != self.canGoForward {
                    self.canGoForward = canGoForward
                }
            }
        }
        loadingObserver = wkWebView.observe(\.isLoading, options: [.new]) {
            [weak self] webView, _ in
            DispatchQueue.main.async {
                guard let self, webView === self.wkWebView else { return }
                let isLoading = webView.isLoading
                if isLoading != self.isLoading { self.isLoading = isLoading }
                if !webView.isLoading {
                    self.performPendingPrivateChatIfReady()
                    self.flushPendingComposerActions()
                }
            }
        }
        urlObserver = wkWebView.observe(\.url, options: [.new]) {
            [weak self] webView, _ in
            DispatchQueue.main.async {
                guard let self, webView === self.wkWebView, let url = webView.url else { return }
                if url.absoluteString != "about:blank" && !self.isSuspended {
                    self.resetInactivityTimer()
                }
                let atHome = self.adapter.isHomeSurface(url)
                if atHome != self.isAtHome { self.isAtHome = atHome }
                let canGoBack = !atHome && webView.canGoBack
                if canGoBack != self.canGoBack { self.canGoBack = canGoBack }
            }
        }
    }

    private func performPendingPrivateChatIfReady() {
        guard pendingPrivateChatProvider == provider,
              let url = wkWebView.url,
              adapter.isHomeSurface(url) else { return }
        pendingPrivateChatProvider = nil
        adapter.activatePrivateChat(in: wkWebView)
    }
}
