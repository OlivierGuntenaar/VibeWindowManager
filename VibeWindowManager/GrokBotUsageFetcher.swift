import CoreFoundation
import Foundation

struct GrokBotUsageFetcher: UsageFetching {
    func fetch() async -> ProviderUsage {
        let context = GrokBotUsageCache.load()
        guard let token = await CursorCredentials.shared.accessToken(),
              let account = context.account,
              CursorCredentials.claims(token)?["sub"] as? String == account,
              context.personalAccount else {
            return context.usage ?? Self.unavailable("Open Grok Bot’s usage panel to connect its meter.")
        }
        do {
            let json = try await CursorUsageEngine.request("GetSandUsageStatus", token: token,
                transport: { try await CursorDashboardClient.shared.data(for: $0) })
            return Self.parse(json)
        } catch {
            if let cached = context.usage { return cached }
            return Self.unavailable("Grok Bot usage is temporarily unavailable. Retrying automatically.")
        }
    }

    static func unavailable(_ message: String) -> ProviderUsage {
        ProviderUsage(provider: .grokBot, planName: nil, windows: [], fetchedAt: Date(), errorMessage: message)
    }

    static func parse(_ json: [String: Any], now: Date = Date()) -> ProviderUsage {
        let shared = json["isUnified"] as? Bool == true
        let plan = (shared ? json["cursorPlanName"] : json["grokPlanLabel"]) as? String
        guard json["usesPooledEnterpriseAllowance"] as? Bool != true,
              let percent = number(json["usagePercent"]) else {
            return ProviderUsage(provider: .grokBot, planName: plan, windows: [], fetchedAt: now,
                errorMessage: "No individual Grok Bot allowance reported.")
        }
        let reset = (json["nextResetTimestampUtc"] as? String).flatMap { text -> Date? in
            let format = ISO8601DateFormatter()
            format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = format.date(from: text) { return date }
            format.formatOptions = [.withInternetDateTime]
            return format.date(from: text)
        }
        return ProviderUsage(provider: .grokBot, planName: plan,
            windows: [UsageWindow(label: shared ? "Weekly · shared" : "Weekly", usedPercent: min(100, max(0, percent)), resetsAt: reset)],
            fetchedAt: now, errorMessage: nil)
    }

    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
}

/// A read-only fallback from Grok Bot's own usage snapshot, scoped to its selected account.
/// No access to sand-secrets or any conversation/transcript cache is needed.
enum GrokBotUsageCache {
    struct Context {
        var account: String?
        var personalAccount = false
        var usage: ProviderUsage?
    }

    static func load(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Grok Bot/sand-client-persistence"), now: Date = Date()) -> Context {
        func read(_ key: String) -> [String: Any]? {
            let url = root.appendingPathComponent(filename(key))
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 64 * 1024,
                  let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
        guard let slot = read("sand.client.slice.client-meta.account-slot"), slot["schemaVersion"] as? Int == 1,
              let account = slot["value"] as? String, !account.isEmpty else { return Context() }
        var context = Context(account: account)
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")
        guard let encoded = account.addingPercentEncoding(withAllowedCharacters: safe),
              let cache = read("sand.client.slice.account.\(encoded).weekly-usage.cache"), cache["schemaVersion"] as? Int == 2,
              let value = cache["value"] as? [String: Any], value["kind"] as? String == "present" else { return context }
        context.personalAccount = value["selectedTeamId"] is NSNull
        guard let reading = value["reading"] as? [String: Any], let usage = reading["usage"] as? [String: Any],
              let readAt = GrokBotUsageFetcher.number(reading["readAtMs"]),
              let expires = GrokBotUsageFetcher.number(value["expiresAtMs"]),
              readAt > 0, readAt <= now.timeIntervalSince1970 * 1000 + 60_000,
              expires > now.timeIntervalSince1970 * 1000, now.timeIntervalSince1970 - readAt / 1000 < 86_400,
              let percent = GrokBotUsageFetcher.number(usage["percentUsed"]) else { return context }
        let reset = GrokBotUsageFetcher.number(usage["nextResetMs"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0 / 1000) : nil }
        guard reset == nil || reset! > now else { return context }
        let unified = usage["unifiedPlanName"] as? String
        context.usage = ProviderUsage(provider: .grokBot, planName: unified ?? usage["grokPlanLabel"] as? String,
            windows: [UsageWindow(label: unified == nil ? "Weekly" : "Weekly · shared", usedPercent: min(100, max(0, percent)), resetsAt: reset)],
            fetchedAt: Date(timeIntervalSince1970: readAt / 1000), errorMessage: nil, sourceNote: "From Grok Bot")
        return context
    }

    static func filename(_ key: String) -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567".utf8)
        var buffer: UInt32 = 0, bits = 0
        var result = [UInt8]()
        for byte in key.utf8 {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 { bits -= 5; result.append(alphabet[Int((buffer >> bits) & 31)]) }
        }
        if bits > 0 { result.append(alphabet[Int((buffer << (5 - bits)) & 31)]) }
        return String(decoding: result, as: UTF8.self) + ".blob"
    }
}
