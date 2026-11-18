import Foundation

/// Cursor owns its encrypted desktop login. Borrow the CLI's readable session only
/// when its JWT belongs to the desktop account. Never decrypt or rewrite either app's store.
actor CursorCredentials {
    static let shared = CursorCredentials()
    private var pending: Task<String?, Never>?

    func accessToken() async -> String? {
        if let pending { return await pending.value }
        let task = Task { await Self.load() }
        pending = task
        let token = await task.value
        pending = nil
        return token
    }

    @concurrent private static func load() async -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb").path
        guard let desktop = CursorUsageEngine.accessToken(databasePath: path), !desktop.isEmpty else { return nil }
        if !desktop.hasPrefix("cursor-safe-storage:") { return desktop }
        guard let account = CursorUsageEngine.databaseValue("cursorAuth/stripeMembershipAuthId", databasePath: path),
              !UserDefaults.standard.bool(forKey: "cursorUsage.keychainAccessBlocked"),
              case .ready("cursor-user") = ClaudeKeychain.access(service: "cursor-access-token") else { return nil }
        // Only run the Apple reader after confirming its existing ACL and partition trust.
        // Claude's paused-credential flag and credential item are never touched here.
        let result = await ClaudeKeychain.run(["find-generic-password", "-w", "-s", "cursor-access-token", "-a", "cursor-user"], timeout: 10)
        guard result.status == 0, let data = result.data, let token = String(data: data, encoding: .utf8) else {
            UserDefaults.standard.set(true, forKey: "cursorUsage.keychainAccessBlocked")
            return nil
        }
        return validCLIToken(token, account: account, now: Date()) ? token : nil
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
