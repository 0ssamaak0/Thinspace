//
//  ChatBarPanel.swift
//  Thinspace
//
//  Created by alexcding on 2025-12-13.
//

import AppKit
import QuartzCore

@MainActor
final class ChatBarPanel: NSPanel, NSWindowDelegate {
    private enum PresentationState {
        case hidden
        case showing
        case visible
        case hiding
    }

    /// Static so `init` can read the persisted size before `self` is available.
    private static func storedContentSize() -> NSSize {
        let width = UserDefaults.standard.double(
            forKey: UserDefaultsKeys.panelWidth.rawValue
        )
        let height = UserDefaults.standard.double(
            forKey: UserDefaultsKeys.panelHeight.rawValue
        )
        return NSSize(
            width: width > 0 ? width : Constants.defaultWidth,
            height: height > 0 ? height : Constants.defaultHeight
        )
    }

    private var initialContentSize: NSSize {
        Self.storedContentSize()
    }

    private var initialPanelSize: NSSize {
        Self.panelSize(forContentSize: initialContentSize)
    }

    private var currentScreen: NSScreen? {
        NSScreen.screen(containing: NSPoint(x: frame.midX, y: frame.midY))
    }

    private var expandedHeight: CGFloat {
        let screenHeight = currentScreen?.visibleFrame.height ?? 800
        let contentHeight = max(
            screenHeight * Constants.expandedScreenRatio,
            initialContentSize.height
        )
        return contentHeight + Constants.chromeExpansion
    }

    private var isExpanded = false
    private var presentationState: PresentationState = .hidden
    private var presentationGeneration = 0
    private var presentationFrame: NSRect?
    private var isProgrammaticTransition = false
    private var pendingConversationExpansion = false
    private var positionSaveWork: DispatchWorkItem?
    private var sizeSaveWork: DispatchWorkItem?
    private var clickOutsideMonitor: Any?
    private weak var webViewModel: WebViewModel?
    private var glassEffectView: ChatBarGlassEffectView?
    private let onRequestDismiss: () -> Void

    init(
        contentView hostedContentView: NSView,
        webViewModel: WebViewModel,
        onRequestDismiss: @escaping () -> Void
    ) {
        let startingPanelSize = Self.panelSize(forContentSize: Self.storedContentSize())

        self.webViewModel = webViewModel
        self.onRequestDismiss = onRequestDismiss

        super.init(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: startingPanelSize.width,
                height: startingPanelSize.height
            ),
            styleMask: [.nonactivatingPanel, .resizable, .borderless],
            backing: .buffered,
            defer: false
        )

        let glassView = ChatBarGlassEffectView(frame: contentLayoutRect)
        glassEffectView = glassView
        let contentContainer = NSView(frame: glassView.bounds)
        hostedContentView.frame = contentContainer.bounds.insetBy(
            dx: Constants.glassRimWidth,
            dy: Constants.glassRimWidth
        )
        hostedContentView.autoresizingMask = [.width, .height]
        hostedContentView.wantsLayer = true
        hostedContentView.layer?.cornerRadius = Constants.innerCornerRadius
        hostedContentView.layer?.cornerCurve = .continuous
        hostedContentView.layer?.masksToBounds = true
        contentContainer.addSubview(hostedContentView)
        glassView.contentView = contentContainer
        glassView.autoresizingMask = [.width, .height]
        self.contentView = glassView
        delegate = self

        configureWindow()
        configureAppearance()
        updateChatAppearance(
            provider: webViewModel.provider,
            isPrivateChat: webViewModel.isInPrivateChat
        )

        webViewModel.onConversationStarted = { [weak self] in
            guard let self, self.isVisible else { return }
            if self.presentationState == .visible {
                self.expandToNormalSize()
            } else {
                self.pendingConversationExpansion = true
            }
        }
        webViewModel.onPrivateChatStateChanged = { [weak self] isActive in
            guard let self, let webViewModel = self.webViewModel else { return }
            self.updateChatAppearance(
                provider: webViewModel.provider,
                isPrivateChat: isActive
            )
        }
    }

    deinit {
        positionSaveWork?.cancel()
        sizeSaveWork?.cancel()
        // Backstop only; the monitor is normally removed on dismissal.
        if let clickOutsideMonitor {
            NSEvent.removeMonitor(clickOutsideMonitor)
        }
    }

    private func configureWindow() {
        isFloatingPanel = true
        level = .floating
        isMovable = true
        isMovableByWindowBackground = false
        // The coordinator owns this panel strongly and calls close() to release
        // it on idle; the NSWindow default of true would make that close an
        // over-release on an ARC-held property.
        isReleasedWhenClosed = false
        collectionBehavior.formUnion([.fullScreenAuxiliary, .canJoinAllSpaces])
        minSize = Self.panelSize(
            forContentSize: NSSize(
                width: Constants.minWidth,
                height: Constants.minHeight
            )
        )
        maxSize = Self.panelSize(
            forContentSize: NSSize(
                width: Constants.maxWidth,
                height: Constants.maxHeight
            )
        )

    }

    /// Installed only while the panel is on screen. A monitor left armed keeps
    /// waking the app for every click anywhere in the system, and the panel is
    /// cached for the app's lifetime, so `deinit` is not a timely teardown.
    private func installClickOutsideMonitor() {
        guard clickOutsideMonitor == nil else { return }
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: .leftMouseDown
        ) { [weak self] _ in
            guard let self, self.isVisible else { return }
            self.onRequestDismiss()
        }
    }

    private func removeClickOutsideMonitor() {
        guard let clickOutsideMonitor else { return }
        NSEvent.removeMonitor(clickOutsideMonitor)
        self.clickOutsideMonitor = nil
    }

    private func configureAppearance() {
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        animationBehavior = .none
    }

    private func updateChatAppearance(
        provider: LLMProvider,
        isPrivateChat: Bool
    ) {
        glassEffectView?.tintColor = isPrivateChat
            ? Constants.privateChatTintColor
            : Constants.normalChatTintColor(for: provider)
    }

    /// Resolves the correct size before the panel's final presentation frame is
    /// calculated.
    func prepareForPresentation() {
        guard !isProgrammaticTransition else { return }
        adjustSizeForConversationState()
        presentationFrame = frame
    }

    /// Places the panel for the configured `PanelPosition`. Called after
    /// `prepareForPresentation()`, which settles the size that `contentBoxSize`
    /// derives from — the order is load-bearing. Deliberately not folded into
    /// `prepareForPresentation`: its `isProgrammaticTransition` guard must not
    /// gate positioning, or a show arriving during an expand/dismiss animation
    /// would silently skip it.
    ///
    /// `force` is the "panel was just created" case (and the Settings reset),
    /// which must reposition even when the user chose Remember Last.
    func positionForPresentation(force: Bool) {
        let position = PanelPosition.current
        guard force || (!isVisible && position != .rememberLast) else { return }
        // The screen guard sits before the Remember Last branch on purpose: a
        // no-screen state skips the saved-origin restore too, exactly as the
        // coordinator's placement always has.
        guard let screen = NSScreen.screenAtMouseLocation() ?? NSScreen.main else {
            return
        }

        if position == .rememberLast {
            let defaults = UserDefaults.standard
            if defaults.object(forKey: UserDefaultsKeys.panelX.rawValue) != nil,
               defaults.object(forKey: UserDefaultsKeys.panelY.rawValue) != nil {
                let saved = NSPoint(
                    x: defaults.double(forKey: UserDefaultsKeys.panelX.rawValue),
                    y: defaults.double(forKey: UserDefaultsKeys.panelY.rawValue)
                )
                let center = NSPoint(
                    x: saved.x + contentBoxSize.width / 2,
                    y: saved.y + contentBoxSize.height / 2
                )
                if NSScreen.screenStrictly(containing: center) != nil {
                    setPresentationContentOrigin(saved)
                    return
                }
            }
        }

        let origin = screen.point(
            for: contentBoxSize,
            position: position,
            dockOffset: Constants.dockOffset
        )
        setPresentationContentOrigin(origin)
    }

    /// Deferred one run-loop turn. `presentAnimated` has already attached the
    /// shared WKWebView by then, but callers queue work behind this focus —
    /// the captured-selection insert in `AppCoordinator.showChatBar` relies on
    /// running after it — so the deferral is part of the ordering contract.
    func focusComposer() {
        DispatchQueue.main.async { [weak self] in
            self?.webViewModel?.focusComposer()
        }
    }

    /// Positions the inner app at the requested origin. The glass rim extends
    /// outward from that content box and does not change its saved placement.
    /// Every programmatic move must route through here, never a raw
    /// `setFrameOrigin`: cancelling `positionSaveWork` and bracketing the move
    /// in `isProgrammaticTransition` is what stops `windowDidMove` from
    /// re-persisting the origin.
    private func setPresentationContentOrigin(_ origin: NSPoint) {
        positionSaveWork?.cancel()
        isProgrammaticTransition = true
        setFrameOrigin(Self.panelOrigin(forContentOrigin: origin))
        presentationFrame = frame
        isProgrammaticTransition = false
    }

    /// The web app's dimensions, excluding the Liquid Glass chrome.
    private var contentBoxSize: NSSize {
        Self.contentSize(forPanelSize: frame.size)
    }

    var shouldDismissOnToggle: Bool {
        presentationState == .showing || presentationState == .visible
    }

    /// True only when the user has already dismissed the panel. Suspension can
    /// fire while a presented panel is merely occluded (display sleep, screen
    /// lock, ⌘H); releasing it then would make the user's open panel vanish.
    var isReleasableWhenIdle: Bool {
        presentationState == .hidden && !isVisible
    }

    /// Flushes state that lives only in the live NSPanel before the coordinator
    /// drops it: a width chosen while expanded is committed by the collapse
    /// (hidden window, so nothing visibly animates), and any debounced
    /// geometry save — which `deinit` would cancel — is written out now.
    func prepareForIdleRelease() {
        removeClickOutsideMonitor()
        if isExpanded { resetToInitialSize() }
        positionSaveWork?.cancel()
        positionSaveWork = nil
        sizeSaveWork?.cancel()
        sizeSaveWork = nil

        let size = contentBoxSize
        UserDefaults.standard.set(
            size.width,
            forKey: UserDefaultsKeys.panelWidth.rawValue
        )
        UserDefaults.standard.set(
            size.height,
            forKey: UserDefaultsKeys.panelHeight.rawValue
        )
        if PanelPosition.current == .rememberLast {
            let origin = Self.contentOrigin(forPanelOrigin: frame.origin)
            UserDefaults.standard.set(
                origin.x,
                forKey: UserDefaultsKeys.panelX.rawValue
            )
            UserDefaults.standard.set(
                origin.y,
                forKey: UserDefaultsKeys.panelY.rawValue
            )
        }
    }

    func presentAnimated() {
        presentationGeneration += 1
        let generation = presentationGeneration

        if presentationState == .visible, isVisible {
            makeKeyAndOrderFront(nil)
            return
        }

        let wasVisible = isVisible
        presentationState = .showing
        isProgrammaticTransition = true
        positionSaveWork?.cancel()
        installClickOutsideMonitor()

        let finalFrame = presentationFrame ?? frame
        presentationFrame = finalFrame
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let offset = reduceMotion ? 0 : Constants.verticalMotionOffset
        let effectiveDuration = reduceMotion
            ? Constants.reducedMotionDuration
            : Constants.showDuration
        let initialFrame = finalFrame.offsetBy(dx: 0, dy: -offset)

        if !wasVisible {
            setFrame(initialFrame, display: false)
            alphaValue = 0
        }
        // Staged while still fully transparent. Becoming key hands the shared
        // WKWebView to this panel's host; the forced layout builds a freshly
        // created panel's SwiftUI content, whose host attaches the WebView on
        // arrival; the flush commits that first frame. All of it used to run
        // after the fade had started and ate its first frames. It is the same
        // pass the end of the run-loop turn would make, only done earlier.
        makeKeyAndOrderFront(nil)
        layoutIfNeeded()
        displayIfNeeded()
        CATransaction.flush()

        // The fade itself starts a turn later, so it never shares a frame with
        // the staging above. Keyed to the state rather than the generation: a
        // size reset in the gap also bumps the generation, and cancelling on
        // that would strand an ordered-in, fully transparent panel. A
        // dismissal in the gap moves the state off `.showing`.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.presentationState == .showing, self.isVisible else {
                return
            }

            NSAnimationContext.runAnimationGroup { context in
                context.duration = effectiveDuration
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                // NSWindow provides an implicit animation for `frame`, but not
                // for `frameOrigin`. Keeping the size unchanged still makes this
                // a position-only compositor move.
                self.animator().setFrame(finalFrame, display: true)
                self.animator().alphaValue = 1
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self,
                          generation == self.presentationGeneration else { return }

                    self.setFrame(finalFrame, display: false)
                    self.alphaValue = 1
                    self.presentationFrame = finalFrame
                    self.isProgrammaticTransition = false
                    self.presentationState = .visible

                    if self.pendingConversationExpansion {
                        self.pendingConversationExpansion = false
                        self.expandToNormalSize()
                    }
                }
            }
        }
    }

    func dismissAnimated() {
        presentationGeneration += 1
        let generation = presentationGeneration
        // Dropped up front so a click landing during the hide animation cannot
        // request a second dismissal.
        removeClickOutsideMonitor()

        guard isVisible else {
            presentationState = .hidden
            alphaValue = 1
            return
        }

        presentationState = .hiding
        isProgrammaticTransition = true
        positionSaveWork?.cancel()

        let finalFrame = presentationFrame ?? frame
        presentationFrame = finalFrame
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let offset = reduceMotion ? 0 : Constants.verticalMotionOffset
        let effectiveDuration = reduceMotion
            ? Constants.reducedMotionDuration
            : Constants.hideDuration
        let dismissedFrame = finalFrame.offsetBy(dx: 0, dy: -offset)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = effectiveDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().setFrame(dismissedFrame, display: true)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      generation == self.presentationGeneration else { return }

                self.orderOut(nil)
                self.setFrame(finalFrame, display: false)
                self.alphaValue = 1
                self.presentationFrame = finalFrame
                self.isProgrammaticTransition = false
                self.presentationState = .hidden
            }
        }
    }

    /// Window-to-window switching is intentionally immediate. It avoids
    /// coupling the Chat Bar's swipe animation to main-window presentation or
    /// moving the shared WKWebView while either window is mid-transition.
    func dismissImmediately() {
        presentationGeneration += 1
        positionSaveWork?.cancel()
        removeClickOutsideMonitor()
        let finalFrame = presentationFrame ?? frame

        // A zero-duration animator assignment cancels any in-flight implicit
        // frame/alpha animation before the panel is ordered out.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            animator().setFrame(finalFrame, display: false)
            animator().alphaValue = 1
        }
        orderOut(nil)
        setFrame(finalFrame, display: false)
        alphaValue = 1
        presentationFrame = finalFrame
        isProgrammaticTransition = false
        presentationState = .hidden
    }

    /// A provider switch always opens the new provider's home page.
    ///
    /// The tint update must stay the first statement: `resetToInitialSize`
    /// ends in `setFrame(display: true)`, the only forced display in the
    /// sequence, and tinting after it could paint one stale-colour frame.
    func providerDidSwitch() {
        if let webViewModel {
            updateChatAppearance(
                provider: webViewModel.provider,
                isPrivateChat: webViewModel.isInPrivateChat
            )
        }
        resetToInitialSize()
        if isVisible {
            DispatchQueue.main.async { [weak self] in
                self?.webViewModel?.focusComposer()
            }
        }
    }

    private func adjustSizeForConversationState() {
        let inConversation = webViewModel?.isInConversation ?? false
        if inConversation {
            if !isExpanded {
                expandToNormalSize()
            }
        } else if isExpanded {
            resetToInitialSize()
        }
    }

    /// Grows in a single step, never an animated resize: every step of a
    /// window-frame animation resizes the live WKWebView, and each resize
    /// makes the provider page lay itself out again at the new viewport.
    ///
    /// The `setFrame` posts `windowDidResize` synchronously with the final
    /// frame, so there is no intermediate size for that handler to record, and
    /// `isExpanded` is already set, so the expanded height is never persisted
    /// as the user's chosen size.
    private func expandToNormalSize() {
        guard !isExpanded, let screen = currentScreen else { return }
        isExpanded = true

        let currentFrame = frame
        let maxAvailableHeight = screen.visibleFrame.maxY - currentFrame.origin.y
        let targetHeight = min(
            expandedHeight,
            maxAvailableHeight - Constants.topPadding
        )
        let clampedHeight = max(targetHeight, initialPanelSize.height)
        let targetFrame = NSRect(
            x: currentFrame.origin.x,
            y: currentFrame.origin.y,
            width: currentFrame.width,
            height: clampedHeight
        )
        presentationFrame = targetFrame
        setFrame(targetFrame, display: true)
    }

    func resetToInitialSize() {
        isExpanded = false
        // Invalidates any in-flight show or hide so its completion cannot
        // restore the frame it captured before this collapse.
        presentationGeneration += 1
        isProgrammaticTransition = false
        let currentFrame = frame
        let targetFrame = NSRect(
            x: currentFrame.origin.x,
            y: currentFrame.origin.y,
            width: currentFrame.width,
            height: initialPanelSize.height
        )
        presentationFrame = targetFrame
        setFrame(targetFrame, display: true)
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        if !isProgrammaticTransition {
            presentationFrame = frame
        }
        guard !isExpanded else { return }

        sizeSaveWork?.cancel()
        let size = contentBoxSize
        let work = DispatchWorkItem {
            UserDefaults.standard.set(
                size.width,
                forKey: UserDefaultsKeys.panelWidth.rawValue
            )
            UserDefaults.standard.set(
                size.height,
                forKey: UserDefaultsKeys.panelHeight.rawValue
            )
        }
        sizeSaveWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Constants.sizeSaveDebounce,
            execute: work
        )
    }

    func windowDidMove(_ notification: Notification) {
        guard !isProgrammaticTransition else { return }
        presentationFrame = frame
        guard PanelPosition.current == .rememberLast else { return }

        positionSaveWork?.cancel()
        let origin = Self.contentOrigin(forPanelOrigin: frame.origin)
        let work = DispatchWorkItem {
            UserDefaults.standard.set(
                origin.x,
                forKey: UserDefaultsKeys.panelX.rawValue
            )
            UserDefaults.standard.set(
                origin.y,
                forKey: UserDefaultsKeys.panelY.rawValue
            )
        }
        positionSaveWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Constants.positionSaveDebounce,
            execute: work
        )
    }

    // MARK: - Keyboard Handling

    override func cancelOperation(_ sender: Any?) {
        onRequestDismiss()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([
            .command,
            .shift,
            .option,
            .control
        ])
        let key = event.charactersIgnoringModifiers?.lowercased()

        if key == "n", modifiers == [.command] {
            webViewModel?.openNewChat()
            resetToInitialSize()
            return true
        }

        if key == "n", modifiers == [.command, .shift] {
            webViewModel?.openPrivateChat()
            resetToInitialSize()
            return true
        }

        if key == ".", modifiers == [.command] {
            webViewModel?.toggleSidebar()
            return true
        }

        return super.performKeyEquivalent(with: event)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    nonisolated static func panelSize(forContentSize size: NSSize) -> NSSize {
        NSSize(
            width: size.width + Constants.chromeExpansion,
            height: size.height + Constants.chromeExpansion
        )
    }

    nonisolated static func contentSize(forPanelSize size: NSSize) -> NSSize {
        NSSize(
            width: size.width - Constants.chromeExpansion,
            height: size.height - Constants.chromeExpansion
        )
    }

    nonisolated static func panelOrigin(forContentOrigin origin: NSPoint) -> NSPoint {
        NSPoint(
            x: origin.x - Constants.glassRimWidth,
            y: origin.y - Constants.glassRimWidth
        )
    }

    nonisolated static func contentOrigin(forPanelOrigin origin: NSPoint) -> NSPoint {
        NSPoint(
            x: origin.x + Constants.glassRimWidth,
            y: origin.y + Constants.glassRimWidth
        )
    }
}

extension ChatBarPanel {
    struct Constants {
        /// Vertical inset above the Dock for the bottom panel positions.
        static let dockOffset: CGFloat = 50
        static let defaultWidth: CGFloat = 500
        static let defaultHeight: CGFloat = 200
        static let minWidth: CGFloat = 300
        static let minHeight: CGFloat = 150
        static let maxWidth: CGFloat = 900
        static let maxHeight: CGFloat = 900
        static let glassRimWidth: CGFloat = 10
        static let chromeExpansion: CGFloat = glassRimWidth * 2
        static let cornerRadius: CGFloat = 30
        static let innerCornerRadius: CGFloat = cornerRadius - glassRimWidth
        static let privateChatTintColor = NSColor.white.withAlphaComponent(0.50)

        static func normalChatTintColor(for provider: LLMProvider) -> NSColor {
            switch provider {
            case .gemini:
                return NSColor.systemBlue.withAlphaComponent(0.10)
            case .claude:
                return NSColor.systemOrange.withAlphaComponent(0.10)
            case .chatgpt:
                return NSColor.white.withAlphaComponent(0.10)
            }
        }
        static let expandedScreenRatio: CGFloat = 0.7
        static let showDuration: TimeInterval = 0.16
        static let hideDuration: TimeInterval = 0.12
        static let reducedMotionDuration: TimeInterval = 0.08
        static let verticalMotionOffset: CGFloat = 20
        static let topPadding: CGFloat = 20
        static let positionSaveDebounce: TimeInterval = 0.3
        static let sizeSaveDebounce: TimeInterval = 0.3
    }
}

/// A single system-rendered glass surface forms chrome outside the web app's
/// persisted content box, so adding the rim never shrinks the website.
private final class ChatBarGlassEffectView: NSGlassEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureGlass()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureGlass()
    }

    private func configureGlass() {
        style = .regular
        cornerRadius = ChatBarPanel.Constants.cornerRadius
        // NSGlassEffectView rounds its material, but the hosted hierarchy also
        // needs an outer clip to prevent a square window edge from leaking
        // through at the transparent corners.
        wantsLayer = true
        layer?.cornerRadius = ChatBarPanel.Constants.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
    }
}
