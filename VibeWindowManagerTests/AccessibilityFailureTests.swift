import AppKit
import ApplicationServices
import Testing
@testable import VibeWindowManager

@MainActor
struct AccessibilityFailureTests {
    private let frame = CGRect(x: 0, y: 0, width: 1200, height: 800)

    private func expectNotTrusted(_ action: () throws -> Void) {
        do {
            try action()
            Issue.record("Expected permission denial")
        } catch LayoutError.notTrusted {
            // The permission guard must run before attempting any AX operation.
        } catch {
            Issue.record("Expected notTrusted, received \(error)")
        }
    }

    @Test func deniedPermissionBlocksWindowEnumeration() {
        let service = AXWindowLayoutService(trustedCheck: { false })
        expectNotTrusted { _ = try service.windows(for: .current) }
        expectNotTrusted { _ = try service.windowElements(for: .current) }
    }

    @Test func deniedPermissionBlocksDirectWindowMovement() {
        let service = AXWindowLayoutService(trustedCheck: { false })
        let dummy = AXUIElementCreateApplication(0)
        expectNotTrusted { try service.setFrame(dummy, frame, allScreens: []) }
    }

    @Test func deniedPermissionBlocksTileAndCascade() {
        let service = AXWindowLayoutService(trustedCheck: { false })
        let dummy = AXUIElementCreateApplication(0)
        expectNotTrusted { try service.applyTile(visibleFrame: frame, mode: .grid(1), to: [dummy], allScreens: []) }
        expectNotTrusted { try service.applyCascade(visibleFrame: frame, to: [dummy], allScreens: [], insetStep: 20) }
    }

    @Test func deniedPermissionIsReportedEvenForEmptySelection() {
        let service = AXWindowLayoutService(trustedCheck: { false })
        expectNotTrusted { try service.applyTile(visibleFrame: frame, mode: .grid(1), to: [], allScreens: []) }
        expectNotTrusted { try service.applyCascade(visibleFrame: frame, to: [], allScreens: [], insetStep: 20) }
    }

    @Test func permissionStatusIsLiveRatherThanCached() {
        var trusted = true
        let service = AXWindowLayoutService(trustedCheck: { trusted })
        #expect(service.isProcessTrusted)
        trusted = false
        #expect(!service.isProcessTrusted)
        expectNotTrusted { _ = try service.windows(for: .current) }
        trusted = true
        #expect(service.isProcessTrusted)
    }

    @Test func revokedPermissionBlocksDirectMovement() {
        var trusted = true
        let service = AXWindowLayoutService(trustedCheck: { trusted })
        #expect(service.isProcessTrusted)
        trusted = false
        let dummy = AXUIElementCreateApplication(0)
        expectNotTrusted { try service.setFrame(dummy, frame, allScreens: []) }
    }

    @Test func permissionRevokedBetweenTilePlanningAndMovementIsRechecked() {
        var checks = 0
        let service = AXWindowLayoutService(trustedCheck: {
            checks += 1
            return checks == 1
        })
        let dummy = AXUIElementCreateApplication(0)
        expectNotTrusted { try service.applyTile(visibleFrame: frame, mode: .grid(1), to: [dummy], allScreens: []) }
        #expect(checks == 2)
    }

    @Test func permissionRevokedBetweenCascadePlanningAndMovementIsRechecked() {
        var checks = 0
        let service = AXWindowLayoutService(trustedCheck: {
            checks += 1
            return checks == 1
        })
        let dummy = AXUIElementCreateApplication(0)
        expectNotTrusted { try service.applyCascade(visibleFrame: frame, to: [dummy], allScreens: [], insetStep: 20) }
        #expect(checks == 2)
    }

    @Test func trustedEmptySelectionIsHarmless() throws {
        let service = AXWindowLayoutService(trustedCheck: { true })
        try service.applyTile(visibleFrame: frame, mode: .grid(1), to: [], allScreens: [])
        try service.applyCascade(visibleFrame: frame, to: [], allScreens: [], insetStep: 20)
    }
}
