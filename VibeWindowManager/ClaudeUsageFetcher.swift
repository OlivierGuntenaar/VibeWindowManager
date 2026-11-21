//
//  ClaudeUsageFetcher.swift
//  VibeWindowManager
//
//  Fetches Claude subscription usage (5-hour session, weekly, per-model weekly
//  windows, extra usage), the same numbers the Claude app's usage page shows.
//
//    GET https://api.anthropic.com/api/oauth/usage
//    Authorization: Bearer <token>
//    anthropic-beta: oauth-2025-04-20
//  Response:
//    { five_hour | seven_day | seven_day_opus | seven_day_sonnet:
//          { utilization: Double? /* percent 0...100 */, resets_at: ISO-8601 String? },
//      extra_usage: { is_enabled, utilization, ... },
//      limits: [{ kind, group, percent, resets_at, scope: { model: { display_name } } }] }
//
//  The token comes from the Claude desktop app's own sign-in (ClaudeDesktopSession),
//  read-only: nothing here signs in, renews or writes credentials. The refresh coordinator
//  applies bounded, persistent cooldowns to errors and 429s. Token values are never logged.
//

import Foundation
import CoreFoundation

struct ClaudeUsageFetcher: UsageFetching {
    nonisolated static let maximumServerCooldown: TimeInterval = 7 * 24 * 60 * 60
    var minimumRefreshInterval: TimeInterval = 5 * 60

    func fetch() async -> ProviderUsage {
        await ClaudeRefreshCoordinator.shared.fetch(minimumRefreshInterval: minimumRefreshInterval)
    }
}

/// One policy across panels/services: errors must not cause a retry on every popover opening.
@MainActor
final class ClaudeRefreshCoordinator {
    static let shared = ClaudeRefreshCoordinator(
        loader: { await ClaudeUsageFetcher.loadSnapshot() }, defaults: .standard
    )
    static let cooldownKey = "claudeUsage.nextAllowedAt"
    static let rateLimitCountKey = "claudeUsage.rateLimitCount"

    private let loader: () async -> ClaudeUsageFetcher.Snapshot
    private let now: () -> Date
    private let defaults: UserDefaults?
    private var cached: ProviderUsage?
    private var lastGood: ProviderUsage?
    private(set) var nextAllowedAt: Date?
    private var rateLimitCount = 0
    private var inFlight: Task<ClaudeUsageFetcher.Snapshot, Never>?
    private var requestID: UUID?
    private var waiters: Set<UUID> = []
    var activeWaiterCount: Int { waiters.count }

    init(loader: @escaping () async -> ClaudeUsageFetcher.Snapshot,
         now: @escaping () -> Date = Date.init, defaults: UserDefaults? = nil) {
        self.loader = loader
        self.now = now
        self.defaults = defaults
        let currentDate = now()
        if let date = defaults?.object(forKey: Self.cooldownKey) as? Date,
           date.timeIntervalSince1970.isFinite,
           date.timeIntervalSince(currentDate) <= ClaudeUsageFetcher.maximumServerCooldown {
            nextAllowedAt = date > currentDate ? date : nil
            rateLimitCount = min(max(defaults?.integer(forKey: Self.rateLimitCountKey) ?? 0, 0), 5)
        }
    }

    func fetch(minimumRefreshInterval: TimeInterval = 300) async -> ProviderUsage {
        guard !Task.isCancelled else { return cancelledUsage() }
        if let nextAllowedAt, now() < nextAllowedAt {
            return cached ?? ProviderUsage(provider: .claude, planName: nil, windows: [], fetchedAt: now(),
                errorMessage: "Claude usage refresh is cooling down. Retrying automatically.")
        }
        let interval = minimumRefreshInterval.isFinite ? min(max(300, minimumRefreshInterval), 3600) : 300
        let task: Task<ClaudeUsageFetcher.Snapshot, Never>
        let id: UUID
        if let active = inFlight, let activeID = requestID {
            task = active
            id = activeID
        } else {
            id = UUID()
            let load = loader
            task = Task { await load() }
            inFlight = task
            requestID = id
        }
        let waiter = UUID()
        waiters.insert(waiter)
        let snapshot = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.removeCancelledWaiter(waiter, request: id) }
        }
        guard !Task.isCancelled else {
            removeCancelledWaiter(waiter, request: id)
            return cancelledUsage()
        }
        waiters.remove(waiter)
        // Only the first active waiter commits this response; obsolete requests cannot replace it.
        guard requestID == id else { return cached ?? cancelledUsage() }
        inFlight = nil
        requestID = nil
        waiters.removeAll()
        guard !snapshot.isCancelled else { return cancelledUsage() }

        let fetchedAt = now()
        let rateLimited = snapshot.httpStatus == 429
        if rateLimited { rateLimitCount = min(rateLimitCount + 1, 5) }
        else if snapshot.errorMessage == nil { rateLimitCount = 0 }
        let delay = rateLimited ? max(interval, min(300 * pow(2, Double(rateLimitCount - 1)), 3600)) : interval
        var retryAt = fetchedAt.addingTimeInterval(delay)
        if let serverDate = snapshot.retryAfter, serverDate.timeIntervalSince1970.isFinite, serverDate > retryAt {
            retryAt = min(serverDate, fetchedAt.addingTimeInterval(ClaudeUsageFetcher.maximumServerCooldown))
        }
        nextAllowedAt = retryAt
        defaults?.set(retryAt, forKey: Self.cooldownKey)
        defaults?.set(rateLimitCount, forKey: Self.rateLimitCountKey)

        let usage: ProviderUsage
        if let error = snapshot.errorMessage, snapshot.isTransient, let lastGood {
            usage = ProviderUsage(provider: .claude, planName: lastGood.planName, windows: lastGood.windows,
                                  fetchedAt: lastGood.fetchedAt,
                                  errorMessage: "Showing cached usage. " + error, requiresKeychainAccess: snapshot.requiresKeychainAccess)
        } else {
            usage = ProviderUsage(provider: .claude, planName: snapshot.planName,
                                  windows: snapshot.errorMessage == nil ? snapshot.windows.map {
                                      UsageWindow(label: $0.label, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt)
                                  } : [], fetchedAt: fetchedAt, errorMessage: snapshot.errorMessage,
                requiresKeychainAccess: snapshot.requiresKeychainAccess)
        }
        cached = usage
        if snapshot.errorMessage == nil { lastGood = usage }
        else if !snapshot.isTransient { lastGood = nil }
        return usage
    }

    func keychainAccessWasGranted() {
        // An access error made no usage request; retrying after explicit authorization is safe.
        guard cached?.requiresKeychainAccess == true else { return }
        cached = nil
        nextAllowedAt = nil
        defaults?.removeObject(forKey: Self.cooldownKey)
    }

    private func removeCancelledWaiter(_ waiter: UUID, request id: UUID) {
        guard requestID == id else { return }
        waiters.remove(waiter)
        if waiters.isEmpty {
            inFlight?.cancel()
            inFlight = nil
            requestID = nil
        }
    }

    private func cancelledUsage() -> ProviderUsage {
        cached ?? ProviderUsage(provider: .claude, planName: nil, windows: [], fetchedAt: now(),
                                errorMessage: "Claude usage refresh cancelled.")
    }
}

// MARK: - Off-main-actor worker

extension ClaudeUsageFetcher {
    nonisolated struct RawWindow: Sendable {
        let label: String
        let usedPercent: Double
        let resetsAt: Date?
    }

    nonisolated struct Snapshot: Sendable {
        var planName: String?
        var windows: [RawWindow] = []
        var errorMessage: String?
        var httpStatus: Int?
        var retryAfter: Date?
        var isTransient = false
        var isCancelled = false
        var requiresKeychainAccess = false
    }

    nonisolated static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    @concurrent
    nonisolated static func loadSnapshot(
        session: @escaping @Sendable () async -> ClaudeDesktopSession.Lookup = { await ClaudeDesktopSession.lookup() },
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) },
        now: @escaping @Sendable () -> Date = Date.init
    ) async -> Snapshot {
        var snapshot = Snapshot()
        guard !Task.isCancelled else { snapshot.isCancelled = true; return snapshot }

        let token: ClaudeDesktopSession.Token
        switch await session() {
        case .found(let found):
            token = found
        case .expired(let lapsed):
            snapshot.planName = planName(subscriptionType: lapsed.subscriptionType, rateLimitTier: lapsed.rateLimitTier)
            snapshot.errorMessage = "The Claude app's sign-in has lapsed. Open Claude once to renew it."
            return snapshot
        case .notSignedIn(let reason):
            snapshot.errorMessage = reason
            return snapshot
        case .needsKeychainAccess(let reason):
            snapshot.errorMessage = reason
            snapshot.requiresKeychainAccess = true
            snapshot.isTransient = true
            return snapshot
        case .unreadable(let reason):
            snapshot.errorMessage = reason
            snapshot.isTransient = true
            return snapshot
        }
        snapshot.planName = planName(subscriptionType: token.subscriptionType, rateLimitTier: token.rateLimitTier)

        guard !Task.isCancelled else { snapshot.isCancelled = true; return snapshot }
        var request = URLRequest(url: usageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("VibeWindowManager", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            snapshot.isCancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
            snapshot.isTransient = true
            snapshot.errorMessage = "Couldn't reach Anthropic: \(error.localizedDescription)"
            return snapshot
        }

        guard !Task.isCancelled else {
            snapshot.isCancelled = true
            return snapshot
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        snapshot.httpStatus = status
        snapshot.retryAfter = retryDate(http?.value(forHTTPHeaderField: "Retry-After"), now: now())
        switch status {
        case 200:
            break
        case 401:
            snapshot.errorMessage = "Anthropic refused the Claude app's sign-in. Open Claude once to renew it."
            return snapshot
        case 403:
            snapshot.errorMessage = "Usage isn't available for this Claude account (403). It needs a Pro or Max plan."
            return snapshot
        case 429:
            snapshot.isTransient = true
            snapshot.errorMessage = "Anthropic temporarily limited usage checks (429). Retrying automatically after the cooldown."
            return snapshot
        default:
            snapshot.isTransient = status == 0 || status >= 500
            snapshot.errorMessage = "Usage request failed (HTTP \(status))."
            return snapshot
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            snapshot.isTransient = true
            snapshot.errorMessage = "Unexpected usage response from Anthropic."
            return snapshot
        }
        snapshot.windows = parseWindows(json)
        if snapshot.windows.isEmpty {
            snapshot.errorMessage = "No usage limits reported for this account."
        }
        return snapshot
    }

    nonisolated static func retryDate(_ header: String?, now: Date) -> Date? {
        guard let raw = header?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        // RFC delay-seconds is a nonnegative decimal integer, not arbitrary floating-point syntax.
        if raw.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) {
            guard let seconds = Double(raw), seconds.isFinite else { return nil }
            return now.addingTimeInterval(min(seconds, maximumServerCooldown))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return min(date, now.addingTimeInterval(maximumServerCooldown))
    }

    // MARK: Parsing

    nonisolated static func parseWindows(_ json: [String: Any]) -> [RawWindow] {
        var windows: [RawWindow] = []
        var seen = Set<String>()

        func add(_ label: String, _ percent: Double?, _ resetsAt: Date?) {
            guard let percent, percent.isFinite, !seen.contains(label) else { return }
            seen.insert(label)
            windows.append(RawWindow(label: label, usedPercent: min(max(percent, 0), 100), resetsAt: resetsAt))
        }

        let named: [(key: String, label: String)] = [
            ("five_hour", "Session (5h)"),
            ("seven_day", "Weekly"),
            ("seven_day_opus", "Weekly · Opus"),
            ("seven_day_sonnet", "Weekly · Sonnet"),
        ]
        for (key, label) in named {
            guard let window = json[key] as? [String: Any] else { continue }
            add(label, number(window["utilization"]), date(window["resets_at"]))
        }

        // Newer accounts report per-model weekly windows only in `limits[]`
        // (Claude Code shows these as e.g. "Weekly · Fable").
        if let limits = json["limits"] as? [[String: Any]] {
            for limit in limits {
                let scope = limit["scope"] as? [String: Any]
                let model = (scope?["model"] as? [String: Any])?["display_name"] as? String
                guard let model, !model.isEmpty else { continue }
                let kind = "\(limit["kind"] as? String ?? "") \(limit["group"] as? String ?? "")".lowercased()
                let isWeekly = kind.contains("week") || kind.contains("seven_day") || kind.contains("7d")
                let isSession = kind.contains("five_hour") || kind.contains("session") || kind.contains("5h")
                let label = isSession ? "Session · \(model)" : (isWeekly || kind.trimmingCharacters(in: .whitespaces).isEmpty)
                    ? "Weekly · \(model)" : "\(model) (\(kind.trimmingCharacters(in: .whitespaces)))"
                add(label, number(limit["percent"]), date(limit["resets_at"]))
            }
        }

        if let extra = json["extra_usage"] as? [String: Any],
           (extra["is_enabled"] as? Bool) == true {
            add("Extra usage", number(extra["utilization"]), nil)
        }
        return windows
    }

    nonisolated static func number(_ value: Any?) -> Double? {
        let parsed: Double?
        switch value {
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID(): parsed = n.doubleValue
        case let s as String: parsed = Double(s)
        default: parsed = nil
        }
        guard let parsed, parsed.isFinite else { return nil }
        return parsed
    }

    /// Accepts ISO-8601 with any number of fractional digits (the API sends
    /// microseconds, which ISO8601DateFormatter rejects), or epoch seconds/ms.
    nonisolated static func date(_ value: Any?) -> Date? {
        if value is NSNumber, let v = number(value) {
            return Date(timeIntervalSince1970: v > 1e12 ? v / 1000 : v)
        }
        guard let raw = value as? String, !raw.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: raw) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: raw) { return d }
        // Strip the fractional part ("...:00.123456+00:00" -> "...:00+00:00").
        if let dot = raw.range(of: #"\.\d+"#, options: .regularExpression) {
            var trimmed = raw
            trimmed.removeSubrange(dot)
            return plain.date(from: trimmed)
        }
        return nil
    }

    // MARK: Plan name

    nonisolated static func planName(subscriptionType: String?, rateLimitTier: String?) -> String? {
        let type = (subscriptionType ?? "").lowercased()
        let tier = (rateLimitTier ?? "").lowercased()
        let base: String
        if type == "max" || type.contains("claude_max") || tier.contains("claude_max") {
            base = "Max"
        } else if type == "pro" || type.contains("claude_pro") || tier.contains("claude_pro") {
            base = "Pro"
        } else if type.contains("team") || tier.contains("team") {
            base = "Team"
        } else if type.contains("enterprise") || tier.contains("enterprise") {
            base = "Enterprise"
        } else if type.isEmpty {
            return nil
        } else {
            base = type.replacingOccurrences(of: "claude_", with: "").capitalized
        }
        if base == "Max" {
            if tier.contains("20x") { return "Max 20x" }
            if tier.contains("5x") { return "Max 5x" }
        }
        return base
    }


}
