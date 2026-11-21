import Foundation
import SwiftUI
import Testing
@testable import VibeWindowManager

@MainActor
struct UsagePresentationTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func resetWithoutTimestampIsOmitted() {
        #expect(UsageFormat.resetText(nil, now: now) == nil)
    }

    @Test(arguments: [-60.0, 0.0]) func elapsedResetIsReportedAsReset(offset: Double) {
        #expect(UsageFormat.resetText(now.addingTimeInterval(offset), now: now) == "reset")
    }

    @Test(arguments: [
        (0.1, "1m"), (59.0, "1m"), (60.0, "1m"), (60.1, "2m"),
        (3_540.0, "59m"), (3_541.0, "1h"), (3_600.0, "1h"),
        (3_601.0, "1h 1m"), (86_400.0, "1d"), (90_000.0, "1d 1h"),
        (180_000.0, "2d 2h")
    ]) func resetCountdownRoundsUpAtMinuteBoundaries(seconds: Double, expected: String) {
        #expect(UsageFormat.resetText(now.addingTimeInterval(seconds), now: now) == "resets in \(expected)")
    }

    @Test func notUpdatedStateIsExplicit() {
        #expect(UsageFormat.updatedText(nil, now: now) == "not updated yet")
    }

    @Test(arguments: [
        (-60.0, "updated just now"), (0.0, "updated just now"),
        (59.9, "updated just now"), (60.0, "updated 1m ago"),
        (3_599.0, "updated 59m ago"), (3_600.0, "updated 1h ago"),
        (86_399.0, "updated 23h ago"), (86_400.0, "updated 1d ago"),
        (172_800.0, "updated 2d ago")
    ]) func updateAgeUsesCompletedUnits(age: Double, expected: String) {
        #expect(UsageFormat.updatedText(now.addingTimeInterval(-age), now: now) == expected)
    }

    @Test(arguments: [
        (-10.0, "0% used", "100% left"), (0.0, "0% used", "100% left"),
        (21.2, "21% used", "79% left"), (49.5, "50% used", "51% left"),
        (99.6, "100% used", "0% left"), (100.0, "100% used", "0% left"),
        (130.0, "100% used", "0% left")
    ]) func percentagesClampAndRespectProviderDirection(used: Double, usedText: String, remainingText: String) {
        #expect(UsageFormat.percentText(used, showsRemaining: false) == usedText)
        #expect(UsageFormat.percentText(used, showsRemaining: true) == remainingText)
    }

    @Test(arguments: [0.0, 59.99]) func lowUsageIsGreen(used: Double) {
        #expect(UsageFormat.barColor(used) == Color.green)
    }

    @Test(arguments: [60.0, 84.99]) func approachingLimitIsOrange(used: Double) {
        #expect(UsageFormat.barColor(used) == Color.orange)
    }

    @Test(arguments: [85.0, 100.0]) func nearLimitIsRed(used: Double) {
        #expect(UsageFormat.barColor(used) == Color.red)
    }

    @Test func cursorDisplaysUsedShareAndCodexDisplaysRemainingShare() {
        #expect(UsageProvider.cursor.displayName == "Cursor")
        #expect(UsageProvider.cursor.symbolName == "cursorarrow")
        #expect(!UsageProvider.cursor.showsRemaining)
        #expect(!UsageProvider.claude.showsRemaining)
        #expect(UsageProvider.codex.showsRemaining)
        #expect(UsageFormat.percentText(21.2, showsRemaining: UsageProvider.cursor.showsRemaining) == "21% used")
    }

    @Test func errorMessagePreservesWhitespaceAndClickableSignInLink() {
        let formatted = UsageFormat.errorText("Sign in at [Cursor](https://cursor.com/settings).\nTry again.")
        #expect(String(formatted.characters) == "Sign in at Cursor.\nTry again.")
        #expect(formatted.runs.contains { $0.link == URL(string: "https://cursor.com/settings") })
    }

    @Test func plainErrorMessageRemainsReadable() {
        let formatted = UsageFormat.errorText("Cursor is offline (HTTP 503).")
        #expect(String(formatted.characters) == "Cursor is offline (HTTP 503).")
    }
    @Test func menuOnlyIncludesProvidersWithUsableMeters() async {
        struct Fetcher: UsageFetching {
            let result: ProviderUsage
            func fetch() async -> ProviderUsage { result }
        }
        let service = UsageLimitsService(fetchers: [
            .claude: Fetcher(result: ProviderUsage(provider: .claude, planName: nil, windows: [],
                fetchedAt: now, errorMessage: "No credentials found")),
            .codex: Fetcher(result: ProviderUsage(provider: .codex, planName: "Pro",
                windows: [UsageWindow(label: "Weekly", usedPercent: 0, resetsAt: nil)],
                fetchedAt: now, errorMessage: nil)),
            .cursor: Fetcher(result: ProviderUsage(provider: .cursor, planName: nil,
                windows: [UsageWindow(label: "API", usedPercent: 12, resetsAt: nil)],
                fetchedAt: now, errorMessage: "Plan info unavailable")),
            .grokBot: Fetcher(result: ProviderUsage(provider: .grokBot, planName: nil, windows: [],
                fetchedAt: now, errorMessage: "Connect usage")),
        ])
        #expect(service.menuProviders.isEmpty)
        service.refresh()
        for _ in 0..<200 where service.isRefreshing { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(!service.isRefreshing)
        #expect(service.menuProviders == [.codex, .cursor])
        // The main window can still show setup failures and partial-result diagnostics.
        #expect(service.usage(for: .claude)?.errorMessage == "No credentials found")
        #expect(service.usage(for: .grokBot)?.errorMessage == "Connect usage")
        #expect(service.usage(for: .cursor)?.errorMessage == "Plan info unavailable")
    }

    @Test func malformedMeterDoesNotMakeAProviderVisible() {
        let usage = ProviderUsage(provider: .cursor, planName: nil,
            windows: [UsageWindow(label: "API", usedPercent: .nan, resetsAt: nil)],
            fetchedAt: now, errorMessage: nil)
        #expect(!usage.hasUsableMeter)
    }

}
