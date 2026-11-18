import CryptoKit
import Foundation

/// All three dashboard methods share a cooldown. Cached and in-flight requests are
/// scoped to the credential, so account switches cannot reuse another account's usage.
actor CursorDashboardClient {
    static let shared = CursorDashboardClient(defaults: .standard)
    static let cooldownKey = "cursorUsage.dashboardCooldown"
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private struct Entry {
        let result: Result<(Data, URLResponse), any Error>
        let expires: Date
    }
    private var cache: [String: Entry] = [:]
    private var pending: [String: Task<(Data, URLResponse), any Error>] = [:]
    private let transport: Transport
    private let now: @Sendable () -> Date
    private let defaults: UserDefaults?
    private var cooldown: Date?
    private var failures: Int

    init(defaults: UserDefaults? = nil, now: @escaping @Sendable () -> Date = Date.init,
         transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }) {
        self.defaults = defaults
        self.transport = transport
        self.now = now
        cooldown = defaults?.object(forKey: Self.cooldownKey) as? Date
        failures = min(5, max(0, defaults?.integer(forKey: Self.cooldownKey + ".failures") ?? 0))
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let identity = (request.value(forHTTPHeaderField: "Authorization") ?? "") + (request.url?.absoluteString ?? "")
        let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        if let entry = cache[key], entry.expires > now() { return try entry.result.get() }
        if let task = pending[key] { return try await task.value }
        if let cooldown, cooldown > now() {
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil,
                headerFields: ["Retry-After": String(Int(ceil(cooldown.timeIntervalSince(now()))))])!)
        }
        let task = Task { try await transport(request) }
        pending[key] = task
        let result = await task.result
        pending.removeValue(forKey: key)
        let date = now()
        cache = cache.filter { $0.value.expires > date }
        cache[key] = Entry(result: result, expires: date.addingTimeInterval(300))
        if case .success((_, let response)) = result, let http = response as? HTTPURLResponse,
           http.statusCode == 429 {
            failures = min(failures + 1, 5)
            let delay = min(3600, 900 * pow(2, Double(failures - 1)))
            let retry = ClaudeUsageFetcher.retryDate(http.value(forHTTPHeaderField: "Retry-After"), now: date)
            cooldown = max(cooldown ?? date, max(date.addingTimeInterval(delay), retry ?? date))
            defaults?.set(cooldown, forKey: Self.cooldownKey)
            defaults?.set(failures, forKey: Self.cooldownKey + ".failures")
        } else if case .success((_, let response)) = result,
                  (response as? HTTPURLResponse)?.statusCode == 200, (cooldown ?? .distantPast) <= date {
            failures = 0
            cooldown = nil
            defaults?.removeObject(forKey: Self.cooldownKey)
            defaults?.removeObject(forKey: Self.cooldownKey + ".failures")
        }
        return try result.get()
    }
}
