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
//  Credentials: Claude Code stores them in the login keychain as a generic password
//  (service "Claude Code-credentials", account = $USER), written and read with
//  /usr/bin/security. We read it the same way: `security` is already on the item's
//  access list, so no "allow access" prompt appears. A direct SecItemCopyMatching
//  call from this app would prompt, and prompt again whenever Claude Code rewrites
//  the item on token refresh. Fallback: ~/.claude/.credentials.json (same JSON).
//
//  We never refresh the token ourselves: refresh tokens rotate, and refreshing
//  without writing the new pair back would sign Claude Code out.
//  Token values are never logged.
//

import Foundation
import CoreFoundation

struct ClaudeUsageFetcher: UsageFetching {
    /// Results younger than this are served from memory. The usage endpoint
    /// rate-limits per token, so popover open/close must not hammer it.
    var minimumRefreshInterval: TimeInterval = 60

    private static var lastResult: ProviderUsage?

    func fetch() async -> ProviderUsage {
        if let cached = Self.lastResult,
           cached.errorMessage == nil,
           Date().timeIntervalSince(cached.fetchedAt) < minimumRefreshInterval {
            return cached
        }
        let snapshot = await Self.loadSnapshot()
        let usage = ProviderUsage(
            provider: .claude,
            planName: snapshot.planName,
            windows: snapshot.errorMessage == nil
                ? snapshot.windows.map { UsageWindow(label: $0.label, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt) }
                : [],
            fetchedAt: Date(),
            errorMessage: snapshot.errorMessage
        )
        Self.lastResult = usage
        return usage
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
    }

    nonisolated struct OAuthCredential: Sendable {
        let accessToken: String
        let expiresAt: Date?
        let subscriptionType: String?
        let rateLimitTier: String?

        var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSinceNow < 30
        }
    }

    nonisolated enum CredentialLookup: Sendable {
        case found(OAuthCredential)
        case expired(OAuthCredential)
        case missing(String)
    }

    nonisolated static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    nonisolated static let keychainService = "Claude Code-credentials"

    @concurrent
    nonisolated static func loadSnapshot() async -> Snapshot {
        var snapshot = Snapshot()

        let credential: OAuthCredential
        switch await lookUpCredential() {
        case .found(let c):
            credential = c
        case .expired(let c):
            snapshot.planName = planName(subscriptionType: c.subscriptionType, rateLimitTier: c.rateLimitTier)
                ?? planNameFromClaudeConfig()
            snapshot.errorMessage = "Claude token expired — open Claude Code to refresh it."
            return snapshot
        case .missing(let reason):
            snapshot.planName = planNameFromClaudeConfig()
            snapshot.errorMessage = reason
            return snapshot
        }

        snapshot.planName = planName(subscriptionType: credential.subscriptionType, rateLimitTier: credential.rateLimitTier)
            ?? planNameFromClaudeConfig()

        var request = URLRequest(url: usageURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("VibeWindowManager", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            snapshot.errorMessage = "Couldn't reach Anthropic: \(error.localizedDescription)"
            return snapshot
        }

        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200:
            break
        case 401:
            snapshot.errorMessage = "Claude token rejected (401) — open Claude Code to refresh it."
            return snapshot
        case 403:
            snapshot.errorMessage = "Usage not available for this login (403) — sign in to Claude Code with a Pro/Max account."
            return snapshot
        case 429:
            snapshot.errorMessage = "Usage endpoint rate-limited (429) — try again in a few minutes."
            return snapshot
        default:
            snapshot.errorMessage = "Usage request failed (HTTP \(status))."
            return snapshot
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            snapshot.errorMessage = "Unexpected usage response from Anthropic."
            return snapshot
        }
        snapshot.windows = parseWindows(json)
        if snapshot.windows.isEmpty {
            snapshot.errorMessage = "No usage limits reported for this account."
        }
        return snapshot
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

    nonisolated static func lookUpCredential() async -> CredentialLookup {
        var expired: OAuthCredential?
        var sawStore = false

        let keychainBlob = await readKeychainBlob()
        let fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        let fileBlob = try? Data(contentsOf: fileURL)

        for blob in [keychainBlob, fileBlob].compactMap({ $0 }) {
            sawStore = true
            guard let credential = parseCredential(blob) else { continue }
            if credential.isExpired {
                expired = expired ?? credential
            } else {
                return .found(credential)
            }
        }
        if let expired { return .expired(expired) }
        if sawStore {
            return .missing("No Claude Code login stored — run `claude` in a terminal and /login.")
        }
        return .missing("Claude Code credentials not found in Keychain — run `claude` and /login.")
    }

    nonisolated static func parseCredential(_ data: Data) -> OAuthCredential? {
        var data = data
        // Tolerate a hex-encoded value (some writers store `security -X <hex>`).
        if data.first != UInt8(ascii: "{"),
           let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let decoded = Data(hexString: text) {
            data = decoded
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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

    /// Runs `/usr/bin/security find-generic-password -a <user> -w -s "Claude Code-credentials"`,
    /// exactly as Claude Code does. Returns nil when the item is absent or unreadable.
    nonisolated static func readKeychainBlob() async -> Data? {
        var user = ProcessInfo.processInfo.environment["USER"] ?? NSUserName()
        if user.isEmpty || user.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) == nil {
            user = "claude-code-user"
        }
        if let data = await runSecurity(["find-generic-password", "-a", user, "-w", "-s", keychainService]) {
            return data
        }
        // Account name mismatch: fall back to matching on service only.
        return await runSecurity(["find-generic-password", "-w", "-s", keychainService])
    }

    nonisolated static func runSecurity(_ arguments: [String]) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
                process.arguments = arguments
                let stdout = Pipe()
                process.standardOutput = stdout
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                // Don't hang forever if the keychain is locked and waiting on a dialog.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 15) {
                    if process.isRunning { process.terminate() }
                }
                // Drain before waiting so a large item can't fill the pipe and deadlock.
                let output = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                var trimmed = output
                while let last = trimmed.last, last == 0x0A || last == 0x0D { trimmed.removeLast() }
                continuation.resume(returning: trimmed.isEmpty ? nil : trimmed)
            }
        }
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
