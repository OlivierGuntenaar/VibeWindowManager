import Foundation
import Testing
@testable import VibeWindowManager

@MainActor
private final class ClaudePolicyClock {
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

@MainActor
private final class ClaudePolicyLoader {
    var calls = 0
    var responses: [ClaudeUsageFetcher.Snapshot] = []
    var pending: [Int: CheckedContinuation<ClaudeUsageFetcher.Snapshot, Never>] = [:]
    var cancelledReturns = 0

    func load() async -> ClaudeUsageFetcher.Snapshot {
        calls += 1
        if !responses.isEmpty { return responses.removeFirst() }
        let call = calls
        let result = await withCheckedContinuation { pending[call] = $0 }
        if Task.isCancelled { cancelledReturns += 1 }
        return result
    }

    func finish(_ call: Int, with snapshot: ClaudeUsageFetcher.Snapshot) {
        pending.removeValue(forKey: call)?.resume(returning: snapshot)
    }
}

@MainActor
struct ClaudeRefreshPolicyTests {
    private func success(_ percent: Double = 25) -> ClaudeUsageFetcher.Snapshot {
        .init(planName: "Pro", windows: [.init(label: "Session", usedPercent: percent, resetsAt: nil)])
    }
    private func limited(retry: Date? = nil) -> ClaudeUsageFetcher.Snapshot {
        .init(errorMessage: "429 cooldown", httpStatus: 429, retryAfter: retry, isTransient: true)
    }
    private func eventually(_ check: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !check(), ContinuousClock.now < deadline { await Task.yield() }
        return check()
    }

    @Test func keychainAuthorizationRetriesAccessErrorsButNeverBypasses429() async {
        let clock = ClaudePolicyClock(), loader = ClaudePolicyLoader()
        loader.responses = [.init(errorMessage: "Keychain blocked", isTransient: true, requiresKeychainAccess: true),
                            limited(retry: clock.date.addingTimeInterval(7200)), success()]
        let policy = ClaudeRefreshCoordinator(loader: loader.load, now: { clock.date })
        #expect(await policy.fetch().requiresKeychainAccess)
        policy.keychainAccessWasGranted()
        #expect(await policy.fetch().errorMessage == "429 cooldown")
        policy.keychainAccessWasGranted()
        _ = await policy.fetch()
        #expect(loader.calls == 2)
        #expect(policy.nextAllowedAt == clock.date.addingTimeInterval(7200))
    }

    @Test func successfulUsageIsCachedForAtLeastFiveMinutes() async {
        let clock = ClaudePolicyClock(), loader = ClaudePolicyLoader()
        loader.responses = [success(10), success(30)]
        let policy = ClaudeRefreshCoordinator(loader: loader.load, now: { clock.date })
        let first = await policy.fetch(minimumRefreshInterval: 0)
        clock.advance(299)
        #expect(await policy.fetch(minimumRefreshInterval: 0) == first)
        #expect(loader.calls == 1)
        clock.advance(1)
        #expect(await policy.fetch().windows.first?.usedPercent == 30)
        #expect(loader.calls == 2)
    }

    @Test func longerRequestedSuccessCacheIsHonored() async {
        let clock = ClaudePolicyClock(), loader = ClaudePolicyLoader()
        loader.responses = [success(), success(30)]
        let policy = ClaudeRefreshCoordinator(loader: loader.load, now: { clock.date })
        _ = await policy.fetch(minimumRefreshInterval: 900)
        clock.advance(899)
        _ = await policy.fetch()
        #expect(loader.calls == 1)
        clock.advance(1)
        _ = await policy.fetch()
        #expect(loader.calls == 2)
    }

    @Test func repeatedErrorDoesNotHammerOnReopen() async {
        let clock = ClaudePolicyClock(), loader = ClaudePolicyLoader()
        loader.responses = [.init(errorMessage: "Offline", isTransient: true), success()]
        let policy = ClaudeRefreshCoordinator(loader: loader.load, now: { clock.date })
        let first = await policy.fetch()
        for _ in 0..<25 { #expect(await policy.fetch() == first) }
        #expect(loader.calls == 1)
        clock.advance(300)
        #expect(await policy.fetch().errorMessage == nil)
        #expect(loader.calls == 2)
    }

    @Test func rateLimitBackoffDoublesAndCapsAtOneHour() async {
        let clock = ClaudePolicyClock(), loader = ClaudePolicyLoader()
        loader.responses = Array(repeating: limited(), count: 7)
        let policy = ClaudeRefreshCoordinator(loader: loader.load, now: { clock.date })
        for expected in [300.0, 600, 1200, 2400, 3600, 3600, 3600] {
            _ = await policy.fetch()
            #expect(policy.nextAllowedAt == clock.date.addingTimeInterval(expected))
            clock.advance(expected)
        }
        #expect(loader.calls == 7)
    }

    @Test func longerServerRetryAfterOverridesLocalCap() async {
        let clock = ClaudePolicyClock(), loader = ClaudePolicyLoader()
        let retry = clock.date.addingTimeInterval(7200)
        loader.responses = [limited(retry: retry), success()]
        let policy = ClaudeRefreshCoordinator(loader: loader.load, now: { clock.date })
        _ = await policy.fetch()
        #expect(policy.nextAllowedAt == retry)
        clock.advance(7199)
        _ = await policy.fetch()
        #expect(loader.calls == 1)
        clock.advance(1)
        _ = await policy.fetch()
        #expect(loader.calls == 2)
    }

    @Test func successResetsExponentialBackoff() async {
        let clock = ClaudePolicyClock(), loader = ClaudePolicyLoader()
        loader.responses = [limited(), limited(), success(), limited()]
        let policy = ClaudeRefreshCoordinator(loader: loader.load, now: { clock.date })
        _ = await policy.fetch(); clock.advance(300)
        _ = await policy.fetch(); clock.advance(600)
        _ = await policy.fetch(); clock.advance(300)
        _ = await policy.fetch()
        #expect(policy.nextAllowedAt == clock.date.addingTimeInterval(300))
    }

    @Test func transientErrorKeepsLastGoodWindowsAndTheirOriginalTimestamp() async {
        let clock = ClaudePolicyClock(), loader = ClaudePolicyLoader()
        loader.responses = [success(42), limited()]
        let policy = ClaudeRefreshCoordinator(loader: loader.load, now: { clock.date })
        let good = await policy.fetch()
        clock.advance(300)
        let stale = await policy.fetch()
        #expect(stale.windows == good.windows)
        #expect(stale.planName == good.planName)
        #expect(stale.fetchedAt == good.fetchedAt)
        #expect(stale.errorMessage?.contains("Showing cached usage") == true)
        #expect(stale.errorMessage?.contains("429") == true)
    }

    @Test func authenticationFailureDoesNotPresentOldAccountUsage() async {
        let clock = ClaudePolicyClock(), loader = ClaudePolicyLoader()
        loader.responses = [success(), .init(errorMessage: "Token rejected", httpStatus: 401)]
        let policy = ClaudeRefreshCoordinator(loader: loader.load, now: { clock.date })
        _ = await policy.fetch()
        clock.advance(300)
        let rejected = await policy.fetch()
        #expect(rejected.windows.isEmpty)
        #expect(rejected.errorMessage == "Token rejected")
    }

    @Test func simultaneousCallsShareOneRequest() async throws {
        let loader = ClaudePolicyLoader()
        let policy = ClaudeRefreshCoordinator(loader: loader.load)
        let tasks = (0..<10).map { _ in Task { await policy.fetch() } }
        try #require(await eventually { loader.calls == 1 })
        loader.finish(1, with: success(19))
        for task in tasks { #expect(await task.value.windows.first?.usedPercent == 19) }
        #expect(loader.calls == 1)
    }

    @Test func cancellingOnlyWaiterDoesNotCacheCancelledOutput() async throws {
        let loader = ClaudePolicyLoader()
        let policy = ClaudeRefreshCoordinator(loader: loader.load)
        let task = Task { await policy.fetch() }
        try #require(await eventually { loader.calls == 1 })
        task.cancel()
        loader.finish(1, with: success(90))
        _ = await task.value
        #expect(policy.nextAllowedAt == nil)
        loader.responses = [success(12)]
        #expect(await policy.fetch().windows.first?.usedPercent == 12)
        #expect(loader.calls == 2)
    }

    @Test func oneCancelledCallerDoesNotCancelOtherCallersResult() async throws {
        let loader = ClaudePolicyLoader()
        let policy = ClaudeRefreshCoordinator(loader: loader.load)
        let first = Task { await policy.fetch() }
        let second = Task { await policy.fetch() }
        try #require(await eventually { loader.calls == 1 })
        try #require(await eventually { policy.activeWaiterCount == 2 })
        first.cancel()
        loader.finish(1, with: success(55))
        _ = await first.value
        #expect(await second.value.windows.first?.usedPercent == 55)
        #expect(loader.calls == 1)
        #expect(await policy.fetch().windows.first?.usedPercent == 55)
    }

    @Test func cancelledTransportSnapshotNeverSetsCooldown() async {
        let loader = ClaudePolicyLoader()
        loader.responses = [.init(errorMessage: "Cancelled", isCancelled: true), success()]
        let policy = ClaudeRefreshCoordinator(loader: loader.load)
        _ = await policy.fetch()
        #expect(policy.nextAllowedAt == nil)
        #expect(await policy.fetch().errorMessage == nil)
        #expect(loader.calls == 2)
    }

    @Test func cooldownSurvivesRelaunchWithoutPersistingUsageOrCredentials() async throws {
        let suite = "ClaudeRefreshPolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = ClaudePolicyClock(), loader = ClaudePolicyLoader()
        loader.responses = [limited()]
        let policy = ClaudeRefreshCoordinator(loader: loader.load, now: { clock.date }, defaults: defaults)
        _ = await policy.fetch()
        let restartedLoader = ClaudePolicyLoader()
        restartedLoader.responses = [limited()]
        let restarted = ClaudeRefreshCoordinator(loader: restartedLoader.load, now: { clock.date }, defaults: defaults)
        let waiting = await restarted.fetch()
        #expect(restartedLoader.calls == 0)
        #expect(waiting.windows.isEmpty)
        #expect(waiting.errorMessage?.contains("cooling down") == true)
        #expect(Set(defaults.persistentDomain(forName: suite)?.keys.map { $0 } ?? []) ==
                Set([ClaudeRefreshCoordinator.cooldownKey, ClaudeRefreshCoordinator.rateLimitCountKey]))
        clock.advance(300)
        _ = await restarted.fetch()
        #expect(restartedLoader.calls == 1)
        #expect(restarted.nextAllowedAt == clock.date.addingTimeInterval(600))
    }

    @Test(arguments: ["", "garbage", "-1", "NaN", "inf", "1e308", "1e3", "30.5", "+30"])
    func malformedRetryAfterIsIgnored(header: String) {
        #expect(ClaudeUsageFetcher.retryDate(header, now: Date()) == nil)
    }

    @Test(arguments: [Double.greatestFiniteMagnitude, 1e308, 7200.0])
    func excessiveLocalCacheIntervalIsLimitedToOneHour(interval: Double) async {
        let clock = ClaudePolicyClock(), loader = ClaudePolicyLoader()
        loader.responses = [success()]
        let policy = ClaudeRefreshCoordinator(loader: loader.load, now: { clock.date })
        _ = await policy.fetch(minimumRefreshInterval: interval)
        #expect(policy.nextAllowedAt == clock.date.addingTimeInterval(3600))
    }

    @Test func serverCooldownIsBoundedToSevenDaysAtParserAndPolicyBoundaries() async {
        let clock = ClaudePolicyClock(), loader = ClaudePolicyLoader()
        let maximum = clock.date.addingTimeInterval(7 * 24 * 3600)
        #expect(ClaudeUsageFetcher.retryDate("999999999999999999999999999", now: clock.date) == maximum)
        #expect(ClaudeUsageFetcher.retryDate("Fri, 01 Jan 2100 00:00:00 GMT", now: clock.date) == maximum)
        loader.responses = [limited(retry: Date(timeIntervalSince1970: 1e308))]
        let policy = ClaudeRefreshCoordinator(loader: loader.load, now: { clock.date })
        _ = await policy.fetch()
        #expect(policy.nextAllowedAt == maximum)
    }

    @Test func absurdPersistedCooldownCannotDisableRefreshPermanently() async throws {
        let suite = "ClaudeRefreshPolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = ClaudePolicyClock(), loader = ClaudePolicyLoader()
        defaults.set(clock.date.addingTimeInterval(8 * 24 * 3600), forKey: ClaudeRefreshCoordinator.cooldownKey)
        defaults.set(5, forKey: ClaudeRefreshCoordinator.rateLimitCountKey)
        loader.responses = [limited()]
        let policy = ClaudeRefreshCoordinator(loader: loader.load, now: { clock.date }, defaults: defaults)
        #expect(policy.nextAllowedAt == nil)
        _ = await policy.fetch()
        #expect(loader.calls == 1)
        #expect(policy.nextAllowedAt == clock.date.addingTimeInterval(300))
    }

    @Test func retryAfterSupportsSecondsAndHTTPDate() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ClaudeUsageFetcher.retryDate(" 7200 ", now: now) == now.addingTimeInterval(7200))
        #expect(ClaudeUsageFetcher.retryDate("Wed, 21 Oct 2015 07:28:00 GMT", now: now) ==
                Date(timeIntervalSince1970: 1_445_412_480))
        #expect(ClaudeUsageFetcher.retryDate(nil, now: now) == nil)
    }

    @Test func actual429ResponseCapturesRetryHeaderWithoutLiveCredentialsOrNetwork() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = await ClaudeUsageFetcher.loadSnapshot(
            session: { .found(.init(accessToken: "fixture-token", expiresAt: nil, scopes: ["user:profile"],
                                    subscriptionType: "pro", rateLimitTier: nil)) },
            transport: { request in
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
                #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
                return (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil,
                                              headerFields: ["Retry-After": "7200"])!)
            }, now: { now })
        #expect(snapshot.httpStatus == 429)
        #expect(snapshot.retryAfter == now.addingTimeInterval(7200))
        #expect(snapshot.isTransient)
        #expect(snapshot.errorMessage?.contains("Retrying automatically") == true)
    }

    @Test func networkFailureIsTransientAndCancellationIsRecognized() async {
        let lookup: @Sendable () async -> ClaudeDesktopSession.Lookup = {
            .found(.init(accessToken: "fixture", expiresAt: nil, scopes: ["user:profile"], subscriptionType: nil, rateLimitTier: nil))
        }
        let offline = await ClaudeUsageFetcher.loadSnapshot(session: lookup,
            transport: { _ in throw URLError(.notConnectedToInternet) })
        #expect(offline.isTransient)
        #expect(!offline.isCancelled)
        let cancelled = await ClaudeUsageFetcher.loadSnapshot(session: lookup,
            transport: { _ in throw URLError(.cancelled) })
        #expect(cancelled.isCancelled)
    }
}
