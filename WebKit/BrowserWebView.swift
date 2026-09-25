//
//  BrowserWebView.swift
//  Thinspace
//

import AppKit
import SwiftUI
import WebKit

/// Hosts whichever WebView is currently owned by WebViewModel. A WebView can
/// move between the main window and Chat Bar; ownership tracking prevents an
/// off-screen host from stealing a newly rebuilt WebView during a provider switch.
@MainActor
struct BrowserWebView: NSViewRepresentable {
    let webViewModel: WebViewModel
    /// Recorded, never retained. Reading `wkWebView` during body evaluation is
    /// what registers the Observation dependency that invalidates this host
    /// when the model swaps WebViews; holding the object itself would keep a
    /// suspended or replaced WebView — and its WebContent process — alive
    /// until SwiftUI next re-evaluated a hidden window's body. Do not delete
    /// this property or move the read out of `init`: ChatBarView.body has no
    /// other observable read, so the Chat Bar host would silently stop being
    /// invalidated on provider switch and suspend/resume.
    private let webViewIdentity: ObjectIdentifier

    init(webViewModel: WebViewModel) {
        self.webViewModel = webViewModel
        webViewIdentity = ObjectIdentifier(webViewModel.wkWebView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(webViewModel: webViewModel)
    }

    func makeNSView(context: Context) -> BrowserWebViewContainer {
        BrowserWebViewContainer(
            webView: webViewModel.wkWebView,
            webViewModel: webViewModel,
            coordinator: context.coordinator
        )
    }

    func updateNSView(_ container: BrowserWebViewContainer, context: Context) {
        context.coordinator.webViewModel = webViewModel
        // Compared against the live model value, not the recorded identity: a
        // stale cached view value must not swap the container back to a
        // WebView the model has already moved past.
        let current = webViewModel.wkWebView
        if container.webView !== current {
            container.swapWebView(to: current)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        weak var webViewModel: WebViewModel?
        private var downloadDestinations: [ObjectIdentifier: URL] = [:]
        private var reservedDownloadDestinations: Set<URL> = []

        init(webViewModel: WebViewModel) {
            self.webViewModel = webViewModel
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }

            if navigationAction.shouldPerformDownload {
                decisionHandler(.download)
                return
            }

            // This catches ordinary same-frame link clicks as well as target=_blank.
            // Subframes remain untouched so provider resources can load normally.
            let isTopLevel = navigationAction.targetFrame?.isMainFrame ?? true
            if isTopLevel, webViewModel?.shouldOpenExternally(url) == true {
                openExternally(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard let url = navigationAction.request.url else { return nil }
            if webViewModel?.shouldOpenExternally(url) == true {
                openExternally(url)
            } else {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        /// The asynchronous variant: the synchronous `open(_:)` blocks the main
        /// thread on Launch Services while it resolves and launches the handler.
        private func openExternally(_ url: URL) {
            NSWorkspace.shared.open(
                url,
                configuration: NSWorkspace.OpenConfiguration(),
                completionHandler: nil
            )
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
        }

        func webView(
            _ webView: WKWebView,
            navigationResponse: WKNavigationResponse,
            didBecome download: WKDownload
        ) {
            download.delegate = self
        }

        func webView(
            _ webView: WKWebView,
            navigationAction: WKNavigationAction,
            didBecome download: WKDownload
        ) {
            download.delegate = self
        }

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping (URL?) -> Void
        ) {
            guard let downloadsDirectory = FileManager.default.urls(
                for: .downloadsDirectory,
                in: .userDomainMask
            ).first else {
                completionHandler(nil)
                return
            }

            let sanitizedName = URL(fileURLWithPath: suggestedFilename).lastPathComponent
            let filename = sanitizedName.isEmpty ? "Download" : sanitizedName
            let baseURL = downloadsDirectory.appendingPathComponent(filename)
            let stem = baseURL.deletingPathExtension().lastPathComponent
            let pathExtension = baseURL.pathExtension
            var destination = baseURL
            var counter = 1

            while FileManager.default.fileExists(atPath: destination.path) ||
                    reservedDownloadDestinations.contains(destination) {
                let candidateName = pathExtension.isEmpty
                    ? "\(stem) (\(counter))"
                    : "\(stem) (\(counter)).\(pathExtension)"
                destination = downloadsDirectory.appendingPathComponent(candidateName)
                counter += 1
            }

            let key = ObjectIdentifier(download)
            downloadDestinations[key] = destination
            reservedDownloadDestinations.insert(destination)
            completionHandler(destination)
        }

        func downloadDidFinish(_ download: WKDownload) {
            guard let destination = removeDestination(for: download) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }

        func download(
            _ download: WKDownload,
            didFailWithError error: Error,
            resumeData: Data?
        ) {
            _ = removeDestination(for: download)
            let alert = NSAlert()
            alert.messageText = "Download Failed"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
            completionHandler()
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            let alert = NSAlert()
            alert.messageText = message
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            completionHandler(alert.runModal() == .alertFirstButtonReturn)
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            let alert = NSAlert()
            alert.messageText = prompt
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            let textField = NSTextField(
                frame: NSRect(x: 0, y: 0, width: 240, height: 24)
            )
            textField.stringValue = defaultText ?? ""
            alert.accessoryView = textField
            completionHandler(
                alert.runModal() == .alertFirstButtonReturn ? textField.stringValue : nil
            )
        }

        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping (WKPermissionDecision) -> Void
        ) {
            let trusted = webViewModel?.allowsMediaCapture(from: origin.host) == true
            decisionHandler(trusted ? .grant : .prompt)
        }

        func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping ([URL]?) -> Void
        ) {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.canChooseFiles = true
            NSApp.activate(ignoringOtherApps: true)
            panel.begin { response in
                completionHandler(response == .OK ? panel.urls : nil)
            }
        }

        private func removeDestination(for download: WKDownload) -> URL? {
            let destination = downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
            if let destination {
                reservedDownloadDestinations.remove(destination)
            }
            return destination
        }
    }
}

final class BrowserWebViewContainer: NSView {
    private(set) var webView: WKWebView
    private weak var webViewModel: WebViewModel?
    private let coordinator: BrowserWebView.Coordinator
    private var windowObserver: NSObjectProtocol?

    init(
        webView: WKWebView,
        webViewModel: WebViewModel,
        coordinator: BrowserWebView.Coordinator
    ) {
        self.webView = webView
        self.webViewModel = webViewModel
        self.coordinator = coordinator
        super.init(frame: .zero)
        autoresizesSubviews = true
        webViewModel.registerHost(self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
        }
    }

    func swapWebView(to newWebView: WKWebView) {
        guard webView !== newWebView else { return }
        let retainedOwnership = webViewModel?.isHostOwner(self) == true
        if webView.superview === self {
            webView.removeFromSuperview()
        }
        webView = newWebView

        if retainedOwnership || window?.isKeyWindow == true {
            attachWebView()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
            self.windowObserver = nil
        }
        guard let window else { return }

        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.attachWebView()
        }
        if window.isKeyWindow {
            attachWebView()
        }
    }

    override func layout() {
        super.layout()
        if webView.superview === self {
            webView.frame = bounds
        }
    }

    private func attachWebView() {
        guard let webViewModel else { return }
        webViewModel.claimHost(self)
        guard webView.superview !== self else { return }
        webView.removeFromSuperview()
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        addSubview(webView)
    }
}

/// A weak slot in WebViewModel's host registry. See the registry fields on
/// `WebViewModel` for the memory invariant it exists to uphold.
final class WeakBrowserContainer {
    weak var value: BrowserWebViewContainer?
    init(_ value: BrowserWebViewContainer) { self.value = value }
}
