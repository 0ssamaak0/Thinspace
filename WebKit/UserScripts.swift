//
//  UserScripts.swift
//  Thinspace
//

import WebKit

/// Composes scripts shared by every provider with the active provider's
/// conversation detector. Configurations are rebuilt when providers switch.
enum UserScripts {
    static let consoleLogHandler = "consoleLog"
    static let conversationStateHandler = "conversationState"
    static let privateChatStateHandler = "privateChatState"

    static func createAllScripts(for adapter: any ProviderAdapter) -> [WKUserScript] {
        var scripts = [
            WKUserScript(
                source: imeFixSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ),
            WKUserScript(
                source: selectionInsertSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ),
            WKUserScript(
                source: conversationObserverSource(
                    providerSource: adapter.conversationObserverSource
                ),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ),
            WKUserScript(
                source: privateChatObserverSource(
                    providerSource: adapter.privateChatObserverSource
                ),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        ]

        #if DEBUG
        scripts.insert(
            WKUserScript(
                source: consoleLogBridgeSource,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            ),
            at: 0
        )
        #endif

        return scripts
    }

    private static let consoleLogBridgeSource = """
    (function() {
        if (window.__thinspaceConsoleBridgeInstalled) return;
        window.__thinspaceConsoleBridgeInstalled = true;
        const originalLog = console.log.bind(console);
        console.log = function(...args) {
            originalLog(...args);
            try {
                const message = args.map(function(arg) {
                    if (typeof arg === 'object') return JSON.stringify(arg);
                    return String(arg);
                }).join(' ');
                window.webkit.messageHandlers.\(consoleLogHandler).postMessage(message);
            } catch (_) {}
        };
    })();
    """

    /// Prevents the Enter used to commit an IME composition from also sending.
    private static let imeFixSource = """
    (function() {
        'use strict';
        if (window.__thinspaceIMEFixInstalled) return;
        window.__thinspaceIMEFixInstalled = true;

        let imeActive = false;
        let imeEverUsed = false;
        let compositionEndTime = 0;
        const BUFFER_TIME = 300;

        function isInIMEWindow() {
            return imeActive || Date.now() - compositionEndTime < BUFFER_TIME;
        }

        document.addEventListener('compositionstart', function() {
            imeActive = true;
            imeEverUsed = true;
        }, true);
        document.addEventListener('compositionend', function() {
            imeActive = false;
            compositionEndTime = Date.now();
        }, true);
        document.addEventListener('keydown', function(event) {
            if (!imeEverUsed || event.key !== 'Enter' || event.shiftKey ||
                event.ctrlKey || event.altKey) return;
            if (isInIMEWindow() || event.isComposing || event.keyCode === 229) {
                event.stopImmediatePropagation();
                event.preventDefault();
            }
        }, true);
        document.addEventListener('beforeinput', function(event) {
            if (!imeEverUsed) return;
            if (event.inputType !== 'insertParagraph' &&
                event.inputType !== 'insertLineBreak') return;
            if (isInIMEWindow()) {
                event.stopImmediatePropagation();
                event.preventDefault();
            }
        }, true);
    })();
    """

    /// Adds the text the user had selected in another app to the composer when
    /// the Chat Bar opens, with the caret left above it.
    ///
    /// Nothing here touches the send path. Intercepting Enter or the send
    /// button means racing each provider's own state commit and reflow, which
    /// differs per provider and breaks whenever their UI changes; placing the
    /// text in the composer up front works identically for Enter, Command-Enter
    /// and the mouse, and lets the user see and edit what will be sent.
    static let selectionInsertSource = """
    (function() {
        'use strict';
        if (window.__thinspaceSelectionBridgeInstalled) return;
        window.__thinspaceSelectionBridgeInstalled = true;

        const COMPOSER_SELECTORS = [
            '#prompt-textarea',
            '[data-testid="composer-text-input"]',
            'rich-textarea [contenteditable="true"]',
            'div.ql-editor[contenteditable="true"]',
            'div.ProseMirror[contenteditable="true"]',
            'div[contenteditable="true"][data-placeholder]',
            'textarea[placeholder*="Message" i]',
            '[contenteditable="true"]',
            'textarea'
        ];

        function findComposer() {
            for (const selector of COMPOSER_SELECTORS) {
                const element = document.querySelector(selector);
                if (element) return element;
            }
            return null;
        }

        function isPlainTextField(element) {
            return element.tagName === 'TEXTAREA' || element.tagName === 'INPUT';
        }

        function contentOf(element) {
            return isPlainTextField(element) ? element.value : element.innerText;
        }

        function quotedBlock(value) {
            // Three leading newlines put the caret on its own line with two
            // blank lines under it, identically on every provider.
            return '\\n\\n\\n--- ' + value.source + ' ---\\n' + value.text;
        }

        function scrollToTop(element) {
            element.scrollTop = 0;
            let node = element.parentElement;
            for (let i = 0; i < 5 && node; i++) {
                if (node.scrollHeight > node.clientHeight) node.scrollTop = 0;
                node = node.parentElement;
            }
        }

        function collapseSelection(element, toStart) {
            const selection = window.getSelection();
            const range = document.createRange();
            range.selectNodeContents(element);
            range.collapse(toStart);
            selection.removeAllRanges();
            selection.addRange(range);
        }

        function paste(element, text) {
            try {
                const transfer = new DataTransfer();
                transfer.setData('text/plain', text);
                element.dispatchEvent(new ClipboardEvent('paste', {
                    clipboardData: transfer,
                    bubbles: true,
                    cancelable: true
                }));
            } catch (_) {}
        }

        function waitForChange(element, before, attempts, done) {
            if (contentOf(element) !== before) { done(true); return; }
            if (attempts <= 0) { done(false); return; }
            setTimeout(function() {
                waitForChange(element, before, attempts - 1, done);
            }, 25);
        }

        // Each strategy is verified against the composer's own content, because
        // a rich editor can accept and silently discard an event it does not
        // understand, and WebKit may drop the clipboardData carried by a
        // constructed ClipboardEvent.
        //
        // The check has to be asynchronous: ProseMirror and Quill commit a
        // paste through their own transaction, which lands a tick or more after
        // the event is dispatched. Reading the content synchronously reports
        // failure for a paste that did work, runs the fallback as well, and
        // inserts the quotation twice.
        function insert(element, text, done) {
            element.focus();

            if (isPlainTextField(element)) {
                // React tracks the previous value on the node, so the native
                // setter is needed for it to observe the change at all.
                const prototype = element.tagName === 'TEXTAREA'
                    ? window.HTMLTextAreaElement.prototype
                    : window.HTMLInputElement.prototype;
                const setter = Object.getOwnPropertyDescriptor(prototype, 'value').set;
                setter.call(element, element.value + text);
                element.dispatchEvent(new Event('input', { bubbles: true }));
                done(true);
                return;
            }

            if (!element.isContentEditable) { done(false); return; }

            const before = contentOf(element);
            collapseSelection(element, false);

            // Paste is tried first: it is the only route that survives as
            // separate paragraphs in both ProseMirror and Quill.
            paste(element, text);
            waitForChange(element, before, 6, function(pasted) {
                if (pasted) { done(true); return; }
                try {
                    document.execCommand('insertText', false, text);
                } catch (_) {}
                waitForChange(element, before, 4, done);
            });
        }

        // A single placement is not enough: ProseMirror restores its own
        // selection when the paste transaction commits, which can land after
        // the caret has been moved and drops it back below the quotation.
        // Reapplying briefly wins that race, and the content guard stops the
        // moment the user types so their caret is never yanked backwards.
        function settleCaretAtTop(composer, guard, attempts) {
            if (contentOf(composer) !== guard) return;

            if (isPlainTextField(composer)) {
                composer.setSelectionRange(0, 0);
            } else {
                collapseSelection(composer, true);
            }
            scrollToTop(composer);

            if (attempts <= 0) return;
            setTimeout(function() {
                settleCaretAtTop(composer, guard, attempts - 1);
            }, 60);
        }

        window.__thinspaceInsertSelection = function(value) {
            if (!value || !value.text) return false;
            const text = quotedBlock(value);
            let tries = 0;

            function attempt() {
                const composer = findComposer();
                if (!composer) {
                    // The provider page may still be building its composer.
                    if (++tries < 40) setTimeout(attempt, 75);
                    return;
                }
                // Reopening the Chat Bar over an unsent draft must not stack a
                // second copy of the same quotation.
                if (contentOf(composer).indexOf(value.text) !== -1) return;

                insert(composer, text, function(inserted) {
                    if (!inserted) return;
                    settleCaretAtTop(composer, contentOf(composer), 4);
                });
            }

            attempt();
            return true;
        };
    })();
    """

    private static func conversationObserverSource(providerSource: String) -> String {
        """
        (function() {
            'use strict';
            if (window.__thinspaceConversationObserverInstalled) return;
            window.__thinspaceConversationObserverInstalled = true;

            \(providerSource)

            let lastState = null;
            let scheduled = false;
            let observer = null;
            let observing = false;

            // Every isInProviderConversation() becomes true only via an added
            // element, a data-is-streaming flip, or a pathname change. A future
            // detector that keys off text content or an attribute outside
            // attributeFilter must add that attribute to the filter, or this
            // fast path will miss its transition. `schedule` keeps its zero-arg
            // signature because it is also the popstate listener and is called
            // bare from the history hooks.
            function relevantMutation(records) {
                for (let i = 0; i < records.length; i++) {
                    const record = records[i];
                    if (record.type === 'attributes') return true;
                    const added = record.addedNodes;
                    for (let j = 0; j < added.length; j++) {
                        if (added[j].nodeType === 1) return true;
                    }
                }
                return false;
            }

            function onMutations(records) {
                if (relevantMutation(records)) schedule();
            }

            // Subtree childList observation makes WebKit build a MutationRecord
            // for every node the page inserts, which is heaviest while a
            // response streams. It is only needed to catch the transition into
            // a conversation, so it is dropped once that has been detected and
            // restored if a route change puts the page back outside one.
            function connect() {
                if (observing || !document.body) return;
                if (!observer) observer = new MutationObserver(onMutations);
                observer.observe(document.body, {
                    childList: true,
                    subtree: true,
                    attributes: true,
                    attributeFilter: ['data-is-streaming']
                });
                observing = true;
            }

            function disconnect() {
                if (!observing) return;
                observer.disconnect();
                observing = false;
            }

            function publish() {
                const state = !!isInProviderConversation();
                if (state === lastState) return;
                lastState = state;
                if (state) {
                    disconnect();
                } else {
                    connect();
                }
                try {
                    window.webkit.messageHandlers.\(conversationStateHandler).postMessage({
                        inConversation: state
                    });
                } catch (_) {}
            }

            function schedule() {
                if (scheduled) return;
                scheduled = true;
                setTimeout(function() {
                    scheduled = false;
                    publish();
                }, 100);
            }

            function start() {
                if (!document.body) {
                    setTimeout(start, 25);
                    return;
                }
                connect();
                publish();
            }

            const originalPushState = history.pushState;
            const originalReplaceState = history.replaceState;
            history.pushState = function() {
                const result = originalPushState.apply(this, arguments);
                schedule();
                return result;
            };
            history.replaceState = function() {
                const result = originalReplaceState.apply(this, arguments);
                schedule();
                return result;
            };
            window.addEventListener('popstate', schedule);
            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', start, { once: true });
            } else {
                start();
            }
        })();
        """
    }

    /// Private mode belongs to the embedded provider, so the native app cannot
    /// infer it from navigation alone. Each adapter supplies its DOM detector;
    /// this shared observer publishes state and also catches provider-owned
    /// controls clicked directly by the user.
    private static func privateChatObserverSource(providerSource: String) -> String {
        """
        (function() {
            'use strict';
            if (window.__thinspacePrivateChatObserverInstalled) return;
            window.__thinspacePrivateChatObserverInstalled = true;

            \(ProviderJS.visible)

            \(ProviderJS.normalize)

            // childNodes textContent joined with spaces approximates
            // innerText's separator-at-box-boundary behavior without forcing a
            // synchronous style+layout flush — this runs in a capture-phase
            // click listener ahead of the page's own handlers. Relative to
            // innerText the join can only add separators, never lose one the
            // word-boundary regexes below depend on.
            function elementName(element) {
                const joinedText = Array.prototype.map.call(
                    element.childNodes,
                    function(node) { return node.textContent; }
                ).join(' ');
                return [
                    element.getAttribute('aria-label'),
                    element.getAttribute('title'),
                    joinedText,
                    element.textContent
                ].map(normalize).filter(Boolean).join(' ');
            }

            function privateChatStateFromURL() {
                let url;
                try {
                    url = new URL(window.location.href);
                } catch (_) {
                    return null;
                }

                for (const entry of url.searchParams.entries()) {
                    const key = normalize(entry[0]).toLowerCase();
                    const value = normalize(entry[1]).toLowerCase();
                    if (/temporary|incognito|private/.test(key)) {
                        if (/^(1|true|on|active|enabled)$/.test(value)) return true;
                        if (/^(0|false|off|inactive|disabled)$/.test(value)) return false;
                    }
                    if (/^(mode|chat|conversation|type)$/.test(key) &&
                        /^(temporary|incognito|private)$/.test(value)) {
                        return true;
                    }
                }
                return null;
            }

            function explicitElementState(element) {
                const values = [
                    element.getAttribute('aria-pressed'),
                    element.getAttribute('aria-checked'),
                    element.getAttribute('data-state')
                ].map(function(value) { return normalize(value).toLowerCase(); });

                if (values.some(function(value) {
                    return ['true', 'on', 'checked', 'active', 'enabled'].includes(value);
                })) return true;
                if (values.some(function(value) {
                    return ['false', 'off', 'unchecked', 'inactive', 'disabled'].includes(value);
                })) return false;

                const name = elementName(element);
                if (/(turn off|disable|exit|leave|end).*?(temporary|private|incognito)|(?:temporary|private|incognito).*?(is on|active|enabled)/i.test(name)) {
                    return true;
                }
                if (/(turn on|enable|start).*?(temporary|private|incognito)|(?:temporary|private|incognito).*?(is off|inactive|disabled)/i.test(name)) {
                    return false;
                }
                return null;
            }

            function privateChatStateFromElements(selectors) {
                let sawInactive = false;
                for (const selector of selectors) {
                    let elements = [];
                    try {
                        elements = document.querySelectorAll(selector);
                    } catch (_) {}
                    for (const element of elements) {
                        if (!visible(element)) continue;
                        const state = explicitElementState(element);
                        if (state === true) return true;
                        if (state === false) sawInactive = true;
                    }
                }
                return sawInactive ? false : null;
            }

            function hasPrivateChatIndicator(selectors, namePattern) {
                for (const selector of selectors) {
                    let elements = [];
                    try {
                        elements = document.querySelectorAll(selector);
                    } catch (_) {}
                    for (const element of elements) {
                        if (!visible(element)) continue;
                        if (element.closest('button, [role="button"], a[href]')) continue;
                        if (namePattern.test(elementName(element))) return true;
                    }
                }
                return false;
            }

            \(providerSource)

            let lastState = null;
            let scheduled = false;
            let forcedState = null;
            let forcedStateUntil = 0;
            let toggleGeneration = 0;

            function publishState(state, force) {
                state = !!state;
                if (!force && state === lastState) return;
                lastState = state;
                try {
                    window.webkit.messageHandlers.\(privateChatStateHandler).postMessage({
                        inPrivateChat: state
                    });
                } catch (_) {}
            }

            function detectAndPublish() {
                let state = null;
                try {
                    state = detectProviderPrivateChatState();
                } catch (_) {}
                if (typeof state !== 'boolean') return false;
                if (forcedState !== null && state !== forcedState &&
                    lastState === forcedState && Date.now() < forcedStateUntil) {
                    return true;
                }
                publishState(state);
                return true;
            }

            function schedule(delay) {
                setTimeout(detectAndPublish, delay);
            }

            function scheduleBurst() {
                if (scheduled) return;
                scheduled = true;
                schedule(80);
                schedule(300);
                setTimeout(function() {
                    scheduled = false;
                    detectAndPublish();
                }, 900);
            }

            window.__thinspaceSetPrivateChatState = function(state) {
                forcedState = !!state;
                forcedStateUntil = Date.now() + 1500;
                publishState(state, true);
                scheduleBurst();
                // The burst above runs entirely inside the forced window, where
                // a contradicting result is ignored, so it can only confirm the
                // intended state. These two passes run after the window closes
                // and are what correct the colour when the provider did not
                // actually act on the shortcut.
                schedule(1600);
                schedule(2600);
            };

            // Icon-only controls carry no name, so their test id is checked too.
            // Attribute reads only: this runs ahead of the page's own handlers.
            function isPrivateControl(control, name) {
                if (/temporary( chat)?|incognito|private chat/i.test(name)) return true;
                const testID = control.getAttribute('data-testid') ||
                    control.getAttribute('data-test-id') || '';
                return /temp(orary)?[-_ ]?chat|incognito|private[-_ ]?chat/i.test(testID);
            }

            // Only a click that can change private mode schedules detection.
            // Every burst pass runs the detector's whole-page queries and
            // visible() style reads, so bursting on every click was costly in a
            // long, streaming conversation. Links and new chats that navigate
            // are still caught by the history hooks below.
            document.addEventListener('click', function(event) {
                const control = event.target instanceof Element
                    ? event.target.closest('button, [role="button"], a[href]')
                    : null;
                if (!control) return;

                const name = elementName(control);
                const clickedPrivateControl = isPrivateControl(control, name);
                const wasActive = lastState === true;
                const clickedExitSurface = wasActive &&
                    /\\bnew chat\\b|\\bstart (a )?new chat\\b/i.test(name);
                if (!clickedPrivateControl && !clickedExitSurface) return;
                scheduleBurst();

                if (clickedExitSurface) {
                    setTimeout(function() { publishState(false); }, 120);
                    return;
                }
                if (!clickedPrivateControl) return;

                const generation = ++toggleGeneration;
                setTimeout(function() {
                    if (generation !== toggleGeneration) return;
                    const detected = detectAndPublish();
                    if (!detected) publishState(!wasActive);
                }, 450);
            }, true);

            const originalPushState = history.pushState;
            const originalReplaceState = history.replaceState;
            history.pushState = function() {
                const result = originalPushState.apply(this, arguments);
                scheduleBurst();
                return result;
            };
            history.replaceState = function() {
                const result = originalReplaceState.apply(this, arguments);
                scheduleBurst();
                return result;
            };
            window.addEventListener('popstate', scheduleBurst);
            window.addEventListener('pageshow', scheduleBurst);

            function start() {
                if (!document.body) {
                    setTimeout(start, 25);
                    return;
                }
                // Detected once for the state the page loads in. Every later
                // change is driven by the event that caused it: the shortcut
                // hooks above, a click on a provider control, or a navigation.
                // Nothing polls.
                detectAndPublish();
            }

            if (document.readyState === 'loading') {
                document.addEventListener('DOMContentLoaded', start, { once: true });
            } else {
                start();
            }
        })();
        """
    }
}
