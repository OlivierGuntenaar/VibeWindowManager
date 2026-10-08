import Foundation
import Testing
@testable import VibeWindowManager

@MainActor
private final class LifecycleFetcher: UsageFetching {
    private(set) var calls = 0
    private(set) var completed = 0
    private(set) var cancelledCompletions = 0
    private var pending: [Int: CheckedContinuation<ProviderUsage, Never>] = [:]

    func fetch() async -> ProviderUsage {
        calls += 1
        let call = calls
        let result = await withCheckedContinuation { pending[call] = $0 }
        completed += 1
        if Task.isCancelled { cancelledCompletions += 1 }
        return result
    }

    func finish(call: Int, provider: UsageProvider, percent: Double) {
        let result = ProviderUsage(provider: provider, planName: nil,
                                   windows: [UsageWindow(label: "Session", usedPercent: percent, resetsAt: nil)],
                                   fetchedAt: Date(), errorMessage: nil)
        pending.removeValue(forKey: call)?.resume(returning: result)
    }
}

@MainActor
private final class ManualUsageTimers {
    private(set) var timers: [Timer] = []

    func make(interval: TimeInterval, action: @escaping @Sendable (Timer) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true, block: action)
        timers.append(timer)
        return timer
    }
}

@MainActor
struct UsageConcurrencyLifecycleTests {
    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        return condition()
    }

    @Test func cancelledOldRefreshCannotOverwriteNewerResults() async throws {
        let fetcher = LifecycleFetcher()
        let service = UsageLimitsService(fetchers: [.cursor: fetcher])
        service.refresh()
        try #require(await eventually { fetcher.calls == 1 })
        service.cancelRefresh()
        #expect(!service.isRefreshing)
        #expect(service.lastRefreshed == nil)
        service.refresh()
        try #require(await eventually { fetcher.calls == 2 })
        fetcher.finish(call: 2, provider: .cursor, percent: 80)
        try #require(await eventually { !service.isRefreshing })
        let completedAt = service.lastRefreshed
        fetcher.finish(call: 1, provider: .cursor, percent: 10)
        try #require(await eventually { fetcher.completed == 2 })
        #expect(service.cursor?.windows.first?.usedPercent == 80)
        #expect(service.lastRefreshed == completedAt)
        #expect(fetcher.cancelledCompletions == 1)
    }

    @Test func oldRefreshCompletionCannotClearNewRefreshSpinner() async throws {
        let fetcher = LifecycleFetcher()
        let service = UsageLimitsService(fetchers: [.cursor: fetcher])
        service.refresh()
        try #require(await eventually { fetcher.calls == 1 })
        service.cancelRefresh()
        service.refresh()
        try #require(await eventually { fetcher.calls == 2 })
        fetcher.finish(call: 1, provider: .cursor, percent: 10)
        try #require(await eventually { fetcher.completed == 1 })
        #expect(service.isRefreshing)
        #expect(service.cursor == nil)
        #expect(service.lastRefreshed == nil)
        fetcher.finish(call: 2, provider: .cursor, percent: 80)
        try #require(await eventually { !service.isRefreshing })
        #expect(service.cursor?.windows.first?.usedPercent == 80)
    }

    @Test func cancelPreservesCompletedProviderAndIgnoresLateProvider() async throws {
        let cursor = LifecycleFetcher(), claude = LifecycleFetcher()
        let service = UsageLimitsService(fetchers: [.cursor: cursor, .claude: claude])
        service.refresh()
        try #require(await eventually { cursor.calls == 1 && claude.calls == 1 })
        cursor.finish(call: 1, provider: .cursor, percent: 35)
        try #require(await eventually { service.cursor != nil })
        service.cancelRefresh()
        service.cancelRefresh()
        claude.finish(call: 1, provider: .claude, percent: 90)
        try #require(await eventually { claude.completed == 1 })
        #expect(service.cursor?.windows.first?.usedPercent == 35)
        #expect(service.claude == nil)
        #expect(service.lastRefreshed == nil)
        #expect(!service.isRefreshing)
    }

    @Test func timerTicksDuringSlowRefreshDoNotStartDuplicateFetches() async throws {
        let fetcher = LifecycleFetcher(), timers = ManualUsageTimers()
        let service = UsageLimitsService(fetchers: [.cursor: fetcher], makeTimer: timers.make)
        defer { service.stopAutoRefresh() }
        service.startAutoRefresh(interval: 300)
        try #require(await eventually { fetcher.calls == 1 })
        let timer = try #require(timers.timers.first)
        for _ in 0..<20 { timer.fire() }
        #expect(fetcher.calls == 1)
        fetcher.finish(call: 1, provider: .cursor, percent: 10)
        try #require(await eventually { !service.isRefreshing })
        timer.fire()
        try #require(await eventually { fetcher.calls == 2 })
        fetcher.finish(call: 2, provider: .cursor, percent: 20)
        try #require(await eventually { !service.isRefreshing })
        #expect(service.cursor?.windows.first?.usedPercent == 20)
    }

    @Test func restartingAutoRefreshInvalidatesPreviousTimerAndCoalescesWork() async throws {
        let fetcher = LifecycleFetcher(), timers = ManualUsageTimers()
        let service = UsageLimitsService(fetchers: [.cursor: fetcher], makeTimer: timers.make)
        defer { service.stopAutoRefresh() }
        service.startAutoRefresh(interval: 300)
        try #require(await eventually { fetcher.calls == 1 })
        service.startAutoRefresh(interval: 600)
        #expect(timers.timers.count == 2)
        #expect(!timers.timers[0].isValid)
        #expect(timers.timers[1].isValid)
        #expect(fetcher.calls == 1)
        fetcher.finish(call: 1, provider: .cursor, percent: 10)
        try #require(await eventually { !service.isRefreshing })
        service.stopAutoRefresh()
        #expect(!timers.timers[1].isValid)
    }

    @Test func deallocationInvalidatesTimerAndCancelsOutstandingFetch() async throws {
        let fetcher = LifecycleFetcher(), timers = ManualUsageTimers()
        var service: UsageLimitsService? = UsageLimitsService(fetchers: [.cursor: fetcher], makeTimer: timers.make)
        weak var weakService = service
        service?.startAutoRefresh(interval: 300)
        try #require(await eventually { fetcher.calls == 1 })
        let timer = try #require(timers.timers.first)
        service = nil
        #expect(weakService == nil)
        #expect(!timer.isValid)
        fetcher.finish(call: 1, provider: .cursor, percent: 10)
        try #require(await eventually { fetcher.completed == 1 })
        #expect(fetcher.cancelledCompletions == 1)
    }

    @Test(arguments: [0.0, -1.0, Double.nan, Double.infinity, -Double.infinity])
    func invalidTimerIntervalsNeverScheduleOrFetch(interval: Double) {
        let fetcher = LifecycleFetcher(), timers = ManualUsageTimers()
        let service = UsageLimitsService(fetchers: [.cursor: fetcher], makeTimer: timers.make)
        service.startAutoRefresh(interval: interval)
        #expect(timers.timers.isEmpty)
        #expect(fetcher.calls == 0)
        #expect(!service.isRefreshing)
    }

    @Test(arguments: [(10.0, 1.0), (300.0, 30.0), (3_600.0, 30.0)])
    func timerToleranceAllowsCoalescingWakeups(interval: Double, tolerance: Double) async throws {
        let timers = ManualUsageTimers()
        let service = UsageLimitsService(fetchers: [:], makeTimer: timers.make)
        defer { service.stopAutoRefresh() }
        service.startAutoRefresh(interval: interval)
        let timer = try #require(timers.timers.first)
        #expect(timer.timeInterval == interval)
        #expect(timer.tolerance == tolerance)
        try #require(await eventually { !service.isRefreshing })
    }

    @Test func stoppingTimerDoesNotCancelAlreadyRunningRefresh() async throws {
        let fetcher = LifecycleFetcher(), timers = ManualUsageTimers()
        let service = UsageLimitsService(fetchers: [.cursor: fetcher], makeTimer: timers.make)
        service.startAutoRefresh(interval: 300)
        try #require(await eventually { fetcher.calls == 1 })
        service.stopAutoRefresh()
        #expect(!timers.timers[0].isValid)
        #expect(service.isRefreshing)
        fetcher.finish(call: 1, provider: .cursor, percent: 22)
        try #require(await eventually { !service.isRefreshing })
        #expect(service.cursor?.windows.first?.usedPercent == 22)
        #expect(fetcher.cancelledCompletions == 0)
    }
}
