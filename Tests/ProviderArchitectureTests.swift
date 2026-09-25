//
//  ProviderArchitectureTests.swift
//  ThinspaceTests
//

import Foundation
import AppKit
import JavaScriptCore
import KeyboardShortcuts
import WebKit
import XCTest
@testable import Thinspace

private class RecordingWebView: WKWebView {
    private(set) var evaluatedScripts: [String] = []
    private(set) var loadedRequests: [URLRequest] = []

    override func evaluateJavaScript(
        _ javaScriptString: String,
        completionHandler: (@MainActor @Sendable (Any?, (any Error)?) -> Void)? = nil
    ) {
        evaluatedScripts.append(javaScriptString)
        completionHandler?(true, nil)
    }

    override func load(_ request: URLRequest) -> WKNavigation? {
        loadedRequests.append(request)
        return nil
    }
}

/// Reports a claude.ai/code URL so adapter actions that branch on the current
/// page exercise their Code-page path.
private final class CodePageWebView: RecordingWebView {
    override var url: URL? { URL(string: "https://claude.ai/code") }
}

final class LLMProviderTests: XCTestCase {
    func testProviderIdentityIsStableAndComplete() {
        XCTAssertEqual(LLMProvider.allCases, [.claude, .gemini, .chatgpt])
        XCTAssertEqual(LLMProvider.claude.id, "claude")
        XCTAssertEqual(LLMProvider.gemini.id, "gemini")
        XCTAssertEqual(LLMProvider.chatgpt.id, "chatgpt")
        XCTAssertEqual(LLMProvider.claude.displayName, "Claude")
        XCTAssertEqual(LLMProvider.gemini.displayName, "Gemini")
        XCTAssertEqual(LLMProvider.chatgpt.displayName, "ChatGPT")
        XCTAssertEqual(LLMProvider.defaultsKey, "activeLLMProvider")
    }

    func testChatBarInitialShortcutIsOptionSpace() {
        XCTAssertEqual(
            KeyboardShortcuts.Name.bringToFront.initialShortcut,
            KeyboardShortcuts.Shortcut(.space, modifiers: [.option])
        )
    }

    func testClaudeCapabilitiesIncludeItsProviderSpecificSurfaces() {
        let capabilities = LLMProvider.claude.capabilities

        XCTAssertTrue(capabilities.contains(.newChat))
        XCTAssertTrue(capabilities.contains(.privateChat))
        XCTAssertTrue(capabilities.contains(.sidebar))
        XCTAssertTrue(capabilities.contains(.projects))
        XCTAssertTrue(capabilities.contains(.newProject))
        XCTAssertTrue(capabilities.contains(.claudeCode))
        XCTAssertTrue(capabilities.contains(.providerSettings))
    }

    func testGeminiCapabilitiesStayMinimal() {
        let capabilities = LLMProvider.gemini.capabilities

        XCTAssertTrue(capabilities.contains(.newChat))
        XCTAssertTrue(capabilities.contains(.privateChat))
        XCTAssertTrue(capabilities.contains(.sidebar))
        XCTAssertFalse(capabilities.contains(.projects))
        XCTAssertFalse(capabilities.contains(.newProject))
        XCTAssertFalse(capabilities.contains(.claudeCode))
        XCTAssertFalse(capabilities.contains(.providerSettings))
    }

    func testChatGPTCapabilitiesStayMinimal() {
        let capabilities = LLMProvider.chatgpt.capabilities

        XCTAssertTrue(capabilities.contains(.newChat))
        XCTAssertTrue(capabilities.contains(.privateChat))
        XCTAssertTrue(capabilities.contains(.sidebar))
        XCTAssertFalse(capabilities.contains(.projects))
        XCTAssertFalse(capabilities.contains(.newProject))
        XCTAssertFalse(capabilities.contains(.claudeCode))
        XCTAssertFalse(capabilities.contains(.providerSettings))
    }

    func testAdapterFactoryKeepsProviderIdentity() {
        for provider in LLMProvider.allCases {
            XCTAssertEqual(ProviderAdapters.adapter(for: provider).provider, provider)
        }
    }

    func testProviderDataStoresHaveDistinctStableIdentities() {
        let claudeIdentifier = WebViewModel.dataStoreIdentifier(for: .claude)
        let geminiIdentifier = WebViewModel.dataStoreIdentifier(for: .gemini)
        let chatGPTIdentifier = WebViewModel.dataStoreIdentifier(for: .chatgpt)

        XCTAssertEqual(
            claudeIdentifier,
            UUID(uuidString: "A1C4A7DE-9F3E-4B48-96C5-7C680CB57401")
        )
        XCTAssertEqual(
            geminiIdentifier,
            UUID(uuidString: "6E3B9C21-D4F8-4A75-AD12-8519B7E26002")
        )
        XCTAssertEqual(
            chatGPTIdentifier,
            UUID(uuidString: "C8F2D5A4-7B19-4E63-AB20-94D7F6103003")
        )
        XCTAssertEqual(Set([claudeIdentifier, geminiIdentifier, chatGPTIdentifier]).count, 3)
        XCTAssertEqual(claudeIdentifier, WebViewModel.dataStoreIdentifier(for: .claude))
        XCTAssertEqual(geminiIdentifier, WebViewModel.dataStoreIdentifier(for: .gemini))
        XCTAssertEqual(chatGPTIdentifier, WebViewModel.dataStoreIdentifier(for: .chatgpt))
    }
}

final class ChatBarPresentationTests: XCTestCase {
    @MainActor
    func testHidingMainWindowDoesNotTerminateChatBarApp() {
        XCTAssertFalse(
            AppDelegate().applicationShouldTerminateAfterLastWindowClosed(
                NSApplication.shared
            )
        )
    }

    func testGlassChromeAndSwipeAnimationsStayRestrained() {
        XCTAssertEqual(ChatBarPanel.Constants.glassRimWidth, 10)
        XCTAssertEqual(ChatBarPanel.Constants.chromeExpansion, 20)
        XCTAssertEqual(ChatBarPanel.Constants.innerCornerRadius, 20)
        XCTAssertLessThanOrEqual(ChatBarPanel.Constants.showDuration, 0.16)
        XCTAssertLessThanOrEqual(ChatBarPanel.Constants.hideDuration, 0.12)
        XCTAssertLessThanOrEqual(ChatBarPanel.Constants.verticalMotionOffset, 20)
        XCTAssertEqual(
            ChatBarPanel.Constants.privateChatTintColor.alphaComponent,
            0.50,
            accuracy: 0.001
        )

        let expectedNormalTints: [LLMProvider: NSColor] = [
            .gemini: NSColor.systemBlue.withAlphaComponent(0.10),
            .claude: NSColor.systemOrange.withAlphaComponent(0.10),
            .chatgpt: NSColor.white.withAlphaComponent(0.10)
        ]
        for (provider, expectedColor) in expectedNormalTints {
            let tint = ChatBarPanel.Constants.normalChatTintColor(for: provider)
            XCTAssertEqual(tint.alphaComponent, 0.10, accuracy: 0.001)
            XCTAssertEqual(tint, expectedColor, provider.displayName)
        }
    }

    func testWindowFrameIsAnimatableButFrameOriginIsNot() {
        XCTAssertNotNil(NSWindow.defaultAnimation(forKey: "frame"))
        XCTAssertNil(NSWindow.defaultAnimation(forKey: "frameOrigin"))
    }

    func testGlassChromeGrowsOutsideThePersistedContentBox() {
        let contentSize = NSSize(width: 500, height: 459)
        let panelSize = ChatBarPanel.panelSize(forContentSize: contentSize)

        XCTAssertEqual(panelSize, NSSize(width: 520, height: 479))
        XCTAssertEqual(
            ChatBarPanel.contentSize(forPanelSize: panelSize),
            contentSize
        )

        let contentOrigin = NSPoint(x: 300, y: 50)
        let panelOrigin = ChatBarPanel.panelOrigin(
            forContentOrigin: contentOrigin
        )
        XCTAssertEqual(panelOrigin, NSPoint(x: 290, y: 40))
        XCTAssertEqual(
            ChatBarPanel.contentOrigin(forPanelOrigin: panelOrigin),
            contentOrigin
        )
    }
}

final class ProviderUserScriptTests: XCTestCase {
    func testEveryProviderInstallsItsPrivateChatDetector() {
        for provider in LLMProvider.allCases {
            let adapter = ProviderAdapters.adapter(for: provider)
            let privateChatScripts = UserScripts.createAllScripts(for: adapter).filter {
                $0.source.contains("__thinspacePrivateChatObserverInstalled")
            }

            XCTAssertEqual(privateChatScripts.count, 1, provider.displayName)
            XCTAssertTrue(
                privateChatScripts[0].source.contains(adapter.privateChatObserverSource),
                provider.displayName
            )
            XCTAssertTrue(
                privateChatScripts[0].source.contains(UserScripts.privateChatStateHandler),
                provider.displayName
            )
        }
    }

    func testEveryProviderPrivateChatObserverHasValidJavaScriptSyntax() throws {
        let context = try XCTUnwrap(JSContext())

        for provider in LLMProvider.allCases {
            let adapter = ProviderAdapters.adapter(for: provider)
            let source = try XCTUnwrap(
                UserScripts.createAllScripts(for: adapter).first {
                    $0.source.contains("__thinspacePrivateChatObserverInstalled")
                }?.source
            )
            let encodedData = try JSONSerialization.data(
                withJSONObject: source,
                options: .fragmentsAllowed
            )
            let encodedSource = try XCTUnwrap(
                String(data: encodedData, encoding: .utf8)
            )

            context.exception = nil
            context.evaluateScript("new Function(\(encodedSource));")
            XCTAssertNil(context.exception, provider.displayName)
        }
    }

    /// The conversation observer and the activation scripts interpolate shared
    /// Swift-side JS snippets; a broken interpolation would kill the feature
    /// silently, since WebKit drops an unparseable user script without error.
    func testEveryProviderConversationObserverHasValidJavaScriptSyntax() throws {
        let context = try XCTUnwrap(JSContext())

        for provider in LLMProvider.allCases {
            let adapter = ProviderAdapters.adapter(for: provider)
            let source = try XCTUnwrap(
                UserScripts.createAllScripts(for: adapter).first {
                    $0.source.contains("__thinspaceConversationObserverInstalled")
                }?.source
            )
            XCTAssertTrue(
                source.contains("new MutationObserver(onMutations)"),
                provider.displayName
            )

            let encodedData = try JSONSerialization.data(
                withJSONObject: source,
                options: .fragmentsAllowed
            )
            let encodedSource = try XCTUnwrap(
                String(data: encodedData, encoding: .utf8)
            )
            context.exception = nil
            context.evaluateScript("new Function(\(encodedSource));")
            XCTAssertNil(context.exception, provider.displayName)
        }
    }

    func testEveryProviderPrivateChatActivationScriptHasValidJavaScriptSyntax() throws {
        let context = try XCTUnwrap(JSContext())

        for provider in LLMProvider.allCases {
            let webView = RecordingWebView()
            ProviderAdapters.adapter(for: provider).activatePrivateChat(in: webView)
            let source = try XCTUnwrap(
                webView.evaluatedScripts.last,
                provider.displayName
            )
            XCTAssertTrue(
                source.contains("function visible(element) {"),
                provider.displayName
            )

            let encodedData = try JSONSerialization.data(
                withJSONObject: source,
                options: .fragmentsAllowed
            )
            let encodedSource = try XCTUnwrap(
                String(data: encodedData, encoding: .utf8)
            )
            context.exception = nil
            context.evaluateScript("new Function(\(encodedSource));")
            XCTAssertNil(context.exception, provider.displayName)
        }

        // The whitespace regex is the classic escape casualty: one wrong
        // backslash turns it into a literal-`s` match and every name
        // comparison quietly breaks.
        let chatGPT = RecordingWebView()
        ChatGPTProviderAdapter().activatePrivateChat(in: chatGPT)
        XCTAssertTrue(
            chatGPT.evaluatedScripts.last?.contains(#"replace(/\s+/g, ' ')"#) == true
        )
    }

    func testEveryProviderNormalChatActionClearsPagePrivateState() {
        for provider in LLMProvider.allCases {
            let webView = RecordingWebView()
            ProviderAdapters.adapter(for: provider).openNewChat(in: webView)

            XCTAssertTrue(
                webView.evaluatedScripts.contains {
                    $0.contains("__thinspaceSetPrivateChatState(false)")
                },
                provider.displayName
            )
        }
    }

    func testClaudePrivateChatExitLoadsNormalHomeWhileOthersUseNewChatAction() {
        let claudeWebView = RecordingWebView()
        ClaudeProviderAdapter().exitPrivateChat(in: claudeWebView)
        XCTAssertEqual(
            claudeWebView.loadedRequests.last?.url,
            ClaudeProviderAdapter().homeURL
        )

        for adapter in [
            ProviderAdapters.adapter(for: .gemini),
            ProviderAdapters.adapter(for: .chatgpt)
        ] {
            let webView = RecordingWebView()
            adapter.exitPrivateChat(in: webView)
            XCTAssertTrue(webView.loadedRequests.isEmpty, adapter.provider.displayName)
            XCTAssertTrue(
                webView.evaluatedScripts.contains {
                    $0.contains("__thinspaceSetPrivateChatState(false)")
                },
                adapter.provider.displayName
            )
        }
    }

    /// Claude Code and conversations must answer from the path before any DOM
    /// query: a `true` disconnects the observer, and on Claude Code the
    /// fallback scan would otherwise sweep the page on every streamed batch.
    func testClaudeConversationDetectorAnswersFromThePathBeforeTheDOM() throws {
        let detector = ClaudeProviderAdapter().conversationObserverSource

        for path in ["/code", "/code/session-id", "/chat/thread-id"] {
            let context = try XCTUnwrap(JSContext())
            context.evaluateScript("""
            var window = { location: { pathname: '\(path)' } };
            var document = {
                querySelector: function() { throw new Error('DOM queried'); },
                querySelectorAll: function() { throw new Error('DOM queried'); }
            };
            """)
            context.evaluateScript(detector)
            let result = context.evaluateScript("isInProviderConversation()")
            XCTAssertNil(context.exception, path)
            XCTAssertEqual(result?.toBool(), true, path)
        }

        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        var window = { location: { pathname: '/new' } };
        var document = { querySelector: function() { return null; } };
        """)
        context.evaluateScript(detector)
        let result = context.evaluateScript("isInProviderConversation()")
        XCTAssertNil(context.exception)
        XCTAssertEqual(result?.toBool(), false)
    }

    /// Every detection pass runs the provider's whole-page queries, so a click
    /// schedules one only when it can change private mode. Links and new chats
    /// that navigate are covered by the history hooks instead.
    func testPrivateChatObserverSchedulesDetectionOnlyForRelevantClicks() throws {
        for provider in LLMProvider.allCases {
            let name = provider.displayName

            XCTAssertEqual(
                try timersScheduledByClick(on: provider, attributes: ["aria-label": "Copy"]),
                0, name
            )
            XCTAssertEqual(
                try timersScheduledByClick(
                    on: provider,
                    attributes: ["href": "/chat/thread-id"],
                    text: "Quarterly planning"
                ),
                0, name
            )
            XCTAssertEqual(
                try timersScheduledByClick(on: provider, attributes: ["aria-label": "New chat"]),
                0, name
            )

            XCTAssertGreaterThan(
                try timersScheduledByClick(on: provider, attributes: ["aria-label": "Incognito chat"]),
                0, name
            )
            XCTAssertGreaterThan(
                try timersScheduledByClick(on: provider, attributes: [:], text: "Temporary chat"),
                0, name
            )
            XCTAssertGreaterThan(
                try timersScheduledByClick(
                    on: provider,
                    attributes: ["data-testid": "incognito-chat-button"]
                ),
                0, name
            )
            XCTAssertGreaterThan(
                try timersScheduledByClick(
                    on: provider,
                    attributes: ["data-test-id": "temp-chat-button"]
                ),
                0, name
            )
            XCTAssertGreaterThan(
                try timersScheduledByClick(
                    on: provider,
                    attributes: ["aria-label": "New chat"],
                    whilePrivate: true
                ),
                0, name
            )
        }
    }

    /// Just enough DOM for the private-chat observer to install and start in a
    /// bare JSContext. Timers are recorded, and run only when flushed.
    private static let privateObserverHarness = """
    var pending = [];
    function setTimeout(callback, delay) { pending.push(callback); return pending.length; }
    function flush() {
        for (var rounds = 0; pending.length && rounds < 10; rounds++) {
            var due = pending;
            pending = [];
            due.forEach(function(callback) { callback(); });
        }
    }
    function getComputedStyle() { return { visibility: 'visible', display: 'block' }; }
    function Element() {}
    var clickListener = null;
    var window = {
        location: { href: 'https://example.com/', pathname: '/' },
        addEventListener: function() {}
    };
    var document = {
        readyState: 'complete',
        body: {},
        addEventListener: function(type, listener) {
            if (type === 'click') clickListener = listener;
        },
        querySelector: function() { return null; },
        querySelectorAll: function() { return []; }
    };
    var history = { pushState: function() {}, replaceState: function() {} };
    function click(attributes, text) {
        var control = Object.create(Element.prototype);
        control.getAttribute = function(name) {
            return Object.prototype.hasOwnProperty.call(attributes, name)
                ? attributes[name] : null;
        };
        control.closest = function() { return control; };
        control.childNodes = text ? [{ textContent: text }] : [];
        control.textContent = text;
        pending = [];
        clickListener({ target: control });
        return pending.length;
    }
    """

    /// Counts the timers one click schedules in a freshly installed observer.
    /// `whilePrivate` first confirms private mode the way native actions do.
    private func timersScheduledByClick(
        on provider: LLMProvider,
        attributes: [String: String],
        text: String = "",
        whilePrivate: Bool = false
    ) throws -> Int {
        let observer = try XCTUnwrap(
            UserScripts.createAllScripts(for: ProviderAdapters.adapter(for: provider)).first {
                $0.source.contains("__thinspacePrivateChatObserverInstalled")
            }?.source
        )
        let attributesJSON = try XCTUnwrap(
            String(data: JSONSerialization.data(withJSONObject: attributes), encoding: .utf8)
        )
        let textJSON = try XCTUnwrap(
            String(
                data: JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed),
                encoding: .utf8
            )
        )

        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(Self.privateObserverHarness)
        context.evaluateScript(observer)
        if whilePrivate {
            context.evaluateScript("window.__thinspaceSetPrivateChatState(true); flush();")
        }
        let count = context.evaluateScript("click(\(attributesJSON), \(textJSON))")
        XCTAssertNil(context.exception, provider.displayName)
        return Int(count?.toInt32() ?? -1)
    }
}

/// Pins the JavaScript each provider action emits, byte for byte. The shared
/// `retryingActionScript` generator replaced hand-copied literals; these
/// goldens are what let that refactor prove it changed nothing.
final class ProviderActionScriptTests: XCTestCase {
    func testClaudeFocusComposerEmitsGoldenScript() {
        let webView = RecordingWebView()
        ClaudeProviderAdapter().focusComposer(in: webView)

        XCTAssertEqual(webView.evaluatedScripts.last, #"""
        (function() {
            const selectors = [
                "div.ProseMirror[contenteditable=\"true\"]",
                "div[contenteditable=\"true\"][data-placeholder]",
                "textarea[placeholder*=\"Message\" i]",
                "textarea[placeholder*=\"Reply\" i]",
                "[contenteditable=\"true\"]",
                "textarea"
            ];
            let tries = 0;
            function attempt() {
                for (const selector of selectors) {
                    const input = document.querySelector(selector);
                    if (input) { input.focus(); return; }
                }
                if (++tries < 40) setTimeout(attempt, 75);
            }
            attempt();
            return true;
        })();
        """#)
    }

    func testChatGPTFocusComposerEmitsGoldenScript() {
        let webView = RecordingWebView()
        ChatGPTProviderAdapter().focusComposer(in: webView)

        XCTAssertEqual(webView.evaluatedScripts.last, #"""
        (function() {
            const selectors = [
                "#prompt-textarea",
                "[data-testid=\"composer-text-input\"]",
                "div.ProseMirror[contenteditable=\"true\"]",
                "div[contenteditable=\"true\"][data-placeholder]",
                "textarea[placeholder*=\"Message\" i]",
                "[contenteditable=\"true\"]",
                "textarea"
            ];
            let tries = 0;
            function attempt() {
                for (const selector of selectors) {
                    const input = document.querySelector(selector);
                    if (input) { input.focus(); return; }
                }
                if (++tries < 40) setTimeout(attempt, 75);
            }
            attempt();
            return true;
        })();
        """#)
    }

    func testGeminiToggleSidebarEmitsGoldenScript() {
        let webView = RecordingWebView()
        GeminiProviderAdapter().toggleSidebar(in: webView)

        XCTAssertEqual(webView.evaluatedScripts.last, #"""
        (function() {
            const selectors = [
                "button[aria-label*=\"Main menu\" i]",
                "button[aria-label*=\"Open sidebar\" i]",
                "button[aria-label*=\"Close sidebar\" i]",
                "button[aria-label*=\"sidebar\" i]",
                "button[data-test-id=\"side-nav-toggle\"]"
            ];
            let tries = 0;
            function attempt() {
                for (const selector of selectors) {
                    const button = document.querySelector(selector);
                    if (button) { button.click(); return; }
                }
                if (++tries < 40) setTimeout(attempt, 75);
            }
            attempt();
            return true;
        })();
        """#)
    }

    /// Gemini's composer focus deliberately keeps its scoped `||` chain; this
    /// pins it so a future "cleanup" cannot silently flatten the scoping.
    func testGeminiFocusComposerKeepsItsScopedChain() {
        let webView = RecordingWebView()
        GeminiProviderAdapter().focusComposer(in: webView)

        let script = webView.evaluatedScripts.last ?? ""
        XCTAssertTrue(script.contains(
            "rich && rich.querySelector('[contenteditable=\"true\"]')"
        ))
        XCTAssertTrue(script.contains("div.ql-editor[contenteditable=\"true\"]"))
    }

    /// Regression test for the JSONSerialization abort: encoding a bare String
    /// as a JSON top level raised an uncatchable NSInvalidArgumentException on
    /// every Code-page sidebar toggle. The one-shot script must keep returning
    /// a real Bool so the ⌘B fallback stays reachable.
    func testClaudeCodeSidebarToggleEmitsOneShotClickScript() {
        let webView = CodePageWebView()
        ClaudeProviderAdapter().toggleSidebar(in: webView)

        let script = webView.evaluatedScripts.last ?? ""
        XCTAssertTrue(script.contains(#""[data-sidebar=\"trigger\"]""#))
        XCTAssertTrue(script.contains("console.log('[Thinspace] Claude Code sidebar toggled');"))
        XCTAssertTrue(script.contains("return false;"))
        XCTAssertFalse(script.contains("setTimeout"), "the click script must stay one-shot")
    }
}

final class HostPolicyTests: XCTestCase {
    func testExactHostsAllowOnlyTheExactNormalizedHost() {
        let policy = HostPolicy(exactHosts: ["Gemini.Google.Com."])

        XCTAssertTrue(policy.contains("gemini.google.com"))
        XCTAssertTrue(policy.contains("GEMINI.GOOGLE.COM."))
        XCTAssertFalse(policy.contains("www.gemini.google.com"))
        XCTAssertFalse(policy.contains("gemini.google.com.example.org"))
        XCTAssertFalse(policy.contains("evilgemini.google.com"))
    }

    func testDomainSuffixesAllowApexAndDotDelimitedSubdomains() {
        let policy = HostPolicy(domainSuffixes: ["anthropic.com"])

        XCTAssertTrue(policy.contains("anthropic.com"))
        XCTAssertTrue(policy.contains("console.anthropic.com"))
        XCTAssertTrue(policy.contains("deep.console.anthropic.com"))
        XCTAssertFalse(policy.contains("notanthropic.com"))
        XCTAssertFalse(policy.contains("anthropic.com.example.org"))
    }

    func testEmptyPolicyRejectsEveryHost() {
        let policy = HostPolicy()

        XCTAssertFalse(policy.contains("claude.ai"))
        XCTAssertFalse(policy.contains(""))
    }
}

final class ProviderRoutingTests: XCTestCase {
    private let claude = ClaudeProviderAdapter()
    private let gemini = GeminiProviderAdapter()
    private let chatGPT = ChatGPTProviderAdapter()

    func testClaudeRoutesKnownSurfaces() throws {
        XCTAssertEqual(claude.page(for: try url("https://claude.ai/")), .home)
        XCTAssertEqual(claude.page(for: try url("https://claude.ai/new/")), .home)
        XCTAssertEqual(claude.page(for: try url("https://claude.ai/chat/thread-id")), .conversation)
        XCTAssertEqual(claude.page(for: try url("https://claude.ai/projects")), .projects)
        XCTAssertEqual(claude.page(for: try url("https://claude.ai/projects/project-id")), .projects)
        XCTAssertEqual(claude.page(for: try url("https://claude.ai/code/session-id")), .code)
        XCTAssertEqual(claude.page(for: try url("https://claude.ai/settings")), .other)
        XCTAssertEqual(claude.page(for: try url("https://claude.ai.example.org/chat/id")), .other)
    }

    func testGeminiRoutesKnownSurfaces() throws {
        XCTAssertEqual(gemini.page(for: try url("https://gemini.google.com/")), .home)
        XCTAssertEqual(gemini.page(for: try url("https://gemini.google.com/app/")), .home)
        XCTAssertEqual(gemini.page(for: try url("https://gemini.google.com/app/thread-id")), .conversation)
        XCTAssertEqual(gemini.page(for: try url("https://gemini.google.com/settings")), .other)
        XCTAssertEqual(gemini.page(for: try url("https://gemini.google.com.example.org/app/id")), .other)
    }

    func testChatGPTRoutesKnownSurfaces() throws {
        XCTAssertEqual(chatGPT.page(for: try url("https://chatgpt.com/")), .home)
        XCTAssertEqual(chatGPT.page(for: try url("https://chatgpt.com/c/thread-id")), .conversation)
        XCTAssertEqual(
            chatGPT.page(for: try url("https://chatgpt.com/g/gpt-id/c/thread-id")),
            .conversation
        )
        XCTAssertEqual(chatGPT.page(for: try url("https://chatgpt.com/settings")), .other)
        XCTAssertEqual(chatGPT.page(for: try url("https://chatgpt.com.example.org/c/id")), .other)
    }

    /// Resume seeds conversation state from these answers before the page
    /// loads; each must match what the in-page detector reports for the path.
    func testConversationSurfacesMatchTheInPageDetectorPaths() throws {
        XCTAssertTrue(claude.isConversationSurface(try url("https://claude.ai/chat/thread-id")))
        XCTAssertTrue(claude.isConversationSurface(try url("https://claude.ai/code")))
        XCTAssertTrue(claude.isConversationSurface(try url("https://claude.ai/code/session-id")))
        XCTAssertFalse(claude.isConversationSurface(try url("https://claude.ai/new")))
        XCTAssertFalse(claude.isConversationSurface(try url("https://claude.ai/projects")))
        XCTAssertFalse(claude.isConversationSurface(try url("https://claude.ai/settings")))

        XCTAssertTrue(gemini.isConversationSurface(try url("https://gemini.google.com/app/thread-id")))
        XCTAssertFalse(gemini.isConversationSurface(try url("https://gemini.google.com/app")))

        XCTAssertTrue(chatGPT.isConversationSurface(try url("https://chatgpt.com/c/thread-id")))
        XCTAssertTrue(
            chatGPT.isConversationSurface(try url("https://chatgpt.com/g/gpt-id/c/thread-id"))
        )
        XCTAssertFalse(chatGPT.isConversationSurface(try url("https://chatgpt.com/")))
    }

    func testClaudeClassifiesApplicationAuthenticationMediaAndExternalURLs() throws {
        XCTAssertEqual(claude.classify(try url("https://claude.ai/new")), .application)
        XCTAssertEqual(claude.classify(try url("https://accounts.google.com/signin")), .authentication)
        XCTAssertEqual(claude.classify(try url("https://api.anthropic.com/login")), .authentication)
        XCTAssertEqual(claude.classify(try url("https://cdn.claudeusercontent.com/file")), .media)
        XCTAssertEqual(claude.classify(try url("https://claude.ai.example.org/new")), .external)
    }

    func testGeminiClassifiesApplicationAuthenticationMediaAndExternalURLs() throws {
        XCTAssertEqual(gemini.classify(try url("https://gemini.google.com/app")), .application)
        XCTAssertEqual(gemini.classify(try url("https://accounts.google.com/signin")), .authentication)
        XCTAssertEqual(gemini.classify(try url("https://lh3.googleusercontent.com/image")), .media)
        XCTAssertEqual(gemini.classify(try url("https://evilgoogle.com/app")), .external)
    }

    /// Google sign-in redirects through these before returning to Gemini.
    /// Classifying any of them `.external` hands the flow to the default
    /// browser mid-login and the user never gets back to a signed-in app.
    func testGeminiKeepsGoogleSignInRedirectsInApp() throws {
        XCTAssertEqual(
            gemini.classify(try url("https://consent.google.com/ui")),
            .authentication
        )
        XCTAssertEqual(
            gemini.classify(try url("https://myaccount.google.com/signinoptions")),
            .authentication
        )
        XCTAssertEqual(
            gemini.classify(try url("https://accounts.youtube.com/accounts/CheckConnection")),
            .authentication
        )
        // The lookalike guard must still hold for the widened policy.
        XCTAssertEqual(
            gemini.classify(try url("https://consent.google.com.evil.com/ui")),
            .external
        )
    }

    func testChatGPTClassifiesApplicationAuthenticationMediaAndExternalURLs() throws {
        XCTAssertEqual(chatGPT.classify(try url("https://chatgpt.com/")), .application)
        XCTAssertEqual(chatGPT.classify(try url("https://beta.chatgpt.com/c/id")), .application)
        XCTAssertEqual(chatGPT.classify(try url("https://auth.openai.com/authorize")), .authentication)
        XCTAssertEqual(chatGPT.classify(try url("https://auth0.openai.com/authorize")), .authentication)
        XCTAssertEqual(chatGPT.classify(try url("https://accounts.google.com/signin")), .authentication)
        XCTAssertEqual(chatGPT.classify(try url("https://appleid.apple.com/auth")), .authentication)
        XCTAssertEqual(
            chatGPT.classify(try url("https://login.microsoftonline.com/common/oauth2")),
            .authentication
        )
        XCTAssertEqual(
            chatGPT.classify(try url("https://login.live.com/oauth20_authorize.srf")),
            .authentication
        )
        XCTAssertEqual(chatGPT.classify(try url("https://cdn.oaistatic.com/assets/app.js")), .media)
        XCTAssertEqual(chatGPT.classify(try url("https://files.oaiusercontent.com/file")), .media)
        XCTAssertEqual(chatGPT.classify(try url("https://evilchatgpt.com/c/id")), .external)
        XCTAssertEqual(chatGPT.classify(try url("https://chatgpt.com.example.org/c/id")), .external)
    }

    func testChatGPTPrivateChatStartsFromHomeBeforeFindingTemporaryControl() {
        XCTAssertTrue(chatGPT.capabilities.contains(.privateChat))
        XCTAssertTrue(chatGPT.privateChatStartsAtHome)
    }

    func testProviderSpecificDestinationURLsAndPrivateChatEntry() {
        XCTAssertEqual(claude.homeURL.absoluteString, "https://claude.ai/new")
        XCTAssertEqual(claude.projectsURL()?.absoluteString, "https://claude.ai/projects")
        XCTAssertEqual(claude.codeURL()?.absoluteString, "https://claude.ai/code")
        XCTAssertTrue(claude.privateChatStartsAtHome)

        XCTAssertEqual(gemini.homeURL.absoluteString, "https://gemini.google.com/app")
        XCTAssertNil(gemini.projectsURL())
        XCTAssertNil(gemini.codeURL())
        XCTAssertFalse(gemini.privateChatStartsAtHome)

        XCTAssertEqual(chatGPT.homeURL.absoluteString, "https://chatgpt.com/")
        XCTAssertNil(chatGPT.projectsURL())
        XCTAssertNil(chatGPT.codeURL())
        XCTAssertTrue(chatGPT.privateChatStartsAtHome)
    }

    private func url(_ string: String) throws -> URL {
        try XCTUnwrap(URL(string: string))
    }
}

final class PageZoomTests: XCTestCase {
    func testLadderIsStrictlyAscendingAndAnchored() {
        XCTAssertEqual(PageZoom.ladder, PageZoom.ladder.sorted())
        XCTAssertEqual(Set(PageZoom.ladder).count, PageZoom.ladder.count)
        XCTAssertTrue(PageZoom.ladder.contains(PageZoom.defaultZoom))
        XCTAssertEqual(PageZoom.minimum, 0.5)
        XCTAssertEqual(PageZoom.maximum, 2.0)
    }

    func testStepsWalkAdjacentStopsAndClampAtTheEnds() {
        for (below, above) in zip(PageZoom.ladder, PageZoom.ladder.dropFirst()) {
            XCTAssertEqual(PageZoom.stepUp(from: below), above)
            XCTAssertEqual(PageZoom.stepDown(from: above), below)
        }
        XCTAssertEqual(PageZoom.stepUp(from: PageZoom.maximum), PageZoom.maximum)
        XCTAssertEqual(PageZoom.stepDown(from: PageZoom.minimum), PageZoom.minimum)
    }

    func testStepsFromOffLadderValuesReachTheSurroundingStops() {
        XCTAssertEqual(PageZoom.stepUp(from: 0.97), 1.0)
        XCTAssertEqual(PageZoom.stepDown(from: 0.97), 0.85)
    }

    func testNearestSnapsLegacyAndOutOfRangeValues() {
        XCTAssertEqual(PageZoom.nearest(to: 0), 1.0)
        XCTAssertEqual(PageZoom.nearest(to: -1), 1.0)
        XCTAssertEqual(PageZoom.nearest(to: 0.97), 1.0)
        XCTAssertEqual(PageZoom.nearest(to: 0.6), 0.5)
        XCTAssertEqual(PageZoom.nearest(to: 1.4), 1.5)
        XCTAssertEqual(PageZoom.nearest(to: 3.7), 2.0)
        // Equidistant between 1.15 and 1.25 resolves to the smaller stop.
        XCTAssertEqual(PageZoom.nearest(to: 1.2), 1.15)
    }

    func testNearestIsIdempotentOnEveryStop() {
        for stop in PageZoom.ladder {
            XCTAssertEqual(PageZoom.nearest(to: stop), stop)
        }
    }
}

/// Covers how a capture hands its result back. The Accessibility reads
/// themselves need a permission the test host does not have.
final class SelectionCaptureDeliveryTests: XCTestCase {
    private static let sample = CapturedSelection(
        text: "quoted",
        appName: "Preview",
        documentLabel: "paper.pdf"
    )

    func testWalkRunsOffTheMainThreadAndDeliveryRunsOnIt() {
        let walkedOffMain = expectation(description: "walked off the main thread")
        let delivered = expectation(description: "delivered")

        let capture = SelectionCapture {
            if !Thread.isMainThread { walkedOffMain.fulfill() }
            return Self.sample
        }
        capture.deliver { selection in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(selection.sourceLabel, "Preview · paper.pdf")
            delivered.fulfill()
        }
        wait(for: [walkedOffMain, delivered], timeout: 2, enforceOrder: true)
    }

    /// The walk often finishes while the panel is still being presented, before
    /// the composer focus is queued. Delivery must still land behind that
    /// focus, or focusing moves the caret back off the top of the quotation.
    func testDeliveryQueuesBehindEarlierMainQueueWorkWhenTheWalkAlreadyFinished() {
        let capture = SelectionCapture { Self.sample }
        let walkFinished = expectation(description: "walk finished")
        capture.deliver { _ in walkFinished.fulfill() }
        wait(for: [walkFinished], timeout: 2)

        let focused = expectation(description: "composer focus")
        let inserted = expectation(description: "selection delivered")
        DispatchQueue.main.async { focused.fulfill() }
        capture.deliver { _ in inserted.fulfill() }
        wait(for: [focused, inserted], timeout: 2, enforceOrder: true)
    }

    func testNothingIsDeliveredWhenNothingWasFound() {
        let capture = SelectionCapture { nil }
        let delivered = expectation(description: "delivered")
        delivered.isInverted = true
        capture.deliver { _ in delivered.fulfill() }
        wait(for: [delivered], timeout: 0.3)
    }
}
