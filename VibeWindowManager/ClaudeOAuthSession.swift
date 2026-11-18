import CryptoKit
import Darwin
import Foundation
import Security

/// Renews the existing subscription login directly, without launching Claude Code or a model request.
/// The token endpoint and shared lock paths match Claude Code 2.1.296. This is its OAuth integration,
/// not the separate, API-key-authenticated Console usage/cost API.
actor ClaudeOAuthSession {
    typealias Credential = ClaudeUsageFetcher.OAuthCredential
    typealias Snapshot = ClaudeUsageFetcher.Snapshot
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    enum Result: Sendable {
        case ready(Credential)
        case failed(Snapshot)
    }

    static let shared = ClaudeOAuthSession(defaults: .standard)
    static let rejectedTokenKey = "claudeUsage.rejectedRefreshTokenDigest"
    static let rejectedAccessKey = "claudeUsage.rejectedAccessTokenDigest"
    static let cooldownKey = "claudeUsage.auth.nextAllowedAt"
    static let failureCountKey = "claudeUsage.auth.failureCount"
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    private let read: @Sendable () async -> [ClaudeOAuthStore.Document]
    private let write: @Sendable (ClaudeOAuthStore.Document, Data) async -> Bool
    private let acquireLock: @Sendable () throws -> any ClaudeOAuthLocking
    private let transport: Transport
    private let now: @Sendable () -> Date
    private let defaults: UserDefaults?
    private var inFlight: Task<Result, Never>?
    private var rejectedDigest: String?
    private var rejectedAccessDigest: String?
    private var nextAllowedAt: Date?
    private var failureCount = 0
    private var lastFailure: Snapshot?
    private var pending: (document: ClaudeOAuthStore.Document, refreshToken: String, oauth: Data)?

    init(read: @escaping @Sendable () async -> [ClaudeOAuthStore.Document] = { await ClaudeOAuthStore.read() },
         write: @escaping @Sendable (ClaudeOAuthStore.Document, Data) async -> Bool = { await ClaudeOAuthStore.write($0, data: $1) },
         acquireLock: @escaping @Sendable () throws -> any ClaudeOAuthLocking = { try ClaudeOAuthFileLock.acquire() },
         transport: @escaping Transport = { try await URLSession.shared.data(for: $0) },
         now: @escaping @Sendable () -> Date = Date.init,
         defaults: UserDefaults? = nil) {
        self.read = read
        self.write = write
        self.acquireLock = acquireLock
        self.transport = transport
        self.now = now
        self.defaults = defaults
        rejectedDigest = defaults?.string(forKey: Self.rejectedTokenKey)
        rejectedAccessDigest = defaults?.string(forKey: Self.rejectedAccessKey)
        if let date = defaults?.object(forKey: Self.cooldownKey) as? Date,
           date > now(), date.timeIntervalSince(now()) <= ClaudeUsageFetcher.maximumServerCooldown {
            nextAllowedAt = date
            failureCount = min(max(defaults?.integer(forKey: Self.failureCountKey) ?? 0, 0), 5)
        }
    }

    func renew(replacing credential: Credential) async -> Result {
        guard Self.digest(credential.accessToken) != rejectedAccessDigest else { return reconnectFailure() }
        if let inFlight { return await inFlight.value }
        if let nextAllowedAt, now() < nextAllowedAt {
            return .failed(lastFailure ?? Snapshot(errorMessage: "Claude sign-in renewal is cooling down. Retrying automatically.",
                                                  retryAfter: nextAllowedAt, isTransient: true))
        }
        // An unstructured task must finish persisting a rotated token even if the UI's waiter cancels.
        let task = Task { await performRenewal(replacing: credential) }
        inFlight = task
        let result = await task.value
        inFlight = nil
        if case .failed(var snapshot) = result, snapshot.isTransient {
            failureCount = min(failureCount + 1, 5)
            let delay = min(300 * pow(2, Double(failureCount - 1)), 3600)
            let retry = max(now().addingTimeInterval(delay), snapshot.retryAfter ?? now())
            nextAllowedAt = min(retry, now().addingTimeInterval(ClaudeUsageFetcher.maximumServerCooldown))
            snapshot.retryAfter = nextAllowedAt
            lastFailure = snapshot
            defaults?.set(nextAllowedAt, forKey: Self.cooldownKey)
            defaults?.set(failureCount, forKey: Self.failureCountKey)
            return .failed(snapshot)
        }
        nextAllowedAt = nil
        failureCount = 0
        lastFailure = nil
        defaults?.removeObject(forKey: Self.cooldownKey)
        defaults?.removeObject(forKey: Self.failureCountKey)
        return result
    }

    func rejectRenewedCredential(_ credential: Credential) {
        rejectedAccessDigest = Self.digest(credential.accessToken)
        defaults?.set(rejectedAccessDigest, forKey: Self.rejectedAccessKey)
    }

    private static func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func performRenewal(replacing credential: Credential) async -> Result {
        let lock: any ClaudeOAuthLocking
        do { lock = try acquireLock() }
        catch { return failure("Claude sign-in is being refreshed elsewhere. Retrying automatically.", transient: true) }
        defer { lock.release() }

        if pending != nil { return await persistPending(lock: lock) }
        let documents = await read()
        guard let document = documents.first(where: { $0.credential?.accessToken == credential.accessToken }) else {
            // Claude Code may have won the race while this caller was waiting for the lock.
            if let fresh = documents.compactMap(\.credential).first(where: { !$0.isExpired(at: now()) }) {
                return .ready(fresh)
            }
            return failure("Claude sign-in changed or is unavailable. Reconnect Claude.")
        }
        guard let oauth = document.oauth,
              let refreshToken = oauth["refreshToken"] as? String, !refreshToken.isEmpty else {
            return failure("Claude sign-in cannot renew itself. Sign in once in Claude Code to reconnect.")
        }
        let digest = Self.digest(refreshToken)
        guard digest != rejectedDigest else { return reconnectFailure() }
        guard lock.isOwned else { return failure("Claude sign-in changed. Retrying automatically.", transient: true) }

        var body: [String: Any] = ["grant_type": "refresh_token", "refresh_token": refreshToken,
                                   "client_id": oauth["clientId"] as? String ?? Self.clientID]
        // Keep the granted scopes; do not request additional permissions during renewal.
        if let scopes = oauth["scopes"] as? [String], !scopes.isEmpty { body["scope"] = scopes.joined(separator: " ") }
        var request = URLRequest(url: Self.tokenURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("VibeWindowManager", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do { (data, response) = try await transport(request) }
        catch { return failure("Couldn't renew Claude sign-in. Retrying automatically.", transient: true) }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let retry = ClaudeUsageFetcher.retryDate(http?.value(forHTTPHeaderField: "Retry-After"), now: now())
        guard status == 200 else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let code = json?["error"] as? String ?? (json?["error"] as? [String: Any])?["type"] as? String
            if code == "invalid_grant" || status == 401 {
                rejectedDigest = digest
                // Persist only a one-way fingerprint, so relaunching never retries a revoked refresh token.
                defaults?.set(digest, forKey: Self.rejectedTokenKey)
                return reconnectFailure()
            }
            return .failed(Snapshot(errorMessage: status == 429
                ? "Anthropic limited sign-in renewal. Retrying after the cooldown."
                : "Claude sign-in renewal failed (HTTP \(status)). Retrying automatically.",
                httpStatus: status, retryAfter: retry, isTransient: true))
        }

        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = json["access_token"] as? String, !access.isEmpty,
              let lifetime = ClaudeUsageFetcher.number(json["expires_in"]), lifetime > 30, lifetime <= 366 * 86400,
              let rotated = (json["refresh_token"] ?? refreshToken) as? String, !rotated.isEmpty else {
            return failure("Anthropic returned an incomplete sign-in renewal. Retrying later.", transient: true)
        }
        var updated = oauth
        updated["accessToken"] = access
        updated["refreshToken"] = rotated
        updated["expiresAt"] = now().addingTimeInterval(lifetime).timeIntervalSince1970 * 1000
        if let scope = json["scope"] as? String { updated["scopes"] = scope.split(separator: " ").map(String.init) }
        updated.removeValue(forKey: "refreshTokenExpiresAt")
        if let refreshLifetime = ClaudeUsageFetcher.number(json["refresh_token_expires_in"]),
           refreshLifetime > 0, refreshLifetime <= 366 * 86400 {
            updated["refreshTokenExpiresAt"] = now().addingTimeInterval(refreshLifetime).timeIntervalSince1970 * 1000
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: updated) else {
            return failure("Couldn't save Claude sign-in renewal.", transient: true)
        }
        pending = (document, refreshToken, encoded)
        return await persistPending(lock: lock)
    }

    private func persistPending(lock: any ClaudeOAuthLocking) async -> Result {
        guard let pending else { return failure("Claude sign-in renewal is unavailable.", transient: true) }
        guard lock.isOwned else { return failure("Claude sign-in changed. Retrying automatically.", transient: true) }
        guard let current = await read().first(where: { $0.origin == pending.document.origin }),
              var json = current.json, let oauth = current.oauth else {
            self.pending = nil
            return failure("Claude was signed out during renewal. Reconnect Claude.")
        }
        guard oauth["refreshToken"] as? String == pending.refreshToken else {
            self.pending = nil
            if let fresh = current.credential, !fresh.isExpired(at: now()) { return .ready(fresh) }
            return failure("Claude sign-in changed during renewal. Reconnect Claude.")
        }
        json["claudeAiOauth"] = try? JSONSerialization.jsonObject(with: pending.oauth)
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: .sortedKeys),
              lock.isOwned, await write(current, data),
              let saved = ClaudeUsageFetcher.parseCredential(data) else {
            // Keep the rotated pair in memory and retry saving it, never refresh with its spent predecessor.
            return failure("Couldn't save renewed Claude sign-in. Retrying automatically.", transient: true)
        }
        self.pending = nil
        rejectedDigest = nil
        defaults?.removeObject(forKey: Self.rejectedTokenKey)
        return .ready(saved)
    }

    private func reconnectFailure() -> Result {
        failure("Claude sign-in was revoked or expired. Sign in once in Claude Code to reconnect.")
    }

    private func failure(_ message: String, transient: Bool = false) -> Result {
        .failed(Snapshot(errorMessage: message, isTransient: transient))
    }
}

nonisolated struct ClaudeOAuthStore {
    enum Origin: Equatable, Sendable { case keychain(String), file(URL) }
    struct Document: Sendable {
        let origin: Origin
        let data: Data
        var json: [String: Any]? { ClaudeUsageFetcher.credentialJSON(data) }
        var oauth: [String: Any]? { json?["claudeAiOauth"] as? [String: Any] }
        var credential: ClaudeUsageFetcher.OAuthCredential? { ClaudeUsageFetcher.parseCredential(data) }
    }

    @concurrent static func read() async -> [Document] {
        var documents: [Document] = []
        if case .found(let account, let data) = await ClaudeKeychain.read() {
            documents.append(Document(origin: .keychain(account), data: data))
        }
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file) { documents.append(Document(origin: .file(file), data: data)) }
        return documents
    }

    @concurrent static func write(_ previous: Document, data: Data) async -> Bool {
        // Check again immediately before saving so a new login or unrelated credential fields aren't overwritten.
        guard await read().contains(where: { $0.origin == previous.origin && $0.data == previous.data }) else { return false }
        switch previous.origin {
        case .keychain(let account):
            guard await ClaudeKeychain.update(account: account, service: ClaudeUsageFetcher.keychainService, data: data) else { return false }
        case .file(let file):
            let temporary = file.deletingLastPathComponent().appendingPathComponent(".vibe-credentials-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: temporary) }
            guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]),
                  rename(temporary.path, file.path) == 0 else { return false }
        }
        return await read().contains { $0.origin == previous.origin && $0.data == data }
    }


}

nonisolated protocol ClaudeOAuthLocking: Sendable {
    var isOwned: Bool { get }
    func release()
}

/// Interoperates with Claude Code's mkdir-based proper-lockfile locks, including its legacy path.
/// Only empty locks stale for over two minutes can be reclaimed; live locks are left alone.
nonisolated final class ClaudeOAuthFileLock: ClaudeOAuthLocking, @unchecked Sendable {
    enum Failure: Error { case busy }
    private let mutex = NSLock()
    private var owned: [(URL, UInt64)] = []
    private var heartbeat: DispatchSourceTimer?
    private var compromised = false

    static func acquire(directory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")) throws -> ClaudeOAuthFileLock {
        let lock = ClaudeOAuthFileLock()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let paths = [directory.appendingPathComponent(".oauth_refresh.lock"),
                         URL(fileURLWithPath: directory.resolvingSymlinksInPath().path + ".lock")]
            for path in paths {
                if mkdir(path.path, 0o700) != 0 {
                    guard errno == EEXIST,
                          let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
                          let modified = attrs[.modificationDate] as? Date,
                          Date().timeIntervalSince(modified) > 120,
                          rmdir(path.path) == 0, mkdir(path.path, 0o700) == 0 else { throw Failure.busy }
                }
                guard let inode = inode(path) else { throw Failure.busy }
                lock.owned.append((path, inode))
            }
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { [weak lock] in lock?.touch() }
            lock.heartbeat = timer
            timer.resume()
            return lock
        } catch { lock.release(); throw error }
    }

    private static func inode(_ path: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path.path)[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    var isOwned: Bool {
        mutex.withLock { !compromised && !owned.isEmpty && owned.allSatisfy { Self.inode($0.0) == $0.1 } }
    }

    private func touch() {
        mutex.withLock {
            for (path, inode) in owned {
                guard Self.inode(path) == inode else { compromised = true; return }
                do { try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path) }
                catch { compromised = true }
            }
        }
    }

    func release() {
        mutex.withLock {
            heartbeat?.cancel()
            heartbeat = nil
            for (path, inode) in owned.reversed() where Self.inode(path) == inode { _ = rmdir(path.path) }
            owned.removeAll()
        }
    }

    deinit { release() }
}
