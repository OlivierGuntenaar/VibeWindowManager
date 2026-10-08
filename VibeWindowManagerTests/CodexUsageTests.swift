import Foundation
import Testing
@testable import VibeWindowManager

struct CodexUsageTests {
    @Test func liveSessionAndWeeklyWindowsAreSortedByDuration() throws {
        let result = try #require(CodexUsageEngine.parseLive(["rateLimits": [
            "limitId": "codex", "planType": "plus",
            "primary": ["usedPercent": "75.5", "windowDurationMins": 10080],
            "secondary": ["usedPercent": 21, "windowDurationMins": 300]
        ]]))
        #expect(result.planName == "Plus")
        #expect(result.source == "app-server")
        #expect(result.windows.map(\.label) == ["Session (5h)", "Weekly"])
        #expect(result.windows.map(\.usedPercent) == [21, 75.5])
        #expect(result.errorMessage == nil)
    }

    @Test func duplicatedMainBucketIsOnlyShownOnce() throws {
        let main: [String: Any] = ["limitId": "codex", "primary": ["usedPercent": 10, "windowDurationMins": 300]]
        let result = try #require(CodexUsageEngine.parseLive([
            "rateLimits": main, "rateLimitsByLimitId": ["codex": main,
                "review": ["limitId": "review", "limitName": "Reviews", "primary": ["usedPercent": 30, "windowDurationMins": 300]]]
        ]))
        #expect(result.windows.map(\.label) == ["Session (5h)", "Reviews · Session (5h)"])
        #expect(result.windows.map(\.usedPercent) == [10, 30])
    }

    @Test func mapKeysPreserveBucketsWithoutEmbeddedIDs() throws {
        let result = try #require(CodexUsageEngine.parseLive(["rateLimitsByLimitId": [
            "review": ["primary": ["usedPercent": 20, "windowDurationMins": 300]],
            "codex": ["primary": ["usedPercent": 10, "windowDurationMins": 300]],
            "agent": ["primary": ["usedPercent": 30, "windowDurationMins": 300]]
        ]]))
        #expect(result.windows.map(\.label) == ["Session (5h)", "agent · Session (5h)", "review · Session (5h)"])
        #expect(result.windows.map(\.usedPercent) == [10, 30, 20])
    }

    @Test func duplicateWindowLabelsAreRemoved() throws {
        let result = try #require(CodexUsageEngine.parseLive(["rateLimits": [
            "primary": ["usedPercent": 10, "windowDurationMins": 300],
            "secondary": ["usedPercent": 90, "windowDurationMins": 300]
        ]]))
        #expect(result.windows.count == 1)
        #expect(result.windows.first?.usedPercent == 10)
    }

    @Test func malformedBucketsAndMissingUsageAreIgnored() throws {
        #expect(CodexUsageEngine.parseLive([:]) == nil)
        #expect(CodexUsageEngine.parseLive(["rateLimits": NSNull(), "rateLimitsByLimitId": ["bad": "not a bucket"]]) == nil)
        let result = try #require(CodexUsageEngine.parseLive(["rateLimits": [
            "primary": ["windowDurationMins": 300], "secondary": NSNull()
        ]]))
        #expect(result.windows.isEmpty)
    }

    @Test(arguments: ["NaN", "nan", "inf", "-inf", "1e309", "garbage"])
    func nonfiniteAndInvalidUsageIsIgnored(raw: String) throws {
        let result = try #require(CodexUsageEngine.parseLive(["rateLimits": [
            "primary": ["usedPercent": raw], "secondary": ["usedPercent": 42]
        ]]))
        #expect(result.windows.map(\.label) == ["Secondary"])
        #expect(result.windows.map(\.usedPercent) == [42])
    }

    @Test(arguments: ["NaN", "inf", "-inf", "1e300", "9223372036854775808", "-1", "0", "nope"])
    func invalidDurationFallsBackWithoutCrashing(raw: String) throws {
        let live = try #require(CodexUsageEngine.parseLive(["rateLimits": [
            "primary": ["usedPercent": 42, "windowDurationMins": raw]
        ]]))
        #expect(live.windows.first?.label == "Primary")
        let fallback = try #require(CodexRolloutReader.parseSnakeCase([
            "primary": ["used_percent": 42, "window_minutes": raw]
        ], snapshotDate: Date()))
        #expect(fallback.windows.first?.label == "Primary")
    }

    @Test func booleanFieldsAreNotNumbers() throws {
        #expect(CodexUsageEngine.number(true) == nil)
        #expect(CodexUsageEngine.number(false) == nil)
        #expect(CodexUsageEngine.number(NSNumber(value: 1)) == 1)
        #expect(CodexUsageEngine.number(Double.infinity) == nil)
        #expect(CodexUsageEngine.number(Double.nan) == nil)
        let result = try #require(CodexUsageEngine.parseLive(["rateLimits": ["primary": ["usedPercent": true]]]))
        #expect(result.windows.isEmpty)
    }

    @Test func extremeSortKeysDoNotOverflow() {
        let window = CodexUsageEngine.makeWindow(label: "Large", used: 50, resetsAt: nil,
                                                 minutes: Int.max, bucket: 1, slot: 0, now: Date())
        #expect(window.sortKey == Int.max)
        let largeBucket = CodexUsageEngine.makeWindow(label: "Large bucket", used: 50, resetsAt: nil,
                                                      minutes: 300, bucket: Int.max, slot: 0, now: Date())
        #expect(largeBucket.sortKey == Int.max)
    }

    @Test(arguments: [(-10.0, 0.0), (0.0, 0.0), (25.5, 25.5), (120.0, 100.0)])
    func finiteUsageIsClamped(raw: Double, expected: Double) throws {
        let result = try #require(CodexUsageEngine.parseLive(["rateLimits": ["primary": ["usedPercent": raw]]]))
        #expect(result.windows.first?.usedPercent == expected)
    }

    @Test(arguments: [-1.0, 0.0, 1.0]) func expiredWindowsClearUsage(offset: Double) {
        let now = Date(timeIntervalSince1970: 1_000)
        let window = CodexUsageEngine.makeWindow(label: "Session", used: 75,
                                                 resetsAt: now.addingTimeInterval(offset), minutes: 300,
                                                 bucket: 0, slot: 0, now: now)
        #expect(window.usedPercent == (offset <= 0 ? 0 : 75))
        #expect(window.resetsAt == (offset <= 0 ? nil : now.addingTimeInterval(offset)))
    }

    @Test(arguments: [(300, "Session (5h)"), (10080, "Weekly"), (15, "15m window"),
                      (120, "2h window"), (90, "1.5h window"), (0, "Fallback"), (-1, "Fallback")])
    func durationLabels(minutes: Int, expected: String) {
        #expect(CodexUsageEngine.windowLabel(minutes: minutes, fallback: "Fallback") == expected)
    }

    @Test(arguments: [("plus", "Plus"), ("prolite", "Pro Lite"), ("edu_plus", "Edu Plus"),
                      ("custom_plan", "Custom Plan"), ("enterprise", "Enterprise")])
    func planLabels(raw: String, expected: String) {
        #expect(CodexUsageEngine.displayPlanName(raw) == expected)
    }

    @Test func absentAndUnknownPlansAreOmitted() {
        #expect(CodexUsageEngine.displayPlanName(nil) == nil)
        #expect(CodexUsageEngine.displayPlanName("") == nil)
        #expect(CodexUsageEngine.displayPlanName("unknown") == nil)
    }

    @Test func fallbackRelativeResetUsesSnapshotTime() throws {
        let snapshot = Date().addingTimeInterval(-60)
        let result = try #require(CodexRolloutReader.parseSnakeCase([
            "plan_type": "pro", "primary": ["used_percent": 35, "window_minutes": 300, "resets_in_seconds": 3600]
        ], snapshotDate: snapshot))
        #expect(result.fetchedAt == snapshot)
        #expect(result.source == "session-log")
        #expect(result.planName == "Pro")
        #expect(result.windows.first?.resetsAt == snapshot.addingTimeInterval(3600))
    }

    @Test func fallbackAbsoluteResetWinsOverRelativeReset() throws {
        let future = Date().addingTimeInterval(7200)
        let result = try #require(CodexRolloutReader.parseSnakeCase([
            "primary": ["used_percent": 35, "resets_at": future.timeIntervalSince1970, "resets_in_seconds": 1]
        ], snapshotDate: Date()))
        let reset = try #require(result.windows.first?.resetsAt)
        #expect(abs(reset.timeIntervalSince(future)) < 0.000001)
    }

    @Test func staleFallbackClearsExpiredWindow() throws {
        let snapshot = Date(timeIntervalSince1970: 1000)
        let result = try #require(CodexRolloutReader.parseSnakeCase([
            "primary": ["used_percent": 90, "resets_in_seconds": 60]
        ], snapshotDate: snapshot))
        #expect(result.windows.first?.usedPercent == 0)
        #expect(result.windows.first?.resetsAt == nil)
        #expect(result.fetchedAt == snapshot)
    }

    @Test func emptyFallbackIsUnavailable() {
        #expect(CodexRolloutReader.parseSnakeCase([:], snapshotDate: Date()) == nil)
        #expect(CodexRolloutReader.parseSnakeCase(["primary": ["used_percent": "NaN"]], snapshotDate: Date()) == nil)
    }

    private func withRollout(_ content: String, body: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codex-test-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(content.utf8).write(to: url)
        try body(url)
    }

    @Test func rolloutSkipsNoiseAndUsesLatestValidEvent() throws {
        try withRollout("""
        {"type":"event_msg","timestamp":"2026-01-02T03:04:05Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":10}}}}
        {"type":"event_msg","timestamp":"2026-01-03T03:04:05.123Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":40}}}}
        {"type":"event_msg","payload":{"type":"other","rate_limits":{"primary":{"used_percent":99}}}}
        {"type":"event_msg","payload":{"type":"token_count","rate_limits":{}}}
        {"type":"event_msg","payload":{"type":"token_count","rate_limits":
        """) { url in
            let result = try #require(CodexRolloutReader.parseTail(of: url))
            #expect(result.windows.first?.usedPercent == 40)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            #expect(result.fetchedAt == formatter.date(from: "2026-01-03T03:04:05.123Z"))
        }
    }

    @Test func rolloutWithoutTimestampUsesFileModificationTime() throws {
        try withRollout(#"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":12}}}}"#) { url in
            let modified = Date(timeIntervalSince1970: 1_700_000_000)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            let result = try #require(CodexRolloutReader.parseTail(of: url))
            #expect(result.fetchedAt == modified)
        }
    }

    @Test func rolloutWithoutValidEventsReturnsNil() throws {
        try withRollout("garbage\n{}\n") { url in
            #expect(CodexRolloutReader.parseTail(of: url) == nil)
        }
        #expect(CodexRolloutReader.parseTail(of: URL(fileURLWithPath: "/tmp/\(UUID().uuidString)-missing")) == nil)
    }

    @Test func largeRolloutTruncatedFirstLineDoesNotHideLatestEvent() throws {
        let noise = String(repeating: "x", count: 4 * 1024 * 1024 + 100)
        let event = #"{"type":"event_msg","timestamp":"2026-01-02T03:04:05Z","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":17}}}}"#
        try withRollout(noise + "\n" + event) { url in
            #expect(CodexRolloutReader.parseTail(of: url)?.windows.first?.usedPercent == 17)
        }
    }

    @MainActor @Test func resultPreservesUsageAndErrorWhenConvertedForUI() {
        let result = CodexUsageResult(planName: "Pro", windows: [.init(label: "Weekly", usedPercent: 25,
                                                                      resetsAt: nil, sortKey: 0)],
                                      fetchedAt: Date(timeIntervalSince1970: 100), errorMessage: "Cached", source: "session-log")
        let usage = result.asProviderUsage()
        #expect(usage.provider == .codex)
        #expect(usage.planName == "Pro")
        #expect(usage.fetchedAt == result.fetchedAt)
        #expect(usage.windows.first?.usedPercent == 25)
        #expect(usage.errorMessage == "Cached")
    }
}
