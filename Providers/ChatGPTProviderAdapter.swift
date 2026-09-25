//
//  ChatGPTProviderAdapter.swift
//  Thinspace
//

import Foundation
import WebKit

struct ChatGPTProviderAdapter: ProviderAdapter {
    let provider: LLMProvider = .chatgpt
    let homeURL = URL(string: "https://chatgpt.com/")!
    let applicationHosts = HostPolicy(domainSuffixes: ["chatgpt.com"])
    let authenticationHosts = HostPolicy(
        exactHosts: [
            "auth0.openai.com",
            "accounts.google.com",
            "appleid.apple.com",
            "login.live.com",
            "login.microsoftonline.com"
        ],
        domainSuffixes: ["auth.openai.com"]
    )
    let mediaHosts = HostPolicy(
        domainSuffixes: ["oaistatic.com", "oaiusercontent.com"]
    )
    let privateChatStartsAtHome = true

    func page(for url: URL) -> ProviderPage {
        guard let host = url.host, applicationHosts.contains(host) else { return .other }
        let path = normalizedPath(url.path)
        if path == "/" { return .home }
        if path.hasPrefix("/c/") ||
            (path.hasPrefix("/g/") && path.contains("/c/")) {
            return .conversation
        }
        return .other
    }

    /// Finds and activates ChatGPT's dynamically rendered Temporary Chat pill.
    func activatePrivateChat(in webView: WKWebView) {
        let source = """
        (function() {
            const selectors = [
                'button[data-testid="temporary-chat-button"]',
                '[role="button"][data-testid="temporary-chat-button"]',
                'button[data-testid="temporary-chat-toggle"]',
                '[role="button"][data-testid="temporary-chat-toggle"]',
                'button[aria-label="Temporary" i]',
                '[role="button"][aria-label="Temporary" i]',
                'button[title="Temporary" i]',
                '[role="button"][title="Temporary" i]',
                'button[aria-label="Turn on temporary chat" i]',
                '[data-testid*="temporary-chat" i]',
                '[data-testid*="temporary_chat" i]',
                'button[aria-label*="temporary chat" i]',
                'button[title*="temporary chat" i]',
                '[role="button"][aria-label*="temporary chat" i]'
            ];
            const MAX_TRIES = 50;
            const ACTIVE_STATES = new Set(['true', 'on', 'checked', 'active']);
            let tries = 0;

            \(ProviderJS.visible)

            function asClickable(element) {
                if (!element) return null;
                if (element.matches('button, [role="button"]')) return element;
                return element.closest('button, [role="button"]') ||
                    element.querySelector('button, [role="button"]');
            }

            \(ProviderJS.normalize)

            function names(element) {
                return [
                    element.getAttribute('aria-label'),
                    element.getAttribute('title'),
                    element.innerText,
                    element.textContent
                ].map(normalize).filter(Boolean);
            }

            function isTemporaryName(element) {
                return names(element).some(function(name) {
                    return /^(turn on |start )?temporary( chat)?$/i.test(name);
                });
            }

            function isInTopBand(element) {
                const rect = element.getBoundingClientRect();
                return rect.top >= 0 && rect.top <= Math.max(200, window.innerHeight * 0.3);
            }

            function stateElements(control, evidence) {
                return Array.from(new Set([
                    control,
                    evidence,
                    ...control.querySelectorAll('[aria-pressed], [aria-checked], [data-state]')
                ].filter(Boolean)));
            }

            function isActive(control, evidence) {
                if (new URL(window.location.href).searchParams.get('temporary-chat') === 'true') {
                    return true;
                }

                return stateElements(control, evidence).some(function(element) {
                    const values = [
                        element.getAttribute('aria-pressed'),
                        element.getAttribute('aria-checked'),
                        element.getAttribute('data-state')
                    ].map(function(value) { return normalize(value).toLowerCase(); });
                    if (values.some(function(value) { return ACTIVE_STATES.has(value); })) {
                        return true;
                    }
                    return names(element).some(function(name) {
                        return /(turn off|disable|exit|leave).*temporary|temporary.*(is on|active)/i
                            .test(name);
                    });
                });
            }

            function findControl() {
                for (const selector of selectors) {
                    try {
                        for (const evidence of document.querySelectorAll(selector)) {
                            const control = asClickable(evidence);
                            if (visible(control) && isInTopBand(control)) {
                                return { control: control, evidence: evidence };
                            }
                        }
                    } catch (_) {}
                }

                const control = Array.from(
                    document.querySelectorAll('button, [role="button"]')
                ).find(function(element) {
                    return visible(element) && isInTopBand(element) &&
                        isTemporaryName(element);
                });
                return control ? { control: control, evidence: control } : null;
            }

            function findTemporaryMenuItem() {
                return Array.from(document.querySelectorAll(
                    '[role="menuitem"], [role="menuitemradio"], [role="option"]'
                )).find(function(element) {
                    return visible(element) && names(element).some(function(name) {
                        return /^temporary( chat)?$/i.test(name);
                    });
                }) || null;
            }

            function verifyActivation(match, allowMenuFallback) {
                const currentMatch = findControl() || match;
                if (isActive(currentMatch.control, currentMatch.evidence)) {
                    if (window.__thinspaceSetPrivateChatState) {
                        window.__thinspaceSetPrivateChatState(true);
                    }
                    console.log('[Thinspace] ChatGPT temporary chat activated');
                    return;
                }

                const menuItem = allowMenuFallback ? findTemporaryMenuItem() : null;
                if (menuItem) {
                    menuItem.click();
                    setTimeout(function() {
                        verifyActivation(match, false);
                    }, 200);
                    return;
                }

                if (window.__thinspaceSetPrivateChatState) {
                    window.__thinspaceSetPrivateChatState(true);
                }
                console.log('[Thinspace] ChatGPT temporary chat control clicked; state not exposed');
            }

            function attempt() {
                const match = findControl();
                if (match) {
                    if (isActive(match.control, match.evidence)) {
                        if (window.__thinspaceSetPrivateChatState) {
                            window.__thinspaceSetPrivateChatState(true);
                        }
                        console.log('[Thinspace] ChatGPT temporary chat already active');
                        return;
                    }
                    match.control.click();
                    setTimeout(function() {
                        verifyActivation(match, true);
                    }, 200);
                    return;
                }

                tries += 1;
                if (tries < MAX_TRIES) {
                    setTimeout(attempt, 100);
                } else {
                    console.log('[Thinspace] ChatGPT temporary chat control not found');
                }
            }

            if (document.activeElement instanceof HTMLElement) document.activeElement.blur();
            attempt();
            return true;
        })();
        """
        runJavaScript(source, named: "open private chat", in: webView)
    }

    func toggleSidebar(in webView: WKWebView) {
        dispatchKeyboardShortcut(
            key: "s", code: "KeyS", keyCode: 83, shift: true, in: webView
        )
    }

    func focusComposer(in webView: WKWebView) {
        let source = retryingActionScript(
            selectors: [
                "#prompt-textarea",
                "[data-testid=\"composer-text-input\"]",
                "div.ProseMirror[contenteditable=\"true\"]",
                "div[contenteditable=\"true\"][data-placeholder]",
                "textarea[placeholder*=\"Message\" i]",
                "[contenteditable=\"true\"]",
                "textarea"
            ],
            action: .focus
        )
        runJavaScript(source, named: "focus composer", in: webView)
    }

    let conversationObserverSource = """
    function isInProviderConversation() {
        const path = window.location.pathname;
        if (path.startsWith('/c/')) return true;
        if (path.startsWith('/g/') && path.includes('/c/')) return true;
        return document.querySelector(
            '[data-testid^="conversation-turn-"], [data-message-author-role]'
        ) !== null;
    }
    """

    let privateChatObserverSource = """
    function detectProviderPrivateChatState() {
        const urlState = privateChatStateFromURL();
        if (urlState !== null) return urlState;

        const controlState = privateChatStateFromElements([
            'button[data-testid="temporary-chat-button"]',
            '[role="button"][data-testid="temporary-chat-button"]',
            'button[data-testid="temporary-chat-toggle"]',
            '[role="button"][data-testid="temporary-chat-toggle"]',
            'button[aria-label*="temporary chat" i]',
            'button[title*="temporary chat" i]',
            '[role="button"][aria-label*="temporary chat" i]'
        ]);
        if (controlState !== null) return controlState;

        return hasPrivateChatIndicator([
            'main [role="status"]',
            'main [data-testid*="temporary-chat" i]',
            'main [aria-label*="temporary chat" i]'
        ], /temporary( chat)?/i) ? true : null;
    }
    """
}
