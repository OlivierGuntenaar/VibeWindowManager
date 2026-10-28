//
//  ShowMainWindowTests.swift
//  VibeWindowManagerTests
//

import AppKit
import Testing
@testable import VibeWindowManager

@MainActor
struct ShowMainWindowTests {
    @Test func noWindowMeansOpenOne() {
        #expect(ShowMainWindow.decision(for: []) == .openWindow)

        let closed = mainWindow(windowNumber: 8, isVisible: false, isMiniaturized: false)
        #expect(ShowMainWindow.decision(for: [closed]) == .openWindow)
    }

    @Test func visibleWindowIsReused() {
        let closed = mainWindow(windowNumber: 9, isVisible: false, isMiniaturized: false)
        let visible = mainWindow(windowNumber: 2)
        #expect(ShowMainWindow.decision(for: [closed, visible]) == .reuse(index: 1))
    }

    @Test func keyWindowWinsOverANewerOne() {
        let newer = mainWindow(windowNumber: 20)
        let key = mainWindow(windowNumber: 3, isKeyWindow: true)
        let older = mainWindow(windowNumber: 1)
        #expect(ShowMainWindow.decision(for: [newer, key, older]) == .reuse(index: 1))
    }

    @Test func minimizedWindowIsReused() {
        let minimized = mainWindow(windowNumber: 4, isVisible: false, isMiniaturized: true)
        #expect(ShowMainWindow.decision(for: [minimized]) == .reuse(index: 0))
    }

    @Test func overlaysAndSheetsAreSkipped() {
        // Each decoy would beat the real window if its one disqualifier were ignored:
        // the sheet is key, and the others have newer window numbers.
        let floating = mainWindow(windowNumber: 94, level: .floating)
        let ripple = candidate(windowNumber: 93, canBecomeKey: true, level: .floating, styleMask: [.borderless])
        let titledNotClosable = candidate(windowNumber: 96, styleMask: [.titled])
        let closableNotTitled = candidate(windowNumber: 92, styleMask: [.closable])
        let cannotBecomeKey = mainWindow(windowNumber: 95, canBecomeKey: false)
        let calibration = candidate(windowNumber: 50, canBecomeKey: false, level: .floating, styleMask: [.borderless])
        let menuBarPanel = candidate(
            windowNumber: 70,
            canBecomeKey: false,
            level: .statusBar,
            styleMask: [.borderless, .nonactivatingPanel]
        )
        let sheet = mainWindow(windowNumber: 100, isKeyWindow: true, isSheet: true)
        let decoys = [
            floating, ripple, titledNotClosable, closableNotTitled,
            cannotBecomeKey, calibration, menuBarPanel, sheet,
        ]

        #expect(ShowMainWindow.decision(for: decoys) == .openWindow)
        #expect(ShowMainWindow.decision(for: decoys + [mainWindow(windowNumber: 5)]) == .reuse(index: 8))
    }

    private func mainWindow(
        windowNumber: Int,
        canBecomeKey: Bool = true,
        level: NSWindow.Level = .normal,
        isKeyWindow: Bool = false,
        isVisible: Bool = true,
        isMiniaturized: Bool = false,
        isSheet: Bool = false
    ) -> ShowMainWindow.Candidate {
        candidate(
            windowNumber: windowNumber,
            canBecomeKey: canBecomeKey,
            level: level,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            isKeyWindow: isKeyWindow,
            isVisible: isVisible,
            isMiniaturized: isMiniaturized,
            isSheet: isSheet
        )
    }

    private func candidate(
        windowNumber: Int,
        canBecomeKey: Bool = true,
        level: NSWindow.Level = .normal,
        styleMask: NSWindow.StyleMask,
        isKeyWindow: Bool = false,
        isVisible: Bool = true,
        isMiniaturized: Bool = false,
        isSheet: Bool = false
    ) -> ShowMainWindow.Candidate {
        ShowMainWindow.Candidate(
            canBecomeKey: canBecomeKey,
            level: level,
            styleMask: styleMask,
            isSheet: isSheet,
            isVisible: isVisible,
            isMiniaturized: isMiniaturized,
            isKeyWindow: isKeyWindow,
            windowNumber: windowNumber
        )
    }
}
