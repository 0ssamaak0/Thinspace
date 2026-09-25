//
//  ProviderAdapter.swift
//  Thinspace
//

import Foundation
import WebKit

enum ProviderPage: Equatable {
    case home
    case conversation
    case projects
    case code
    case other
}

enum ProviderURLClassification: Equatable {
    case application
    case authentication
    case media
    case external
}

/// Exact and dot-suffix matching avoids trusting lookalikes such as
/// `claude.ai.example.com` or `evilgoogle.com`.
struct HostPolicy: Sendable {
    let exactHosts: Set<String>
    let domainSuffixes: Set<String>

    init(exactHosts: Set<String> = [], domainSuffixes: Set<String> = []) {
        self.exactHosts = Set(exactHosts.map { Self.normalize($0) })
        self.domainSuffixes = Set(domainSuffixes.map { Self.normalize($0) })
    }

    func contains(_ host: String) -> Bool {
        let candidate = Self.normalize(host)
        if exactHosts.contains(candidate) { return true }
        return domainSuffixes.contains { domain in
            candidate == domain || candidate.hasSuffix(".\(domain)")
        }
    }

    private static func normalize(_ host: String) -> String {
        host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}

protocol ProviderAdapter {
    var provider: LLMProvider { get }
    var homeURL: URL { get }
    var applicationHosts: HostPolicy { get }
    var authenticationHosts: HostPolicy { get }
    var mediaHosts: HostPolicy { get }
    var conversationObserverSource: String { get }
    var privateChatObserverSource: String { get }
    var privateChatStartsAtHome: Bool { get }

    func page(for url: URL) -> ProviderPage
    func openNewChat(in webView: WKWebView)
    func exitPrivateChat(in webView: WKWebView)
    func activatePrivateChat(in webView: WKWebView)
    func toggleSidebar(in webView: WKWebView)
    func openNewProject(in webView: WKWebView)
    func projectsURL() -> URL?
    func codeURL() -> URL?
    func openProviderSettings(in webView: WKWebView)
    func focusComposer(in webView: WKWebView)
}

/// JavaScript helper functions shared verbatim across the injected scripts.
/// Interpolated into each script that needs them: every script stays
/// self-contained in the page (no cross-script global), so a missing or late
/// observer script can never turn another script's retry loop into a silent
/// no-op.
enum ProviderJS {
    static let visible = """
    function visible(element) {
        if (!element) return false;
        const style = getComputedStyle(element);
        return style.visibility !== 'hidden' && style.display !== 'none' &&
            element.getClientRects().length > 0;
    }
    """

    /// Raw literal: inside a plain string this regex would need `\\s+`, and
    /// getting that wrong silently turns it into a literal-`s` match.
    static let normalize = #"""
    function normalize(value) {
        return (value || '').replace(/\s+/g, ' ').trim();
    }
    """#
}

/// The verb a `retryingActionScript` performs on the first selector match. An
/// enum rather than a free-form string so no caller can interpolate arbitrary
/// JavaScript into the generated source.
enum RetryAction {
    case focus
    case click

    /// Local variable name and method call match the historical per-adapter
    /// scripts byte for byte.
    var variableName: String { self == .focus ? "input" : "button" }
    var invocation: String { self == .focus ? "focus" : "click" }
}

extension ProviderAdapter {
    var capabilities: ProviderCapabilities { provider.capabilities }
    var privateChatStartsAtHome: Bool { false }

    /// All three providers bind ⌘⇧O to a new chat. A provider that does not
    /// should override this rather than inherit a keystroke that means
    /// something else on its page.
    func openNewChat(in webView: WKWebView) {
        dispatchKeyboardShortcut(
            key: "o", code: "KeyO", keyCode: 79, shift: true,
            privateChatState: false, in: webView
        )
    }

    func exitPrivateChat(in webView: WKWebView) {
        openNewChat(in: webView)
    }

    func classify(_ url: URL) -> ProviderURLClassification {
        guard let host = url.host else { return .external }
        if applicationHosts.contains(host) { return .application }
        if authenticationHosts.contains(host) { return .authentication }
        if mediaHosts.contains(host) { return .media }
        return .external
    }

    func isHomeSurface(_ url: URL) -> Bool {
        page(for: url) == .home
    }

    /// The pages each adapter's `conversationObserverSource` answers `true`
    /// for from the path alone, so native state can agree with the page before
    /// it has loaded. Claude Code counts: it is a full-height app that needs
    /// the expanded Chat Bar just as a conversation does.
    func isConversationSurface(_ url: URL) -> Bool {
        switch page(for: url) {
        case .conversation, .code: return true
        case .home, .projects, .other: return false
        }
    }

    /// Drops a single trailing slash so `/projects/` and `/projects` classify
    /// alike. Shared because all three adapters match paths the same way.
    func normalizedPath(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        return String(path.dropLast())
    }

    func allowsMediaCapture(from host: String) -> Bool {
        // CDN/media resource hosts may be loaded in-page, but only the provider's
        // own application origin receives automatic camera/microphone permission.
        applicationHosts.contains(host)
    }

    func openNewProject(in webView: WKWebView) {}
    func projectsURL() -> URL? { nil }
    func codeURL() -> URL? { nil }
    func openProviderSettings(in webView: WKWebView) {}

    func runJavaScript(_ source: String, named action: String, in webView: WKWebView) {
        webView.evaluateJavaScript(source) { result, error in
            #if DEBUG
            if let error {
                print("[Provider:\(self.provider.rawValue)] \(action) failed: \(error.localizedDescription)")
            } else {
                print("[Provider:\(self.provider.rawValue)] \(action): \(String(describing: result))")
            }
            #endif
        }
    }

    func dispatchKeyboardShortcut(
        key: String,
        code: String,
        keyCode: Int,
        shift: Bool,
        meta: Bool = true,
        privateChatState: Bool? = nil,
        in webView: WKWebView
    ) {
        let privateChatPrelude: String
        if let privateChatState {
            privateChatPrelude = """
            if (window.__aiChatSetPrivateChatState) {
                window.__aiChatSetPrivateChatState(\(privateChatState ? "true" : "false"));
            }
            """
        } else {
            privateChatPrelude = ""
        }

        let source = """
        (function() {
            \(privateChatPrelude)
            function makeEvent() {
                return new KeyboardEvent('keydown', {
                    key: \(Self.javaScriptString(key)),
                    code: \(Self.javaScriptString(code)),
                    keyCode: \(keyCode),
                    which: \(keyCode),
                    shiftKey: \(shift ? "true" : "false"),
                    metaKey: \(meta ? "true" : "false"),
                    ctrlKey: false,
                    altKey: false,
                    bubbles: true,
                    cancelable: true,
                    composed: true
                });
            }
            const targets = [document.activeElement, document, document.body, window];
            let dispatched = false;
            for (const target of targets) {
                if (target && typeof target.dispatchEvent === 'function') {
                    dispatched = target.dispatchEvent(makeEvent()) || dispatched;
                }
            }
            return dispatched;
        })();
        """
        runJavaScript(source, named: "keyboard shortcut \(code)", in: webView)
    }

    /// Retry-until-found skeleton shared by the provider actions that must
    /// wait for an SPA to render its control. The first selector that matches
    /// wins; a miss retries on a fixed budget and then gives up silently,
    /// exactly as the per-adapter copies this replaces did.
    func retryingActionScript(
        selectors: [String],
        action: RetryAction,
        tries: Int = 40,
        interval: Int = 75
    ) -> String {
        let encoded = selectors
            .map { "        \(Self.javaScriptString($0))" }
            .joined(separator: ",\n")
        let variable = action.variableName
        return """
        (function() {
            const selectors = [
        \(encoded)
            ];
            let tries = 0;
            function attempt() {
                for (const selector of selectors) {
                    const \(variable) = document.querySelector(selector);
                    if (\(variable)) { \(variable).\(action.invocation)(); return; }
                }
                if (++tries < \(tries)) setTimeout(attempt, \(interval));
            }
            attempt();
            return true;
        })();
        """
    }

    static func javaScriptString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }

}

enum ProviderAdapters {
    static func adapter(for provider: LLMProvider) -> any ProviderAdapter {
        switch provider {
        case .claude: return ClaudeProviderAdapter()
        case .gemini: return GeminiProviderAdapter()
        case .chatgpt: return ChatGPTProviderAdapter()
        }
    }
}
