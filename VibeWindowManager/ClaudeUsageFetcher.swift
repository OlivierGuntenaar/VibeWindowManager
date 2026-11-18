//
//  ClaudeUsageFetcher.swift
//  VibeWindowManager
//
//  Fetches the Claude subscription usage that Claude Code's `/usage` shows
//  (5-hour session, weekly, per-model weekly windows, extra usage).
//
//  Data source (verified against Claude Code 2.1.289's bundled source):
//    GET https://api.anthropic.com/api/oauth/usage
//    Authorization: Bearer <claudeAiOauth.accessToken>
//    anthropic-beta: oauth-2025-04-20
//  Response:
//    { five_hour | seven_day | seven_day_opus | seven_day_sonnet | seven_day_oauth_apps:
//          { utilization: Double? /* percent 0...100 */, resets_at: ISO-8601 String? },
//      extra_usage: { is_enabled, monthly_limit, used_credits, utilization, currency },
//      limits: [{ kind, group, percent, resets_at, severity, is_active,
//                 scope: { model: { display_name }, surface: { display_name } } }] }
//
//  Credentials: Claude Code's login Keychain item, with a ~/.claude/.credentials.json fallback.
//  ClaudeKeychain checks access before background reads and uses the same Apple-signed
//  tool for reads and writes. Authorization happens only through the user's access button.
//
//  ClaudeOAuthSession renews expired tokens directly, under Claude Code's shared
//  refresh locks, and saves rotated credentials back to their original store.
//  Both usage requests and renewal failures have bounded, persistent cooldowns.
//  Token values are never logged.
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

    nonisolated struct OAuthCredential: Sendable {
        let accessToken: String
        let expiresAt: Date?
        let subscriptionType: String?
        let rateLimitTier: String?

        var isExpired: Bool {
            isExpired(at: Date())
        }

        func isExpired(at now: Date) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSince(now) < 30
        }
    }

    nonisolated enum CredentialLookup: Sendable {
        case found(OAuthCredential)
        case expired(OAuthCredential)
        case missing(String)
        case inaccessible(String)
    }

    nonisolated static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    nonisolated static let keychainService = "Claude Code-credentials"

    @concurrent
    nonisolated static func loadSnapshot(
        credentialLookup: @escaping @Sendable () async -> CredentialLookup = { await lookUpCredential() },
        transport: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) },
        configPlan: @escaping @Sendable () -> String? = { planNameFromClaudeConfig() },
        now: @escaping @Sendable () -> Date = Date.init,
        renewCredential: @escaping @Sendable (OAuthCredential) async -> ClaudeOAuthSession.Result = { await ClaudeOAuthSession.shared.renew(replacing: $0) },
        rejectRenewedCredential: @escaping @Sendable (OAuthCredential) async -> Void = { await ClaudeOAuthSession.shared.rejectRenewedCredential($0) }
    ) async -> Snapshot {
        var snapshot = Snapshot()
        guard !Task.isCancelled else { snapshot.isCancelled = true; return snapshot }

        var credential: OAuthCredential
        var renewed = false
        switch await credentialLookup() {
        case .found(let c):
            credential = c
        case .expired(let c):
            snapshot.planName = planName(subscriptionType: c.subscriptionType, rateLimitTier: c.rateLimitTier)
                ?? configPlan()
            switch await renewCredential(c) {
            case .ready(let fresh): credential = fresh; renewed = true
            case .failed(var failure): failure.planName = snapshot.planName; return failure
            }
        case .inaccessible(let reason):
            snapshot.planName = configPlan()
            snapshot.errorMessage = reason
            snapshot.requiresKeychainAccess = true
            snapshot.isTransient = true
            return snapshot
        case .missing(let reason):
            snapshot.planName = configPlan()
            snapshot.errorMessage = reason
            return snapshot
        }

        snapshot.planName = planName(subscriptionType: credential.subscriptionType, rateLimitTier: credential.rateLimitTier)
            ?? configPlan()

        guard !Task.isCancelled else { snapshot.isCancelled = true; return snapshot }
        var request = URLRequest(url: usageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("VibeWindowManager", forHTTPHeaderField: "User-Agent")

        var data: Data
        var response: URLResponse
        do {
            (data, response) = try await transport(request)
            if (response as? HTTPURLResponse)?.statusCode == 401, !renewed, !Task.isCancelled {
                switch await renewCredential(credential) {
                case .ready(let fresh):
                    credential = fresh
                    renewed = true
                    snapshot.planName = planName(subscriptionType: fresh.subscriptionType, rateLimitTier: fresh.rateLimitTier) ?? configPlan()
                    request.setValue("Bearer \(fresh.accessToken)", forHTTPHeaderField: "Authorization")
                    guard !Task.isCancelled else { snapshot.isCancelled = true; return snapshot }
                    (data, response) = try await transport(request)
                case .failed(var failure):
                    failure.planName = snapshot.planName
                    return failure
                }
            }
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
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        snapshot.httpStatus = status
        snapshot.retryAfter = retryDate((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"), now: now())
        switch status {
        case 200:
            break
        case 401:
            if renewed { await rejectRenewedCredential(credential) }
            snapshot.errorMessage = "Claude rejected the renewed sign-in. Sign in once in Claude Code to reconnect."
            return snapshot
        case 403:
            snapshot.errorMessage = "Usage not available for this login (403) — sign in to Claude Code with a Pro/Max account."
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

    /// Non-secret fallback: ~/.claude.json carries `oauthAccount.organizationType`
    /// (e.g. "claude_max") and `organizationRateLimitTier` (e.g. "default_claude_max_20x").
    nonisolated static func planNameFromClaudeConfig() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any] else { return nil }
        return planName(
            subscriptionType: account["organizationType"] as? String,
            rateLimitTier: (account["userRateLimitTier"] as? String) ?? (account["organizationRateLimitTier"] as? String)
        )
    }

    // MARK: Credentials

    nonisolated static func lookUpCredential(
        keychainRead: @escaping @Sendable () async -> ClaudeKeychain.ReadResult = { await ClaudeKeychain.read() },
        fileRead: @escaping @Sendable () -> Data? = {
            try? Data(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json"))
        }
    ) async -> CredentialLookup {
        let keychain = await keychainRead()
        let keychainBlob: Data?
        if case .found(_, let data) = keychain { keychainBlob = data } else { keychainBlob = nil }
        var expired: OAuthCredential?
        var sawStore = false
        for blob in [keychainBlob, fileRead()].compactMap({ $0 }) {
            sawStore = true
            guard let credential = parseCredential(blob) else { continue }
            if credential.isExpired { expired = expired ?? credential }
            else { return .found(credential) }
        }
        if let expired { return .expired(expired) }
        switch keychain {
        case .locked: return .inaccessible("Keychain is locked. Unlock it to read Claude usage.")
        case .approvalRequired: return .inaccessible("Allow Keychain access to read Claude usage.")
        case .unavailable: return .inaccessible("Claude credentials are temporarily inaccessible.")
        case .found, .missing: break
        }
        return .missing(sawStore ? "No Claude login saved. Sign in once in Claude Code."
            : "No Claude credentials found. Sign in once in Claude Code.")
    }

    nonisolated static func credentialJSON(_ data: Data) -> [String: Any]? {
        var data = data
        // Tolerate a hex-encoded value (some writers store `security -X <hex>`).
        if data.first != UInt8(ascii: "{"),
           let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let decoded = Data(hexString: text) {
            data = decoded
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    nonisolated static func parseCredential(_ data: Data) -> OAuthCredential? {
        guard let json = credentialJSON(data),
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String,
              !token.isEmpty else { return nil }
        var expiresAt: Date?
        if let ms = number(oauth["expiresAt"]), ms > 0 {
            expiresAt = Date(timeIntervalSince1970: ms > 1e12 ? ms / 1000 : ms)
        }
        return OAuthCredential(
            accessToken: token,
            expiresAt: expiresAt,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        )
    }


}

private extension Data {
    nonisolated init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2), !hexString.isEmpty else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
