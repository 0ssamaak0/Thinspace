//
//  SelectionCapture.swift
//  Thinspace
//

import AppKit
import ApplicationServices

/// What the user had selected in another application when the Chat Bar opened.
struct CapturedSelection: Sendable {
    let text: String
    let appName: String
    /// File name, page URL, or window title — whichever the source app exposes.
    let documentLabel: String?

    /// The attribution shown above the quoted text, e.g. `Preview · paper.pdf`.
    var sourceLabel: String {
        guard let documentLabel, !documentLabel.isEmpty else { return appName }
        return "\(appName) · \(documentLabel)"
    }
}

/// Reads the selected text out of the frontmost application over the
/// Accessibility API.
///
/// Every entry point is gated on the `captureSelectedText` preference. While it
/// is off nothing is observed, no Accessibility call is made, and the system
/// permission prompt is never shown — enabling the toggle is the only thing in
/// the app that can trigger it.
@MainActor
final class SelectionCaptureService {
    static let shared = SelectionCaptureService()

    private var activationObserver: NSObjectProtocol?
    private var lastActiveApp: (pid: pid_t, name: String)?

    private init() {}

    var isEnabled: Bool {
        UserDefaults.standard.bool(
            forKey: UserDefaultsKeys.captureSelectedText.rawValue
        )
    }

    /// Reflects the granted permission without ever prompting for it.
    var isTrusted: Bool { AXIsProcessTrusted() }

    var isReady: Bool { isEnabled && isTrusted }

    // MARK: - Lifecycle

    /// Called at launch and whenever the preference changes. Tracking exists so
    /// a selection stays attributable after its app has been backgrounded.
    func syncWithPreference() {
        isEnabled ? startTracking() : stopTracking()
    }

    /// Shows the system Accessibility prompt. Reachable only from the Settings
    /// toggle, so a user who leaves the feature off never sees it.
    @discardableResult
    func requestPermission() -> Bool {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary)
    }

    func openAccessibilitySettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    private func startTracking() {
        guard activationObserver == nil else { return }
        // Seeded because the feature can be switched on while another app is
        // already frontmost, before any activation notification arrives.
        recordActivation(NSWorkspace.shared.frontmostApplication)
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.recordActivation(
                    notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                        as? NSRunningApplication
                )
            }
        }
    }

    private func stopTracking() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = nil
        lastActiveApp = nil
    }

    private func recordActivation(_ app: NSRunningApplication?) {
        guard let app,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        lastActiveApp = (app.processIdentifier, app.localizedName ?? "Unknown App")
    }

    // MARK: - Capture

    /// Starts capturing the current selection. Call it before the Chat Bar is
    /// presented, then collect the result with `SelectionCapture.deliver`.
    ///
    /// Only the reads that describe focus run here, on the caller's thread: the
    /// system-wide focused element, and the fallback app's focused element and
    /// window. Presenting the panel moves focus, and after that those same
    /// reads report Thinspace's own composer, or nothing, instead of the source
    /// app. They cost two round trips, each bounded by the messaging timeout.
    /// Everything else — the parent walks, the descendant search, the document
    /// label — reads the saved element references, which stay valid wherever
    /// focus goes, and runs on a global queue while the panel appears.
    ///
    /// Returns `nil` when the feature is off, permission is missing, or
    /// Thinspace itself is the active app. In that last case the fallback would
    /// quote whatever was left selected in the app used before Thinspace: stale,
    /// and not what the user is working with. The menu bar item does not
    /// activate Thinspace, so a summon from there still captures.
    func beginCapture() -> SelectionCapture? {
        guard isReady, !NSApp.isActive else { return nil }
        let targets = AccessibilityReader.focusTargets(
            excludingPID: ProcessInfo.processInfo.processIdentifier,
            fallback: lastActiveApp
        )
        return SelectionCapture { AccessibilityReader.selection(resolving: targets) }
    }
}

/// A capture in flight. The walk starts on creation, so it overlaps the Chat
/// Bar's presentation instead of delaying it.
final class SelectionCapture: @unchecked Sendable {
    private let group = DispatchGroup()
    /// Written once on the global queue before `group.leave()`, and read only
    /// by the block `group.notify` submits after that leave. Dispatch orders the
    /// read after the write, so the two never overlap.
    private var result: CapturedSelection?

    init(resolve: @escaping @Sendable () -> CapturedSelection?) {
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            result = resolve()
            group.leave()
        }
    }

    /// Hands a found selection to `completion` on the main queue, behind every
    /// block already queued there when this is called — even when the walk has
    /// already finished. Nothing is delivered when nothing was found.
    func deliver(_ completion: @escaping @MainActor (CapturedSelection) -> Void) {
        group.notify(queue: .main) { [self] in
            guard let result else { return }
            MainActor.assumeIsolated { completion(result) }
        }
    }
}

/// The Accessibility reads themselves, kept off the main-actor service because
/// every call here is blocking IPC into another process. Only `focusTargets`
/// runs on the main thread; the walk runs on a global queue.
private enum AccessibilityReader {
    /// The element references a capture resolves against.
    ///
    /// `@unchecked Sendable` because Swift does not mark the CF type
    /// AXUIElement Sendable. The hand-off is still safe: each reference is an
    /// immutable handle to an element in another process, CF reference
    /// counting is atomic, and once `focusTargets` returns, only the walk on
    /// the global queue uses them.
    struct FocusTargets: @unchecked Sendable {
        /// The system-wide focused element, when it belongs to another process.
        let focused: AXUIElement?
        /// `lastActiveApp`, when it is another process.
        let fallback: (pid: pid_t, name: String)?
        let fallbackFocused: AXUIElement?
        let fallbackWindow: AXUIElement?
    }

    /// The system default is six seconds, long enough for one unresponsive app
    /// to hang the capture. A miss is preferable to a stall.
    ///
    /// Set on the system-wide element this applies to every Accessibility call
    /// the process makes, which is also what bounds the parent walks and the
    /// descendant search below.
    static let messagingTimeout: Float = 0.25
    static let maximumCharacters = 20_000
    /// Bounds the walk up to the containing window for elements that do not
    /// answer `kAXWindowAttribute` directly.
    static let maximumParentHops = 12
    /// Bounds the descendant search. A hit is fast — Safari answers in 12 nodes
    /// — but a miss walks the whole budget, and summoning the Chat Bar with
    /// nothing selected is the common case. This ceiling is therefore paid on
    /// ordinary hotkey presses — off the main thread, but still as reads the
    /// source app has to answer — and is kept low on purpose.
    static let maximumSearchNodes = 80
    static let maximumSearchDepth = 10

    /// A web area answers for its own selection, and its children are the whole
    /// page. Descending into one would enumerate a DOM over IPC.
    static let webAreaRole = "AXWebArea"

    /// Window chrome cannot hold a page selection, and not descending into it is
    /// most of what keeps the search cheap. A selection in Safari's address bar
    /// still resolves, through the focused-element path that runs first.
    static let chromeRoles: Set<String> = [
        kAXToolbarRole, kAXMenuBarRole, kAXMenuBarItemRole, kAXButtonRole,
        kAXPopUpButtonRole, kAXImageRole, kAXCheckBoxRole, kAXRadioButtonRole,
        kAXSliderRole, kAXProgressIndicatorRole
    ]

    /// The reads that describe focus, and so cannot wait. The system-wide
    /// focused element is the most accurate source, and at hotkey time the
    /// source app is still frontmost. Once focus has moved into Thinspace the
    /// last application that was active is the fallback; its focused element
    /// and window are read now, in one round trip, because while the Chat Bar
    /// is key that app may no longer report them.
    static func focusTargets(
        excludingPID ownPID: pid_t,
        fallback: (pid: pid_t, name: String)?
    ) -> FocusTargets {
        // First, because it also sets the process-wide messaging timeout that
        // bounds every later call, the walk on the global queue included.
        var focused = systemWideFocusedElement()
        if let element = focused, pid(of: element) == ownPID { focused = nil }

        guard let fallback, fallback.pid != ownPID else {
            return FocusTargets(
                focused: focused,
                fallback: nil,
                fallbackFocused: nil,
                fallbackWindow: nil
            )
        }
        let application = AXUIElementCreateApplication(fallback.pid)
        _ = AXUIElementSetMessagingTimeout(application, messagingTimeout)
        let values = multipleValues(application, [
            kAXFocusedUIElementAttribute,
            kAXFocusedWindowAttribute
        ])
        return FocusTargets(
            focused: focused,
            fallback: fallback,
            fallbackFocused: uiElement(values[0]),
            fallbackWindow: uiElement(values[1])
        )
    }

    /// Resolves a capture on the global queue. The messaging timeout bounds
    /// each call, and an unresponsive source app costs about three timeouts in
    /// total because every walk short-circuits on its first failed fetch. What
    /// no per-call timeout bounds is a responsive-but-slow app answering
    /// several hundred reads, which is why the walks below are deduplicated and
    /// batched.
    ///
    /// Returns `nil` when nothing is selected or the source app does not expose
    /// its selection.
    static func selection(resolving targets: FocusTargets) -> CapturedSelection? {
        if let focused = targets.focused,
           let selection = selection(from: focused) {
            return selection
        }

        guard let fallback = targets.fallback else { return nil }

        // Skipped when it is the element just walked: usually the same ~39
        // blocking reads for the same nil answer.
        if let focused = targets.fallbackFocused,
           !(targets.focused.map { CFEqual($0, focused) } ?? false),
           let selection = selection(from: focused, appName: fallback.name) {
            return selection
        }

        // Safari and other WebKit hosts answer from neither focused element:
        // the selection lives on the web area, which is not what holds focus.
        guard let window = targets.fallbackWindow,
              let text = searchForSelectedText(under: window) else { return nil }
        return CapturedSelection(
            text: truncated(text),
            appName: fallback.name,
            documentLabel: documentLabel(ofWindow: window)
        )
    }

    /// Breadth-first and tightly bounded. The web area holding a page selection
    /// sits only a few levels under the window, so this finds it quickly or not
    /// at all rather than crawling a whole UI tree over IPC.
    private static func searchForSelectedText(under window: AXUIElement) -> String? {
        var queue: [(element: AXUIElement, depth: Int)] = [(window, 0)]
        var visited = 0

        while !queue.isEmpty, visited < maximumSearchNodes {
            let (element, depth) = queue.removeFirst()
            visited += 1

            // Read first, so chrome costs one call instead of three. An unknown
            // role is kept; only roles known to be chrome are skipped.
            let role = string(element, kAXRoleAttribute)
            if let role, chromeRoles.contains(role) { continue }

            if let text = selectedText(of: element) { return text }

            guard depth < maximumSearchDepth else { continue }
            // Stopping at the web area is what keeps a miss cheap: its children
            // are the rendered page, and expanding them would turn a fruitless
            // search into thousands of cross-process reads.
            if role == webAreaRole { continue }

            for child in children(element) {
                queue.append((child, depth + 1))
            }
        }
        return nil
    }

    private static func selection(
        from element: AXUIElement,
        appName: String? = nil
    ) -> CapturedSelection? {
        guard let text = selectedText(startingAt: element) else { return nil }

        let resolvedName = appName
            ?? pid(of: element).flatMap {
                NSRunningApplication(processIdentifier: $0)?.localizedName
            }
            ?? "Unknown App"

        return CapturedSelection(
            text: truncated(text),
            appName: resolvedName,
            documentLabel: documentLabel(for: element)
        )
    }

    /// WebKit hosts report the selection on the enclosing web area rather than
    /// on whichever node holds focus, so an empty answer is retried up the
    /// parent chain before giving up. The three attributes each hop needs are
    /// fetched in one round trip instead of two or three.
    private static func selectedText(startingAt element: AXUIElement) -> String? {
        var current = element
        for _ in 0...maximumParentHops {
            let values = multipleValues(current, [
                kAXSelectedTextAttribute,
                "AXSelectedTextMarkerRange",
                kAXParentAttribute
            ])
            if let text = nonEmpty(values[0] as? String) { return text }
            if let range = values[1],
               let text = stringForTextMarkerRange(range, of: current) {
                return text
            }
            guard let parentRef = values[2],
                  CFGetTypeID(parentRef) == AXUIElementGetTypeID() else { break }
            current = (parentRef as! AXUIElement)
        }
        return nil
    }

    /// Native text views answer `AXSelectedText`. WebKit does not implement it
    /// for general web content and exposes the selection as a text-marker range
    /// instead, which has to be resolved to a string through a parameterized
    /// attribute — this is the route VoiceOver uses to read a Safari selection.
    private static func selectedText(of element: AXUIElement) -> String? {
        if let text = nonEmpty(string(element, kAXSelectedTextAttribute)) { return text }

        guard let range = value(element, "AXSelectedTextMarkerRange") else { return nil }
        return stringForTextMarkerRange(range, of: element)
    }

    private static func stringForTextMarkerRange(
        _ range: CFTypeRef,
        of element: AXUIElement
    ) -> String? {
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXStringForTextMarkerRange" as CFString,
            range,
            &result
        ) == .success else { return nil }
        return nonEmpty(result as? String)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// `AXDocument` is what document-based apps expose: a file URL in Preview,
    /// TextEdit and Pages, the page URL in Safari. Apps that set no document,
    /// such as Terminal and Mail, fall back to their window title.
    private static func documentLabel(for element: AXUIElement) -> String? {
        guard let window = containingWindow(of: element) else { return nil }
        return documentLabel(ofWindow: window)
    }

    private static func documentLabel(ofWindow window: AXUIElement) -> String? {
        if let document = string(window, kAXDocumentAttribute),
           let url = URL(string: document) {
            guard url.isFileURL else { return document }
            let name = url.lastPathComponent
            return name.removingPercentEncoding ?? name
        }
        return string(window, kAXTitleAttribute)
    }

    private static func containingWindow(of element: AXUIElement) -> AXUIElement? {
        if let window = self.element(element, kAXWindowAttribute) { return window }

        var current = element
        for _ in 0..<maximumParentHops {
            guard let parent = self.element(current, kAXParentAttribute) else { return nil }
            if string(parent, kAXRoleAttribute) == kAXWindowRole { return parent }
            current = parent
        }
        return nil
    }

    private static func truncated(_ text: String) -> String {
        guard text.count > maximumCharacters else { return text }
        return String(text.prefix(maximumCharacters)) + "\n… (truncated)"
    }

    // MARK: - Attribute helpers

    private static func systemWideFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        _ = AXUIElementSetMessagingTimeout(systemWide, messagingTimeout)
        return element(systemWide, kAXFocusedUIElementAttribute)
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &result
        ) == .success else { return nil }
        return result
    }

    private static func element(
        _ element: AXUIElement,
        _ attribute: String
    ) -> AXUIElement? {
        uiElement(value(element, attribute))
    }

    private static func uiElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        value(element, attribute) as? String
    }

    /// One round trip for several attributes. A failed attribute comes back as
    /// an AXValue error placeholder; those map to nil so callers see exactly
    /// what the single-attribute helpers would have returned.
    private static func multipleValues(
        _ element: AXUIElement,
        _ attributes: [String]
    ) -> [CFTypeRef?] {
        var raw: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(
            element,
            attributes as CFArray,
            AXCopyMultipleAttributeOptions(),
            &raw
        ) == .success,
              let values = raw as [AnyObject]?,
              values.count == attributes.count else {
            return [CFTypeRef?](repeating: nil, count: attributes.count)
        }
        return values.map { entry in
            let ref = entry as CFTypeRef
            if CFGetTypeID(ref) == AXValueGetTypeID(),
               AXValueGetType((ref as! AXValue)) == .axError {
                return nil
            }
            return ref
        }
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func pid(of element: AXUIElement) -> pid_t? {
        var result: pid_t = 0
        guard AXUIElementGetPid(element, &result) == .success else { return nil }
        return result
    }
}
