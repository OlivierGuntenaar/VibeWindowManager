//
//  UsageLimitsModels.swift
//  VibeWindowManager
//
//  Shared contract for the menu-bar usage/limits panel. `ClaudeUsageFetcher` and
//  `CodexUsageFetcher` (their own files) conform to `UsageFetching`; `UsageLimitsService`
//  owns the published results the panel renders.
//

import Combine
import Foundation

enum UsageProvider: String { case claude, codex }

/// One rate-limit window, e.g. "Session" (5h) or "Weekly".
struct UsageWindow: Identifiable, Equatable {
    var id: String { label }
    let label: String
    /// 0...100
    let usedPercent: Double
    let resetsAt: Date?
}

struct ProviderUsage: Equatable {
    let provider: UsageProvider
    let planName: String?
    let windows: [UsageWindow]
    let fetchedAt: Date
    let errorMessage: String?
}

protocol UsageFetching { func fetch() async -> ProviderUsage }

// MARK: - Service

@MainActor
final class UsageLimitsService: ObservableObject {

    static let shared = UsageLimitsService(fetchers: UsageLimitsService.defaultFetchers())

    /// ─── Fetcher wiring ──────────────────────────────────────────────────────────────────────
    /// The ONE spot that constructs the fetchers (ClaudeUsageFetcher.swift / CodexUsageFetcher.swift).
    /// Tests and previews pass their own map to `init(fetchers:)` instead.
    static func defaultFetchers() -> [UsageProvider: any UsageFetching] {
        [
            .claude: ClaudeUsageFetcher(),
            .codex: CodexUsageFetcher(),
        ]
    }

    @Published private(set) var claude: ProviderUsage?
    @Published private(set) var codex: ProviderUsage?
    @Published private(set) var isRefreshing = false
    /// When the last full refresh (both providers) finished.
    @Published private(set) var lastRefreshed: Date?

    private let fetchers: [UsageProvider: any UsageFetching]
    private var refreshTimer: Timer?

    init(fetchers: [UsageProvider: any UsageFetching]) {
        self.fetchers = fetchers
    }

    func usage(for provider: UsageProvider) -> ProviderUsage? {
        switch provider {
        case .claude: return claude
        case .codex: return codex
        }
    }

    /// Runs every fetcher concurrently; each provider's card updates as soon as its own fetch lands.
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let fetchers = self.fetchers
        Task { [weak self] in
            await withTaskGroup(of: ProviderUsage.self) { group in
                for fetcher in fetchers.values {
                    group.addTask { await fetcher.fetch() }
                }
                for await usage in group {
                    self?.store(usage)
                }
            }
            self?.isRefreshing = false
            self?.lastRefreshed = Date()
        }
    }

    /// Called when the menu-bar panel opens: refresh only if the data is older than `maxAge`.
    func refreshIfStale(maxAge: TimeInterval = 60) {
        guard let lastRefreshed, Date().timeIntervalSince(lastRefreshed) < maxAge else {
            refresh()
            return
        }
    }

    func startAutoRefresh(interval: TimeInterval = 5 * 60) {
        stopAutoRefresh()
        // Added to the main run loop below, so the block always fires on the main thread.
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // .common so the timer keeps firing while a menu is tracking.
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
        refresh()
    }

    func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// Previews / snapshots only: inject results without running fetchers.
    func setForPreview(claude: ProviderUsage?, codex: ProviderUsage?, lastRefreshed: Date?) {
        self.claude = claude
        self.codex = codex
        self.lastRefreshed = lastRefreshed
    }

    private func store(_ usage: ProviderUsage) {
        switch usage.provider {
        case .claude: claude = usage
        case .codex: codex = usage
        }
    }
}
