import Foundation
import SwiftUI
import Testing
@testable import VibeWindowManager

@MainActor
struct ReduceMotionTests {
    private func finish(_ service: ReduceMotionService) async {
        for _ in 0..<200 where service.isUpdating {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(!service.isUpdating)
    }

    @Test func initialAndExternalValuesFollowSystem() {
        var system = true
        let service = ReduceMotionService(read: { system }, write: nil, observeSystem: false)
        #expect(service.isEnabled)
        system = false
        service.refresh()
        #expect(!service.isEnabled)
    }

    @Test func changesAreVerifiedAndSharedByBindings() async {
        var system = false
        var writes: [Bool] = []
        let service = ReduceMotionService(read: { system }, write: { system = $0; writes.append($0); return .completed }, observeSystem: false)
        let panel = service.binding, menu = service.binding
        panel.wrappedValue = true
        await finish(service)
        #expect(menu.wrappedValue)
        #expect(system)
        menu.wrappedValue = false
        await finish(service)
        #expect(!panel.wrappedValue)
        #expect(!system)
        #expect(writes == [true, false])
        #expect(service.errorMessage == nil)
    }

    @Test func rejectedChangeDoesNotInventSystemState() async {
        var system = false
        let service = ReduceMotionService(read: { system }, write: { _ in .completed }, observeSystem: false,
            verificationAttempts: 1, verificationDelay: .zero)
        service.setEnabled(true)
        await finish(service)
        #expect(!service.isEnabled)
        #expect(service.errorMessage != nil)
        system = true
        service.refresh()
        #expect(service.isEnabled)
        #expect(service.errorMessage == nil)
    }

    @Test func unavailableSetterOffersSettingsWithoutChangingValue() {
        let service = ReduceMotionService(read: { true }, write: nil, observeSystem: false)
        service.setEnabled(false)
        #expect(service.isEnabled)
        #expect(!service.isUpdating)
        #expect(service.errorMessage != nil)
    }

    @Test func unchangedOrPendingRequestsDoNotDuplicateWrites() async {
        var system = false
        var writes = 0
        let service = ReduceMotionService(read: { system }, write: { _ in writes += 1; return .completed }, observeSystem: false,
            verificationAttempts: 2, verificationDelay: .milliseconds(10))
        service.setEnabled(false)
        #expect(writes == 0)
        service.setEnabled(true)
        service.setEnabled(true)
        service.setEnabled(false)
        system = true
        await finish(service)
        #expect(writes == 1)
        #expect(service.isEnabled)
        #expect(service.errorMessage == nil)
    }
    @Test func missingHelperOffersSetupWithoutInventingAChange() async {
        let service = ReduceMotionService(read: { false }, write: { _ in .needsSetup }, observeSystem: false)
        service.setEnabled(true)
        await finish(service)
        #expect(!service.isEnabled)
        #expect(service.needsSetup)
        #expect(service.errorMessage != nil)
    }

}
