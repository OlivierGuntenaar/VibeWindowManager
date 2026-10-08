//
//  VibeWindowManagerApp.swift
//  VibeWindowManager
//
//  Created by Thomas Guntenaar on 23/04/2026.
//

import AppKit
import Darwin
import SwiftUI

private enum MainWindowID: String {
    case main = "vibe-main-window"
}

@main
struct VibeWindowManagerApp: App {
    @StateObject private var bridge = VibeBridgeServer()
    init() {
        if Self.isTestHostProcess { return }
        if WindowCLI.shouldRun(arguments: CommandLine.arguments) {
            let exitCode = WindowCLI.run(arguments: CommandLine.arguments)
            Darwin.exit(exitCode)
        }
        // `UserDefaults.bool(forKey:)` is false when the key is **missing**; SwiftUI @AppStorage default
        // true does not write the key, so STT would read OpenAI-pip as off. Register defaults for reads
        // that match the UI (see debug session e5d455, H5).
        UserDefaults.standard.register(defaults: [
            "vibeWhisperOpenAIPip": true,
            VibeAppPersistence.bridgeServerEnabledKey: true,
        ])
        // The menu bar extra lists live localhost servers even when the main window was never
        // opened, so the scanner is owned by the app rather than started from a view's lifecycle.
        LocalServerScanService.shared.startAutoRefresh()
        // Claude / Codex usage limits for the top of the menu bar panel: every ~5 min, plus on open
        // when older than ~60 s (see MenuBarPanelView).
        UsageLimitsService.shared.startAutoRefresh()
    }

    /// True when the app is a unit test host (Swift Testing / XCTest) — not a terminal `windows` invocation.
    private static var isTestHostProcess: Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return true }
        return CommandLine.arguments.contains { $0.caseInsensitiveCompare("-XCTest") == .orderedSame }
    }

    var body: some Scene {
        WindowGroup(id: MainWindowID.main.rawValue) {
            ContentView()
                .environmentObject(bridge)
        }
        .commands {
            CommandMenu("Quick layout") {
                Button("Cascade Cursor (extra display…)") {
                    VibeMenuBarActions.cascadeCursorOnExtraOrMainDisplay()
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra("Vibe", image: "MenuBarExtraIcon") {
            MenuBarPanelView(mainWindowID: MainWindowID.main.rawValue)
                .environmentObject(bridge)
        }
        .menuBarExtraStyle(.window)
    }
}

// `VibeMenuBarActions`, `VibeServerMenuFormat` and the menu bar panel live in MenuBarPanelView.swift.
