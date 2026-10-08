import Foundation
import Testing
@testable import VibeWindowManager

/// Suspends at the actual network boundary: tests choose which provider finishes first.
@MainActor
private final class ControlledUsageFetcher: UsageFetching {
    private(set) var calls = 0
    private var pending: [CheckedContinuation<ProviderUsage, Never>] = []

    func fetch() async -> ProviderUsage {
        calls += 1
        return await withCheckedContinuation { pending.append($0) }
    }

    func complete(_ value: ProviderUsage) {
        precondition(!pending.isEmpty)
        pending.removeFirst().resume(returning: value)
    }
}

@MainActor
struct UsageLimitsServiceTests {
    private func result(_ provider: UsageProvider, percent: Double = 25, error: String? = nil) -> ProviderUsage {
        ProviderUsage(provider: provider, planName: "Test", windows: error == nil
                      ? [UsageWindow(label: "Session", usedPercent: percent, resetsAt: nil)] : [],
                      fetchedAt: Date(timeIntervalSince1970: 1_000), errorMessage: error)
    }

    /// Bounded condition wait avoids depending on task scheduling order or network timing.
    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    @Test func startsEmptyWithoutFetching() {
        let fetcher = ControlledUsageFetcher()
        let service = UsageLimitsService(fetchers: [.cursor: fetcher])
        #expect(service.claude == nil)
        #expect(service.codex == nil)
        #expect(service.cursor == nil)
        #expect(service.lastRefreshed == nil)
        #expect(!service.isRefreshing)
        #expect(fetcher.calls == 0)
    }

    @Test func defaultWiringIncludesAllThreeProviders() {
        let fetchers = UsageLimitsService.defaultFetchers()
        #expect(fetchers.count == 3)
        #expect(fetchers[.claude] is ClaudeUsageFetcher)
        #expect(fetchers[.codex] is CodexUsageFetcher)
        #expect(fetchers[.cursor] is CursorUsageFetcher)
    }

    @Test func providersRunConcurrentlyAndPublishIndependently() async throws {
        let claude = ControlledUsageFetcher(), codex = ControlledUsageFetcher(), cursor = ControlledUsageFetcher()
        let service = UsageLimitsService(fetchers: [.claude: claude, .codex: codex, .cursor: cursor])
        let started = Date()
        service.refresh()
        #expect(service.isRefreshing)
        #expect(await eventually { claude.calls == 1 && codex.calls == 1 && cursor.calls == 1 })
        cursor.complete(result(.cursor, percent: 21))
        #expect(await eventually { service.cursor != nil })
        #expect(service.usage(for: .cursor) == result(.cursor, percent: 21))
        #expect(service.claude == nil && service.codex == nil)
        #expect(service.isRefreshing && service.lastRefreshed == nil)
        claude.complete(result(.claude, percent: 42))
        #expect(await eventually { service.claude != nil })
        #expect(service.usage(for: .claude) == result(.claude, percent: 42))
        #expect(service.isRefreshing && service.lastRefreshed == nil)
        codex.complete(result(.codex, percent: 65))
        #expect(await eventually { !service.isRefreshing })
        #expect(service.usage(for: .codex) == result(.codex, percent: 65))
        #expect(try #require(service.lastRefreshed) >= started)
    }

    @Test func repeatedRefreshRequestsAreCoalesced() async {
        let fetcher = ControlledUsageFetcher()
        let service = UsageLimitsService(fetchers: [.cursor: fetcher])
        service.refresh()
        service.refresh()
        service.refreshIfStale()
        #expect(await eventually { fetcher.calls == 1 })
        service.refresh()
        fetcher.complete(result(.cursor))
        #expect(await eventually { !service.isRefreshing })
        #expect(fetcher.calls == 1)
    }

    @Test func aNewRefreshReplacesThePreviousUsage() async {
        let fetcher = ControlledUsageFetcher()
        let service = UsageLimitsService(fetchers: [.cursor: fetcher])
        service.refresh()
        #expect(await eventually { fetcher.calls == 1 })
        fetcher.complete(result(.cursor, percent: 10))
        #expect(await eventually { !service.isRefreshing })
        let priorRefresh = service.lastRefreshed
        service.refresh()
        #expect(service.cursor == result(.cursor, percent: 10))
        #expect(service.lastRefreshed == priorRefresh)
        #expect(await eventually { fetcher.calls == 2 })
        fetcher.complete(result(.cursor, percent: 80))
        #expect(await eventually { !service.isRefreshing })
        #expect(service.cursor == result(.cursor, percent: 80))
    }

    @Test func providerFailureDoesNotDiscardOtherProviders() async {
        let claude = ControlledUsageFetcher(), cursor = ControlledUsageFetcher()
        let service = UsageLimitsService(fetchers: [.claude: claude, .cursor: cursor])
        service.refresh()
        #expect(await eventually { claude.calls == 1 && cursor.calls == 1 })
        cursor.complete(result(.cursor, error: "Sign in to Cursor"))
        #expect(await eventually { service.cursor?.errorMessage != nil })
        #expect(service.isRefreshing)
        claude.complete(result(.claude))
        #expect(await eventually { !service.isRefreshing })
        #expect(service.claude == result(.claude))
        #expect(service.cursor?.errorMessage == "Sign in to Cursor")
        #expect(service.lastRefreshed != nil)
    }

    @Test func successfulRetryClearsProviderError() async {
        let fetcher = ControlledUsageFetcher()
        let service = UsageLimitsService(fetchers: [.cursor: fetcher])
        service.refresh()
        #expect(await eventually { fetcher.calls == 1 })
        fetcher.complete(result(.cursor, error: "Offline"))
        #expect(await eventually { !service.isRefreshing })
        service.refresh()
        #expect(await eventually { fetcher.calls == 2 })
        fetcher.complete(result(.cursor))
        #expect(await eventually { !service.isRefreshing })
        #expect(service.cursor?.errorMessage == nil)
        #expect(service.cursor?.windows.count == 1)
    }

    @Test func freshDataSkipsRefresh() {
        let fetcher = ControlledUsageFetcher()
        let service = UsageLimitsService(fetchers: [.cursor: fetcher])
        service.setForPreview(claude: nil, codex: nil, lastRefreshed: Date())
        service.refreshIfStale(maxAge: 60)
        #expect(!service.isRefreshing)
        #expect(fetcher.calls == 0)
    }

    @Test(arguments: [true, false]) func staleOrMissingDataTriggersRefresh(hasPriorRefresh: Bool) async {
        let fetcher = ControlledUsageFetcher()
        let service = UsageLimitsService(fetchers: [.cursor: fetcher])
        service.setForPreview(claude: nil, codex: nil,
                              lastRefreshed: hasPriorRefresh ? Date().addingTimeInterval(-120) : nil)
        service.refreshIfStale(maxAge: 60)
        #expect(await eventually { fetcher.calls == 1 })
        fetcher.complete(result(.cursor))
        #expect(await eventually { !service.isRefreshing })
    }

    @Test func zeroMaxAgeForcesRefreshOfFreshData() async {
        let fetcher = ControlledUsageFetcher()
        let service = UsageLimitsService(fetchers: [.cursor: fetcher])
        service.setForPreview(claude: nil, codex: nil, lastRefreshed: Date())
        service.refreshIfStale(maxAge: 0)
        #expect(await eventually { fetcher.calls == 1 })
        fetcher.complete(result(.cursor))
        #expect(await eventually { !service.isRefreshing })
    }

    @Test func emptyFetcherMapStillCompletesRefresh() async {
        let service = UsageLimitsService(fetchers: [:])
        service.refresh()
        #expect(await eventually { !service.isRefreshing })
        #expect(service.lastRefreshed != nil)
    }

    @Test func autoRefreshStartsImmediatelyAndCanBeStoppedRepeatedly() async {
        let fetcher = ControlledUsageFetcher()
        let service = UsageLimitsService(fetchers: [.cursor: fetcher])
        defer { service.stopAutoRefresh() }
        service.startAutoRefresh(interval: 3_600)
        #expect(await eventually { fetcher.calls == 1 })
        service.stopAutoRefresh()
        service.stopAutoRefresh()
        // Stopping the timer must not abandon a refresh that is already in flight.
        fetcher.complete(result(.cursor))
        #expect(await eventually { !service.isRefreshing })
        #expect(service.cursor == result(.cursor))
    }
}
