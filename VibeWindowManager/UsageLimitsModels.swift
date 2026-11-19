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

enum UsageProvider: String, CaseIterable { case claude, codex, cursor, grokBot }

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
    var requiresKeychainAccess = false
    var sourceNote: String? = nil

    /// Setup failures and empty responses belong in the main window, not the quick meter list.
    var hasUsableMeter: Bool {
        windows.contains { $0.usedPercent.isFinite }
    }
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
            .cursor: CursorUsageFetcher(),
            .grokBot: GrokBotUsageFetcher(),
        ]
    }

    @Published private(set) var claude: ProviderUsage?
    @Published private(set) var codex: ProviderUsage?
    @Published private(set) var cursor: ProviderUsage?
    @Published private(set) var grokBot: ProviderUsage?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isAuthorizingClaude = false
    @Published private(set) var isAuthorizingCursor = false
    /// When the last full refresh (all providers) finished.
    @Published private(set) var lastRefreshed: Date?

    private let fetchers: [UsageProvider: any UsageFetching]
    private var refreshTimer: Timer?
    private var refreshTask: Task<Void, Never>?
    private var refreshID: UUID?
    private let makeTimer: (TimeInterval, @escaping @Sendable (Timer) -> Void) -> Timer

    init(fetchers: [UsageProvider: any UsageFetching],
         makeTimer: @escaping (TimeInterval, @escaping @Sendable (Timer) -> Void) -> Timer = { interval, action in
             let timer = Timer(timeInterval: interval, repeats: true, block: action)
             RunLoop.main.add(timer, forMode: .common)
             return timer
         }) {
        self.fetchers = fetchers
        self.makeTimer = makeTimer
    }

    isolated deinit {
        refreshTimer?.invalidate()
        refreshTask?.cancel()
    }

    func usage(for provider: UsageProvider) -> ProviderUsage? {
        switch provider {
        case .claude: return claude
        case .codex: return codex
        case .cursor: return cursor
        case .grokBot: return grokBot
        }
    }

    var menuProviders: [UsageProvider] {
        UsageProvider.allCases.filter { usage(for: $0)?.hasUsableMeter == true }
    }

    func authorizeCursorKeychain() {
        guard !isAuthorizingCursor else { return }
        isAuthorizingCursor = true
        Task {
            let token = await CursorCredentials.shared.accessToken(allowInteraction: true)
            isAuthorizingCursor = false
            if token != nil {
                cancelRefresh()
                refresh()
            }
        }
    }

    /// Runs every fetcher concurrently; each provider's card updates as soon as its own fetch lands.
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let fetchers = self.fetchers
        let id = UUID()
        refreshID = id
        refreshTask = Task { [weak self] in
            await withTaskGroup(of: ProviderUsage.self) { group in
                for fetcher in fetchers.values {
                    group.addTask { await fetcher.fetch() }
                }
                for await usage in group {
                    guard !Task.isCancelled, self?.refreshID == id else { continue }
                    self?.store(usage)
                }
            }
            guard !Task.isCancelled, self?.refreshID == id else { return }
            self?.isRefreshing = false
            self?.lastRefreshed = Date()
            self?.refreshTask = nil
            self?.refreshID = nil
        }
    }

    /// Only an explicit user action may open macOS's Keychain authorization dialog.
    func authorizeClaudeKeychain() {
        guard !isAuthorizingClaude else { return }
        isAuthorizingClaude = true
        Task {
            let result = await ClaudeKeychain.read(allowInteraction: true)
            isAuthorizingClaude = false
            if case .found = result {
                ClaudeRefreshCoordinator.shared.keychainAccessWasGranted()
                refresh()
            }
        }
    }

    /// Cancels this refresh without letting late responses overwrite a subsequent refresh.
    func cancelRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshID = nil
        isRefreshing = false
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
        guard interval.isFinite, interval > 0 else { return }
        let timer = makeTimer(interval) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // Allow macOS to coalesce periodic wakeups instead of waking at an exact instant.
        timer.tolerance = min(interval * 0.1, 30)
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
        case .cursor: cursor = usage
        case .grokBot: grokBot = usage
        }
    }
}
