import Foundation
import SwiftUI
import Testing
@testable import VibeWindowManager

@MainActor
struct MalformedUsageDisplayTests {
    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity])
    func invalidPercentNeverCrashesOrLooksLikeAvailableQuota(value: Double) {
        #expect(UsageFormat.percentText(value, showsRemaining: false) == "unavailable")
        #expect(UsageFormat.percentText(value, showsRemaining: true) == "unavailable")
        #expect(UsageFormat.barColor(value) == .gray)
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity, 1e100])
    func invalidOrUnrepresentableResetDateIsOmitted(seconds: Double) {
        #expect(UsageFormat.resetText(Date(timeIntervalSince1970: seconds),
                                     now: Date(timeIntervalSince1970: 0)) == nil)
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity, -1e100])
    func invalidOrUnrepresentableFetchDateIsExplicit(seconds: Double) {
        #expect(UsageFormat.updatedText(Date(timeIntervalSince1970: seconds),
                                       now: Date(timeIntervalSince1970: 0)) == "update time unavailable")
    }

    @Test(arguments: [Double.nan, Double.infinity, -Double.infinity, 1e100, -1e100])
    func durationConversionCannotTrap(seconds: Double) {
        #expect(UsageFormat.compactDuration(seconds) == "unknown")
    }
}
