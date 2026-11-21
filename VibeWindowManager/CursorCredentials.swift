import Foundation

/// Cursor owns its encrypted desktop login. Borrow the CLI's readable session only
/// when its JWT belongs to the desktop account. Never decrypt or rewrite either app's store.
actor CursorCredentials {
    static let shared = CursorCredentials()
    private var pending: Task<String?, Never>?
    private var pendingID: UUID?

    func accessToken(allowInteraction: Bool = false) async -> String? {
        if let pending {
            let token = await pending.value
            if !allowInteraction { return token }
        }
        let id = UUID()
        let task = Task { await Self.load(allowInteraction: allowInteraction) }
        pendingID = id
        pending = task
        let token = await task.value
        if pendingID == id {
            pending = nil
            pendingID = nil
        }
        return token
    }

    @concurrent private static func load(allowInteraction: Bool) async -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
        guard let desktop = CursorUsageEngine.accessToken(databasePath: path), !desktop.isEmpty else { return nil }
        if !desktop.hasPrefix("cursor-safe-storage:") { return desktop }
        guard let account = CursorUsageEngine.databaseValue("cursorAuth/stripeMembershipAuthId", databasePath: path) else { return nil }
        let state = ClaudeKeychain.access(service: "cursor-access-token")
        guard canReadCLIKeychain(state, allowInteraction: allowInteraction,
            blocked: UserDefaults.standard.bool(forKey: "cursorUsage.keychainAccessBlocked")) else { return nil }
        // Automatic polling stays silent. Only the main window's Reconnect button may prompt.
        // Claude's paused-credential flag and credential item are never touched here.
        let result = await ClaudeKeychain.run(["find-generic-password", "-w", "-s", "cursor-access-token", "-a", "cursor-user"], timeout: allowInteraction ? nil : 10)
        guard result.status == 0, let data = result.data, let token = String(data: data, encoding: .utf8) else {
            UserDefaults.standard.set(true, forKey: "cursorUsage.keychainAccessBlocked")
            return nil
        }
        guard validCLIToken(token, account: account, now: Date()) else { return nil }
        UserDefaults.standard.removeObject(forKey: "cursorUsage.keychainAccessBlocked")
        return token
    }

    nonisolated static func canReadCLIKeychain(_ state: ClaudeKeychain.Access,
        allowInteraction: Bool, blocked: Bool) -> Bool {
        switch state {
        case .ready(let account): return account == "cursor-user" && (allowInteraction || !blocked)
        case .locked, .approvalRequired: return allowInteraction
        case .missing, .unavailable: return false
        }
    }

    nonisolated static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        let payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: payload + String(repeating: "=", count: (4 - payload.count % 4) % 4)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    nonisolated static func validCLIToken(_ token: String, account: String, now: Date) -> Bool {
        guard !account.isEmpty, let claims = claims(token), claims["sub"] as? String == account,
              let expiration = claims["exp"] as? Double, expiration.isFinite,
              expiration > now.timeIntervalSince1970 + 60 else { return false }
        return true
    }
}
