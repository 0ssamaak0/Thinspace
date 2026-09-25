//
//  ThinspaceApp.swift
//  Thinspace
//
//  Created by alexcding on 2025-12-13.
//

import SwiftUI
import KeyboardShortcuts
import AppKit

// MARK: - Keyboard Shortcut Definition

extension KeyboardShortcuts.Name {
    static let bringToFront = Self(
        "bringToFront",
        initial: .init(.space, modifiers: [.option])
    )
}

// MARK: - Main App

@main
struct ThinspaceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Deliberately not `@State`. The global hotkey handler reads the
    /// coordinator from a Carbon callback, outside any view update, and reading
    /// a `@State` value there re-evaluates its initializer: every keypress
    /// produced a fresh coordinator, a fresh WKWebView, and another Chat Bar
    /// panel left on screen.
    private let coordinator = AppCoordinator.shared

    /// `KeyboardShortcuts.onKeyDown` appends to a shared list rather than
    /// replacing, so a second registration would fire the handler twice.
    @MainActor private static var didRegisterHotKey = false

    @AppStorage(UserDefaultsKeys.showMenuBarIcon.rawValue)
    private var showMenuBarIcon = true

    var body: some Scene {
        Window(AppCoordinator.Constants.mainWindowTitle, id: AppCoordinator.Constants.mainWindowIdentifier) {
            MainWindowView(coordinator: coordinator)
                .frame(
                    minWidth: Constants.mainWindowMinWidth,
                    minHeight: Constants.mainWindowMinHeight
                )
        }
        .defaultSize(
            width: Constants.mainWindowDefaultWidth,
            height: Constants.mainWindowDefaultHeight
        )
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button {
                    coordinator.openNewChat()
                } label: {
                    Label("New Chat", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)

                Button {
                    coordinator.openPrivateChat()
                } label: {
                    Label("Private Chat", systemImage: "eye.slash")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Button {
                    coordinator.toggleSidebar()
                } label: {
                    Label("Toggle Sidebar", systemImage: "sidebar.left")
                }
                .keyboardShortcut(".", modifiers: .command)

                if coordinator.capabilities.contains(.newProject) {
                    Divider()

                    Button {
                        coordinator.openNewProject()
                    } label: {
                        Label("New Project", systemImage: "folder.badge.plus")
                    }
                }

                if coordinator.capabilities.contains(.projects) {
                    Button {
                        coordinator.openProjects()
                    } label: {
                        Label("Projects", systemImage: "folder")
                    }
                }

                if coordinator.capabilities.contains(.claudeCode) {
                    Button {
                        coordinator.openClaudeCode()
                    } label: {
                        Label("Claude Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }

                if coordinator.capabilities.contains(.providerSettings) {
                    Button {
                        coordinator.openProviderSettings()
                    } label: {
                        Label(
                            "\(coordinator.activeProvider.displayName) Settings",
                            systemImage: "gearshape"
                        )
                    }
                }
            }

            CommandGroup(after: .textEditing) {
                Button {
                    coordinator.focusToolbarSearch()
                } label: {
                    Label("Find on Page", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: .command)
            }

            CommandGroup(after: .toolbar) {
                Button {
                    coordinator.goBack()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!coordinator.canGoBack)

                Button {
                    coordinator.goForward()
                } label: {
                    Label("Forward", systemImage: "chevron.right")
                }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!coordinator.canGoForward)

                Button {
                    coordinator.goHome()
                } label: {
                    Label("Go Home", systemImage: "house")
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])

                Divider()

                Button {
                    coordinator.reload()
                } label: {
                    Label("Reload Page", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)

                Divider()

                Button {
                    coordinator.toggleAlwaysOnTop()
                } label: {
                    if coordinator.alwaysOnTop {
                        Label("Always on Top ✓", systemImage: "pin.fill")
                    } else {
                        Label("Always on Top", systemImage: "pin")
                    }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Divider()

                Button {
                    coordinator.zoomIn()
                } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                .keyboardShortcut("+", modifiers: .command)

                Button {
                    coordinator.zoomOut()
                } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                .keyboardShortcut("-", modifiers: .command)

                Button {
                    coordinator.resetZoom()
                } label: {
                    Label("Actual Size", systemImage: "1.magnifyingglass")
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }

        Settings {
            SettingsView(coordinator: coordinator)
        }
        .windowResizability(.contentSize)
        .defaultSize(
            width: SettingsLayout.width,
            height: SettingsLayout.defaultHeight
        )

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarView(coordinator: coordinator)
        } label: {
            Image(Constants.menuBarIcon)
                .renderingMode(.template)
        }
        .menuBarExtraStyle(.menu)
    }

    init() {
        // The theme is applied in `AppDelegate.applicationDidFinishLaunching`,
        // not here: `NSApp` does not exist yet when SwiftUI initializes this
        // value.
        SelectionCaptureService.shared.syncWithPreference()

        if !Self.didRegisterHotKey {
            Self.didRegisterHotKey = true
            KeyboardShortcuts.onKeyDown(for: .bringToFront) {
                AppCoordinator.shared.toggleChatBar()
            }
        }
    }

}

// MARK: - Constants

extension ThinspaceApp {
    struct Constants {
        static let mainWindowMinWidth: CGFloat = 400
        static let mainWindowMinHeight: CGFloat = 300
        static let mainWindowDefaultWidth: CGFloat = 1000
        static let mainWindowDefaultHeight: CGFloat = 700

        /// Template image set in the asset catalog, not an SF Symbol: the mark
        /// is redrawn for menu bar size rather than scaled from the app icon.
        static let menuBarIcon = "MenuBarIcon"
        static let hideWindowDelay: TimeInterval = 0.1
    }
}
