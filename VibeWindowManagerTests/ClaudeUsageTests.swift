import Foundation
import Testing
@testable import VibeWindowManager

struct ClaudeUsageTests {
    @Test func namedWindowsHaveStableOrder() {
        let windows = ClaudeUsageFetcher.parseWindows([
            "seven_day_sonnet": ["utilization": 40], "seven_day_opus": ["utilization": 30],
            "seven_day": ["utilization": 20], "five_hour": ["utilization": 10]
        ])
        #expect(windows.map(\.label) == ["Session (5h)", "Weekly", "Weekly · Opus", "Weekly · Sonnet"])
        #expect(windows.map(\.usedPercent) == [10, 20, 30, 40])
    }

    @Test func malformedWindowsDoNotInventUsage() {
        #expect(ClaudeUsageFetcher.parseWindows([:]).isEmpty)
        for value in [NSNull(), true, [], "bad", Double.nan, Double.infinity] as [Any] {
            #expect(ClaudeUsageFetcher.parseWindows(["five_hour": ["utilization": value]]).isEmpty)
        }
        #expect(ClaudeUsageFetcher.parseWindows(["five_hour": "bad", "seven_day": [:]]).isEmpty)
    }

    @Test(arguments: [-10.0, 0, 42.5, 100, 120])
    func usageClampsToDisplayRange(value: Double) {
        #expect(ClaudeUsageFetcher.parseWindows(["five_hour": ["utilization": value]]).first?.usedPercent == min(100, max(0, value)))
    }

    @Test func validNumericStringsRemainSupported() {
        #expect(ClaudeUsageFetcher.parseWindows(["seven_day": ["utilization": "12.5"]]).first?.usedPercent == 12.5)
    }

    @Test(arguments: ["weekly", "seven_day", "7d", "WEEKLY"])
    func modelWeeklyKinds(kind: String) {
        let windows = ClaudeUsageFetcher.parseWindows(["limits": [["kind": kind, "percent": 12, "scope": ["model": ["display_name": "Fable"]]]]])
        #expect(windows.first?.label == "Weekly · Fable")
    }

    @Test(arguments: ["session", "five_hour", "5h"])
    func modelSessionKinds(kind: String) {
        let windows = ClaudeUsageFetcher.parseWindows(["limits": [["group": kind, "percent": 12, "scope": ["model": ["display_name": "Fable"]]]]])
        #expect(windows.first?.label == "Session · Fable")
    }

    @Test func modelWithoutKindDefaultsToWeekly() {
        let windows = ClaudeUsageFetcher.parseWindows(["limits": [["percent": 12, "scope": ["model": ["display_name": "Fable"]]]]])
        #expect(windows.first?.label == "Weekly · Fable")
    }

    @Test func unfamiliarKindRetainsDescription() {
        let windows = ClaudeUsageFetcher.parseWindows(["limits": [["kind": "DAILY", "percent": 12, "scope": ["model": ["display_name": "Fable"]]]]])
        #expect(windows.first?.label == "Fable (daily)")
    }

    @Test func missingAndEmptyModelNamesAreSkipped() {
        let windows = ClaudeUsageFetcher.parseWindows(["limits": [["percent": 10], ["percent": 10, "scope": ["model": ["display_name": ""]]], ["percent": 10, "scope": ["surface": ["display_name": "Code"]]]]])
        #expect(windows.isEmpty)
    }

    @Test func namedWindowsWinDuplicateLabels() {
        let windows = ClaudeUsageFetcher.parseWindows(["seven_day_opus": ["utilization": 23], "limits": [["kind": "weekly", "percent": 90, "scope": ["model": ["display_name": "Opus"]]]]])
        #expect(windows.map(\.usedPercent) == [23])
    }

    @Test func invalidNamedWindowDoesNotSuppressValidModelFallback() {
        let windows = ClaudeUsageFetcher.parseWindows(["seven_day_opus": ["utilization": "bad"], "limits": [["kind": "weekly", "percent": 90, "scope": ["model": ["display_name": "Opus"]]]]])
        #expect(windows.map(\.usedPercent) == [90])
    }

    @Test func extraUsageRequiresEnablementAndValidPercent() {
        #expect(ClaudeUsageFetcher.parseWindows(["extra_usage": ["is_enabled": false, "utilization": 30]]).isEmpty)
        #expect(ClaudeUsageFetcher.parseWindows(["extra_usage": ["utilization": 30]]).isEmpty)
        #expect(ClaudeUsageFetcher.parseWindows(["extra_usage": ["is_enabled": true]]).isEmpty)
        let windows = ClaudeUsageFetcher.parseWindows(["extra_usage": ["is_enabled": true, "utilization": 30]])
        #expect(windows.first?.label == "Extra usage")
        #expect(windows.first?.usedPercent == 30)
        #expect(windows.first?.resetsAt == nil)
    }

    @Test func numericDatesSupportSecondsAndMilliseconds() {
        let expected = Date(timeIntervalSince1970: 1791894570)
        #expect(ClaudeUsageFetcher.date(1791894570) == expected)
        #expect(ClaudeUsageFetcher.date(1791894570000) == expected)
    }

    @Test(arguments: ["2026-10-08T12:00:00Z", "2026-10-08T14:00:00+02:00", "2026-10-08T12:00:00.000000Z"])
    func isoDatesPreserveTimezone(value: String) {
        #expect(ClaudeUsageFetcher.date(value) == ClaudeUsageFetcher.date("2026-10-08T12:00:00Z"))
        #expect(ClaudeUsageFetcher.date(value) != nil)
    }

    @Test func invalidDatesAreAbsent() {
        for value in [true, false, Double.nan, Double.infinity, -Double.infinity, "", "nonsense", NSNull(), []] as [Any] {
            #expect(ClaudeUsageFetcher.date(value) == nil)
        }
    }

    @Test func badResetDoesNotDiscardUsage() {
        let window = ClaudeUsageFetcher.parseWindows(["five_hour": ["utilization": 20, "resets_at": "invalid"]]).first
        #expect(window?.usedPercent == 20)
        #expect(window?.resetsAt == nil)
    }

    @Test func knownPlansAndTierMultipliers() {
        #expect(ClaudeUsageFetcher.planName(subscriptionType: "MAX", rateLimitTier: "default_claude_max_20x") == "Max 20x")
        #expect(ClaudeUsageFetcher.planName(subscriptionType: nil, rateLimitTier: "default_claude_max_5x") == "Max 5x")
        #expect(ClaudeUsageFetcher.planName(subscriptionType: "max", rateLimitTier: nil) == "Max")
        #expect(ClaudeUsageFetcher.planName(subscriptionType: "claude_pro", rateLimitTier: nil) == "Pro")
        #expect(ClaudeUsageFetcher.planName(subscriptionType: nil, rateLimitTier: "claude_pro") == "Pro")
        #expect(ClaudeUsageFetcher.planName(subscriptionType: "team", rateLimitTier: nil) == "Team")
        #expect(ClaudeUsageFetcher.planName(subscriptionType: nil, rateLimitTier: "enterprise") == "Enterprise")
    }

    @Test func missingAndUnknownPlans() {
        #expect(ClaudeUsageFetcher.planName(subscriptionType: nil, rateLimitTier: nil) == nil)
        #expect(ClaudeUsageFetcher.planName(subscriptionType: "", rateLimitTier: "unknown") == nil)
        #expect(ClaudeUsageFetcher.planName(subscriptionType: "claude_custom", rateLimitTier: nil) == "Custom")
    }

    @Test func credentialsPreserveMetadataAndConvertExpiration() throws {
        let credential = try #require(ClaudeUsageFetcher.parseCredential(Data(#"{"claudeAiOauth":{"accessToken":"fake-token","expiresAt":2000000000000,"subscriptionType":"max","rateLimitTier":"20x"}}"#.utf8)))
        #expect(credential.accessToken == "fake-token")
        #expect(credential.expiresAt == Date(timeIntervalSince1970: 2000000000))
        #expect(credential.subscriptionType == "max")
        #expect(credential.rateLimitTier == "20x")
    }

    @Test(arguments: ["{}", "[]", "bad", "{\"claudeAiOauth\":{}}", "{\"claudeAiOauth\":{\"accessToken\":\"\"}}", "{\"claudeAiOauth\":{\"accessToken\":42}}", "{\"claudeAiOauth\":null}"])
    func invalidCredentialBlobsAreRejected(blob: String) {
        #expect(ClaudeUsageFetcher.parseCredential(Data(blob.utf8)) == nil)
    }

    @Test func hexCredentialsAreDecodedWithWhitespace() throws {
        let raw = Data(#"{"claudeAiOauth":{"accessToken":"fake-token"}}"#.utf8)
        let hex = raw.map { String(format: "%02X", $0) }.joined()
        let credential = try #require(ClaudeUsageFetcher.parseCredential(Data((" \n" + hex + "\n").utf8)))
        #expect(credential.accessToken == "fake-token")
        #expect(credential.expiresAt == nil)
        #expect(!credential.isExpired)
    }

    @Test(arguments: ["f", "gg", "123", "", "00"])
    func malformedHexDoesNotProduceCredential(blob: String) {
        #expect(ClaudeUsageFetcher.parseCredential(Data(blob.utf8)) == nil)
    }

    @Test func invalidExpirationDoesNotProduceNonfiniteDate() throws {
        for expiry in ["NaN", "Infinity", "-1", "0", "invalid"] {
            let blob = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": ["accessToken": "fake", "expiresAt": expiry]])
            let credential = try #require(ClaudeUsageFetcher.parseCredential(blob))
            #expect(credential.expiresAt == nil)
        }
        let blob = Data(#"{"claudeAiOauth":{"accessToken":"fake","expiresAt":true}}"#.utf8)
        #expect(ClaudeUsageFetcher.parseCredential(blob)?.expiresAt == nil)
    }

    @Test func tokenExpiryIncludesRefreshSafetyMargin() {
        let missing = ClaudeUsageFetcher.OAuthCredential(accessToken: "fake", expiresAt: nil, subscriptionType: nil, rateLimitTier: nil)
        #expect(!missing.isExpired)
        for offset in [-3600.0, 10] {
            let credential = ClaudeUsageFetcher.OAuthCredential(accessToken: "fake", expiresAt: Date().addingTimeInterval(offset), subscriptionType: nil, rateLimitTier: nil)
            #expect(credential.isExpired)
        }
        let future = ClaudeUsageFetcher.OAuthCredential(accessToken: "fake", expiresAt: Date().addingTimeInterval(3600), subscriptionType: nil, rateLimitTier: nil)
        #expect(!future.isExpired)
    }
}
