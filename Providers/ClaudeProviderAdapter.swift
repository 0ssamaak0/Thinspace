//
//  ClaudeProviderAdapter.swift
//  Thinspace
//

import Foundation
import WebKit

struct ClaudeProviderAdapter: ProviderAdapter {
    let provider: LLMProvider = .claude
    let homeURL = URL(string: "https://claude.ai/new")!
    let applicationHosts = HostPolicy(domainSuffixes: ["claude.ai"])
    let authenticationHosts = HostPolicy(
        exactHosts: ["accounts.google.com"],
        domainSuffixes: ["anthropic.com"]
    )
    let mediaHosts = HostPolicy(
        domainSuffixes: ["claudeusercontent.com", "anthropic.com", "googleapis.com", "gstatic.com"]
    )
    let privateChatStartsAtHome = true

    func page(for url: URL) -> ProviderPage {
        guard let host = url.host, applicationHosts.contains(host) else { return .other }
        let path = normalizedPath(url.path)
        if path == "/" || path == "/new" { return .home }
        if path == "/projects" || path.hasPrefix("/projects/") { return .projects }
        if path == "/code" || path.hasPrefix("/code/") { return .code }
        if path == "/chat" || path.hasPrefix("/chat/") { return .conversation }
        return .other
    }

    /// Claude's new-chat shortcut preserves Incognito mode. A fresh `/new`
    /// navigation explicitly leaves that mode before creating the normal chat.
    func exitPrivateChat(in webView: WKWebView) {
        webView.load(URLRequest(url: homeURL))
    }

    /// Activates Claude's Incognito Chat control after WebViewModel has opened `/new`.
    func activatePrivateChat(in webView: WKWebView) {
        let source = """
        (function() {
            const selectors = [
                '[data-testid="incognito-chat-button"]',
                '[data-testid*="incognito" i]',
                'button[aria-label*="incognito" i]',
                'button[title*="incognito" i]',
                'button[aria-label*="private chat" i]',
                'button[title*="private chat" i]'
            ];
            const MAX_TRIES = 50;
            let tries = 0;

            \(ProviderJS.visible)

            function findButton() {
                for (const selector of selectors) {
                    try {
                        const match = Array.from(document.querySelectorAll(selector)).find(visible);
                        if (match) return match;
                    } catch (_) {}
                }
                return Array.from(document.querySelectorAll('button')).find(function(button) {
                    if (!visible(button)) return false;
                    const label = [
                        button.getAttribute('aria-label'),
                        button.getAttribute('title'),
                        button.innerText
                    ].filter(Boolean).join(' ');
                    return /incognito|private chat/i.test(label);
                }) || null;
            }

            function attempt() {
                const button = findButton();
                if (button) {
                    button.click();
                    if (window.__thinspaceSetPrivateChatState) {
                        window.__thinspaceSetPrivateChatState(true);
                    }
                    console.log('[Thinspace] Claude private chat activated');
                    return;
                }
                tries += 1;
                if (tries < MAX_TRIES) {
                    setTimeout(attempt, 100);
                } else {
                    console.log('[Thinspace] Claude private chat control not found');
                }
            }

            attempt();
            return true;
        })();
        """
        runJavaScript(source, named: "open private chat", in: webView)
    }

    func toggleSidebar(in webView: WKWebView) {
        if page(for: webView.url ?? homeURL) == .code {
            let source = clickScript(
                selectors: [
                    "[data-sidebar=\"trigger\"]",
                    "button[aria-label*=\"toggle sidebar\" i]",
                    "button[aria-label*=\"open sidebar\" i]",
                    "button[aria-label*=\"close sidebar\" i]",
                    "button[title*=\"sidebar\" i]",
                    "button[data-testid*=\"sidebar\" i]"
                ],
                actionName: "Claude Code sidebar"
            )
            webView.evaluateJavaScript(source) { result, _ in
                if result as? Bool != true {
                    dispatchKeyboardShortcut(
                        key: "b", code: "KeyB", keyCode: 66, shift: false, in: webView
                    )
                }
            }
        } else {
            dispatchKeyboardShortcut(
                key: ".", code: "Period", keyCode: 190, shift: false, in: webView
            )
        }
    }

    func openNewProject(in webView: WKWebView) {
        dispatchKeyboardShortcut(
            key: "i", code: "KeyI", keyCode: 73, shift: true, in: webView
        )
    }

    func projectsURL() -> URL? {
        URL(string: "https://claude.ai/projects")
    }

    func codeURL() -> URL? {
        URL(string: "https://claude.ai/code")
    }

    func openProviderSettings(in webView: WKWebView) {
        dispatchKeyboardShortcut(
            key: ",", code: "Comma", keyCode: 188, shift: true, in: webView
        )
    }

    func focusComposer(in webView: WKWebView) {
        let source = retryingActionScript(
            selectors: [
                "div.ProseMirror[contenteditable=\"true\"]",
                "div[contenteditable=\"true\"][data-placeholder]",
                "textarea[placeholder*=\"Message\" i]",
                "textarea[placeholder*=\"Reply\" i]",
                "[contenteditable=\"true\"]",
                "textarea"
            ],
            action: .focus
        )
        runJavaScript(source, named: "focus composer", in: webView)
    }

    /// The path answers first, before any DOM query. Claude Code answers
    /// `true`: the Chat Bar expands for it as for a conversation, and a `true`
    /// disconnects the observer, where a `false` would keep it connected and
    /// rescanning the whole page for message nodes while a session streams.
    let conversationObserverSource = """
    function isInProviderConversation() {
        const path = window.location.pathname;
        if (path === '/chat' || path.startsWith('/chat/')) return true;
        if (path === '/code' || path.startsWith('/code/')) return true;
        if (document.querySelector('[data-testid="conversation-turn"]')) return true;
        if (document.querySelector('[data-is-streaming="true"]')) return true;
        const main = document.querySelector('main');
        if (!main) return false;
        return main.querySelectorAll('article, [data-turn], [class*="Message"]').length >= 2;
    }
    """

    let privateChatObserverSource = """
    function detectProviderPrivateChatState() {
        const urlState = privateChatStateFromURL();
        if (urlState !== null) return urlState;

        const controlState = privateChatStateFromElements([
            '[data-testid="incognito-chat-button"]',
            '[data-testid*="incognito" i]',
            'button[aria-label*="incognito" i]',
            'button[title*="incognito" i]',
            'button[aria-label*="private chat" i]',
            'button[title*="private chat" i]'
        ]);
        if (controlState !== null) return controlState;

        return hasPrivateChatIndicator([
            'main [role="status"]',
            'main [aria-label*="incognito" i]',
            'main [data-testid*="incognito" i]'
        ], /incognito|private chat/i) ? true : null;
    }
    """

    /// One-shot click: the Bool result feeds toggleSidebar's ⌘B fallback,
    /// so this must not retry and must not always return true.
    private func clickScript(selectors: [String], actionName: String) -> String {
        let encoded = selectors.map { Self.javaScriptString($0) }.joined(separator: ",")
        return """
        (function() {
            const selectors = [\(encoded)];
            for (const selector of selectors) {
                const element = document.querySelector(selector);
                if (element) {
                    element.click();
                    console.log('[Thinspace] \(actionName) toggled');
                    return true;
                }
            }
            return false;
        })();
        """
    }
}
