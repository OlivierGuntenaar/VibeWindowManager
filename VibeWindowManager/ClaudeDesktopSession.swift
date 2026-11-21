//
//  ClaudeDesktopSession.swift
//  VibeWindowManager
//
//  The Claude usage card's only credential source: the Claude desktop app's own sign-in.
//  No Claude Code CLI login, no terminal, and nothing to sign in to here.
//
//  The desktop app keeps its OAuth tokens in
//  ~/Library/Application Support/Claude/config.json under "oauth:tokenCacheV2"
//  (older builds: "oauth:tokenCache"), encrypted with Electron safeStorage:
//    "v10" + AES-128-CBC, PKCS#7, IV = 16 spaces,
//    key = PBKDF2-HMAC-SHA1(password, "saltysalt", 1003 rounds, 16 bytes),
//  where the password is the login Keychain item "Claude Safe Storage".
//  That item is read through Apple's `security` tool (ClaudeKeychain), so one
//  "Always Allow" survives VibeWindowManager updates. Background reads never prompt.
//
//  Read-only by design: tokens are never renewed, revoked or written back. The desktop
//  app renews them itself (they live for weeks); renewing here could rotate its refresh
//  token and sign the desktop app out. Only tokens for api.anthropic.com, carrying
//  user:profile, belonging to the desktop app's current account are used, and the
//  narrowest-scoped one wins. Token values are never logged or persisted.
//

import CommonCrypto
import Foundation

nonisolated enum ClaudeDesktopSession {
    static let safeStorageService = "Claude Safe Storage"
    static let tokenCacheKeys = ["oauth:tokenCacheV2", "oauth:tokenCache"]
    static let audience = "https://api.anthropic.com"
    static let requiredScope = "user:profile"

    struct Token: Sendable, Equatable {
        let accessToken: String
        let expiresAt: Date?
        let scopes: Set<String>
        let subscriptionType: String?
        let rateLimitTier: String?

        /// A minute of margin so a request never leaves with a token about to lapse.
        func isExpired(at now: Date) -> Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSince(now) < 60
        }
    }

    enum Lookup: Sendable {
        case found(Token)
        /// Signed in, but every usable token has lapsed; the desktop app renews them when opened.
        case expired(Token)
        case notSignedIn(String)
        case needsKeychainAccess(String)
        case unreadable(String)
    }

    static var configURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude/config.json")
    }

    // MARK: Lookup

    @concurrent static func lookup(
        allowInteraction: Bool = false,
        readConfig: @escaping @Sendable () -> Data? = { try? Data(contentsOf: configURL) },
        readPassword: @escaping @Sendable (Bool) async -> ClaudeKeychain.ReadResult = {
            await SafeStoragePassword.shared.read(allowInteraction: $0)
        },
        forgetPassword: @escaping @Sendable () async -> Void = { await SafeStoragePassword.shared.forget() },
        now: @escaping @Sendable () -> Date = Date.init
    ) async -> Lookup {
        guard let data = readConfig() else {
            return .notSignedIn("Claude desktop app not found. Install it and sign in once.")
        }
        guard let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .unreadable("Couldn't read the Claude app's settings. Retrying automatically.")
        }
        let blobs = tokenCacheKeys.compactMap { config[$0] as? String }.filter { !$0.isEmpty }
        guard !blobs.isEmpty else { return .notSignedIn("Sign in to the Claude desktop app to show usage.") }
        let account = (config["lastKnownAccountUuid"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        // A cached password can go stale if Claude resets its storage key: re-read once.
        for attempt in 0..<2 {
            let password: Data
            switch await readPassword(allowInteraction) {
            case .found(_, let value): password = value
            case .missing:
                return .unreadable("The Claude app's storage key is missing. Open Claude and sign in again.")
            case .locked:
                return .needsKeychainAccess("Keychain is locked. Unlock it to read Claude usage.")
            case .approvalRequired, .unavailable:
                return .needsKeychainAccess("Allow access to the Claude app's sign-in to show usage.")
            }
            var decryptedAny = false
            var tokens: [Token] = []
            for blob in blobs {
                guard let plain = decrypt(blob, password: password),
                      let cache = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] else { continue }
                decryptedAny = true
                tokens += usableTokens(in: cache, account: account)
            }
            if decryptedAny { return choose(tokens, now: now()) }
            if attempt == 0 { await forgetPassword() }
        }
        return .unreadable("Couldn't decrypt the Claude app's sign-in. Open Claude, then try again.")
    }

    // MARK: Token selection

    /// Keys look like `acct:<account>|<client>:<org>:https://api.anthropic.com:<scope> <scope>…`.
    static func parseKey(_ key: String) -> (account: String, audience: String, scopes: Set<String>)? {
        guard key.hasPrefix("acct:"), let bar = key.firstIndex(of: "|"),
              let scheme = key.range(of: ":https://", range: bar..<key.endIndex) else { return nil }
        let account = String(key[key.index(key.startIndex, offsetBy: 5)..<bar])
        let rest = key[scheme.upperBound...]
        guard !account.isEmpty, let colon = rest.firstIndex(of: ":") else { return nil }
        let host = rest[..<colon]
        let scopes = Set(rest[rest.index(after: colon)...].split(separator: " ").map(String.init))
        guard !host.isEmpty, !scopes.isEmpty else { return nil }
        return (account, "https://" + host, scopes)
    }

    static func usableTokens(in cache: [String: Any], account: String?) -> [Token] {
        cache.compactMap { key, value -> Token? in
            guard let entry = value as? [String: Any],
                  let token = entry["token"] as? String, !token.isEmpty,
                  let parsed = parseKey(key), parsed.audience == audience,
                  parsed.scopes.contains(requiredScope),
                  account == nil || parsed.account == account else { return nil }
            var expiresAt: Date?
            if let ms = ClaudeUsageFetcher.number(entry["expiresAt"]), ms > 0 {
                expiresAt = Date(timeIntervalSince1970: ms > 1e12 ? ms / 1000 : ms)
            }
            return Token(accessToken: token, expiresAt: expiresAt, scopes: parsed.scopes,
                         subscriptionType: entry["subscriptionType"] as? String,
                         rateLimitTier: entry["rateLimitTier"] as? String)
        }
    }

    /// Least privilege first (fewest scopes), then the longest-lived.
    static func choose(_ tokens: [Token], now: Date) -> Lookup {
        func ranked(_ a: Token, _ b: Token) -> Bool {
            if a.scopes.count != b.scopes.count { return a.scopes.count < b.scopes.count }
            return (a.expiresAt ?? .distantFuture) > (b.expiresAt ?? .distantFuture)
        }
        if let best = tokens.filter({ !$0.isExpired(at: now) }).sorted(by: ranked).first { return .found(best) }
        if let latest = tokens.max(by: { ($0.expiresAt ?? .distantPast) < ($1.expiresAt ?? .distantPast) }) {
            return .expired(latest)
        }
        return .notSignedIn("Sign in to the Claude desktop app to show usage.")
    }

    // MARK: Electron safeStorage

    static func decrypt(_ base64: String, password: Data) -> Data? {
        guard !password.isEmpty, let raw = Data(base64Encoded: base64), raw.count > 3,
              raw.prefix(3) == Data("v10".utf8) else { return nil }
        let body = [UInt8](raw.dropFirst(3))
        guard !body.isEmpty, body.count.isMultiple(of: kCCBlockSizeAES128),
              let key = derivedKey(password) else { return nil }
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: body.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, body, body.count, &output, output.count, &moved)
        guard status == kCCSuccess else { return nil }
        return Data(output.prefix(moved))
    }

    static func derivedKey(_ password: Data) -> [UInt8]? {
        let salt = [UInt8]("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let status = password.withUnsafeBytes { raw in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), raw.bindMemory(to: CChar.self).baseAddress, raw.count,
                                 salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                 &key, key.count)
        }
        return status == kCCSuccess ? key : nil
    }
}

/// Keeps the storage password in memory only, so a refresh every few minutes doesn't launch
/// `security` each time. Never written to disk or defaults.
actor SafeStoragePassword {
    static let shared = SafeStoragePassword()
    private var cached: Data?

    func read(allowInteraction: Bool) async -> ClaudeKeychain.ReadResult {
        if let cached, !allowInteraction { return .found("Claude", cached) }
        let result = await ClaudeKeychain.read(allowInteraction: allowInteraction,
                                               service: ClaudeDesktopSession.safeStorageService)
        if case .found(_, let password) = result { cached = password } else { cached = nil }
        return result
    }

    func forget() { cached = nil }
}
