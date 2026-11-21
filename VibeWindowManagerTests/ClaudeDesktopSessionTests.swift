//
//  ClaudeDesktopSessionTests.swift
//  VibeWindowManagerTests
//
//  Fixture tokens only: no Keychain, no network, no real credentials.
//

import CommonCrypto
import Foundation
import Testing
@testable import VibeWindowManager

struct ClaudeDesktopSessionTests {
    static let password = Data("fixture-safe-storage-password".utf8)
    static let account = "acct-1111"
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Electron safeStorage on macOS, as the Claude app writes it.
    static func encrypt(_ plain: Data, password: Data = password) -> String {
        let key = ClaudeDesktopSession.derivedKey(password)!
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        let input = [UInt8](plain)
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                             key, key.count, iv, input, input.count, &output, output.count, &moved)
        precondition(status == kCCSuccess)
        return (Data("v10".utf8) + Data(output.prefix(moved))).base64EncodedString()
    }

    static func key(account: String = account, host: String = "api.anthropic.com", scopes: String) -> String {
        "acct:\(account)|client-a:org-b:https://\(host):\(scopes)"
    }

    static func entry(_ token: String, expiresIn days: Double?, type: String = "max",
                      tier: String = "default_claude_max_20x") -> [String: Any] {
        var value: [String: Any] = ["token": token, "refreshToken": "refresh-\(token)",
                                    "subscriptionType": type, "rateLimitTier": tier]
        if let days { value["expiresAt"] = (now.timeIntervalSince1970 + days * 86_400) * 1000 }
        return value
    }

    static func config(_ cache: [String: Any]?, account: String? = account,
                       password: Data = password) throws -> Data {
        var config: [String: Any] = ["locale": "en-US"]
        if let account { config["lastKnownAccountUuid"] = account }
        if let cache {
            config["oauth:tokenCacheV2"] = encrypt(try JSONSerialization.data(withJSONObject: cache), password: password)
        }
        return try JSONSerialization.data(withJSONObject: config)
    }

    static func lookup(config: Data?, passwords: [ClaudeKeychain.ReadResult] = [.found("Claude", password)],
                       forgotten: Counter = Counter()) async -> ClaudeDesktopSession.Lookup {
        let queue = Queue(passwords)
        return await ClaudeDesktopSession.lookup(
            readConfig: { config },
            readPassword: { _ in await queue.next() },
            forgetPassword: { await forgotten.increment() },
            now: { now })
    }

    actor Queue {
        var items: [ClaudeKeychain.ReadResult]
        init(_ items: [ClaudeKeychain.ReadResult]) { self.items = items }
        func next() -> ClaudeKeychain.ReadResult { items.count > 1 ? items.removeFirst() : items[0] }
    }

    actor Counter {
        var value = 0
        func increment() { value += 1 }
    }

    // MARK: Decryption

    @Test func decryptsElectronSafeStorageAndRejectsTheWrongKey() throws {
        let plain = Data(#"{"hello":"world"}"#.utf8)
        let blob = Self.encrypt(plain)
        #expect(ClaudeDesktopSession.decrypt(blob, password: Self.password) == plain)
        let wrong = ClaudeDesktopSession.decrypt(blob, password: Data("other".utf8))
        #expect(wrong.flatMap { try? JSONSerialization.jsonObject(with: $0) } == nil)
        let unversioned = String(blob.dropFirst(4))
        #expect(ClaudeDesktopSession.decrypt(unversioned, password: Self.password) == nil)
    }

    // MARK: Keys and selection

    @Test func cacheKeysYieldAccountAudienceAndScopes() throws {
        let parsed = try #require(ClaudeDesktopSession.parseKey(Self.key(scopes: "user:inference user:profile")))
        #expect(parsed.account == Self.account)
        #expect(parsed.audience == "https://api.anthropic.com")
        #expect(parsed.scopes == ["user:inference", "user:profile"])
        for bad in ["", "acct:", "acct:x", "acct:|c:o:https://api.anthropic.com:user:profile",
                    "acct:x|c:o:api.anthropic.com:user:profile", "acct:x|c:o:https://api.anthropic.com:",
                    "other:x|c:o:https://api.anthropic.com:user:profile"] {
            #expect(ClaudeDesktopSession.parseKey(bad) == nil, "\(bad)")
        }
    }

    @Test func onlyTheCurrentAccountsAnthropicProfileTokensAreUsable() {
        let cache: [String: Any] = [
            Self.key(scopes: "user:profile"): Self.entry("mine", expiresIn: 10),
            Self.key(account: "someone-else", scopes: "user:profile"): Self.entry("other-account", expiresIn: 10),
            Self.key(host: "claude.ai", scopes: "user:profile"): Self.entry("other-host", expiresIn: 10),
            Self.key(scopes: "user:inference"): Self.entry("no-profile", expiresIn: 10),
            Self.key(scopes: "user:profile user:mcp"): ["token": ""],
            "not-a-token": Self.entry("junk", expiresIn: 10),
        ]
        let tokens = ClaudeDesktopSession.usableTokens(in: cache, account: Self.account)
        #expect(tokens.map(\.accessToken) == ["mine"])
        #expect(tokens.first?.expiresAt == Self.now.addingTimeInterval(10 * 86_400))
    }

    @Test func narrowestLiveTokenWinsThenLongestLived() {
        func token(_ name: String, _ scopes: Set<String>, _ days: Double?) -> ClaudeDesktopSession.Token {
            .init(accessToken: name, expiresAt: days.map { Self.now.addingTimeInterval($0 * 86_400) },
                  scopes: scopes, subscriptionType: nil, rateLimitTier: nil)
        }
        let broad = token("broad", ["user:profile", "user:inference", "user:sessions:claude_code"], 200)
        let narrowShort = token("narrow-short", ["user:profile"], 2)
        let narrowLong = token("narrow-long", ["user:profile"], 20)
        let narrowExpired = token("narrow-expired", ["user:profile"], -1)
        guard case .found(let best) = ClaudeDesktopSession.choose([broad, narrowShort, narrowExpired, narrowLong], now: Self.now)
        else { Issue.record("No token chosen"); return }
        #expect(best.accessToken == "narrow-long")
        guard case .found(let fallback) = ClaudeDesktopSession.choose([broad, narrowExpired], now: Self.now)
        else { Issue.record("Live broad token ignored"); return }
        #expect(fallback.accessToken == "broad")
        let nearlyExpired = token("thirty-seconds", ["user:profile"], 30.0 / 86_400)
        guard case .expired = ClaudeDesktopSession.choose([narrowExpired, nearlyExpired], now: Self.now)
        else { Issue.record("Lapsed tokens reported as usable"); return }
        guard case .notSignedIn = ClaudeDesktopSession.choose([], now: Self.now)
        else { Issue.record("Empty cache not reported as signed out"); return }
    }

    // MARK: Lookup

    @Test func findsTheDesktopTokenWithItsPlan() async throws {
        let config = try Self.config([
            Self.key(scopes: "user:profile"): Self.entry("profile-only", expiresIn: 23),
            Self.key(scopes: "user:inference user:profile"): Self.entry("broader", expiresIn: 200),
        ])
        guard case .found(let token) = await Self.lookup(config: config) else { Issue.record("Token not found"); return }
        #expect(token.accessToken == "profile-only")
        #expect(ClaudeUsageFetcher.planName(subscriptionType: token.subscriptionType,
                                            rateLimitTier: token.rateLimitTier) == "Max 20x")
    }

    @Test func missingAppOrSignInIsReportedWithoutTouchingTheKeychain() async throws {
        let touched = Queue([.approvalRequired])
        for config in [nil, try Self.config(nil)] {
            let result = await ClaudeDesktopSession.lookup(readConfig: { config }, readPassword: { _ in
                Issue.record("Keychain read without a token cache"); return await touched.next()
            }, now: { Self.now })
            guard case .notSignedIn = result else { Issue.record("Expected not signed in"); continue }
        }
        guard case .unreadable = await Self.lookup(config: Data("{broken".utf8)) else {
            Issue.record("Corrupt settings not reported"); return
        }
    }

    @Test func keychainRefusalAsksForAccessInsteadOfClaimingSignedOut() async throws {
        let config = try Self.config([Self.key(scopes: "user:profile"): Self.entry("t", expiresIn: 5)])
        for refusal in [ClaudeKeychain.ReadResult.approvalRequired, .unavailable, .locked] {
            guard case .needsKeychainAccess = await Self.lookup(config: config, passwords: [refusal]) else {
                Issue.record("\(refusal) not reported as needing access"); continue
            }
        }
        guard case .unreadable = await Self.lookup(config: config, passwords: [.missing]) else {
            Issue.record("Missing storage key not reported"); return
        }
    }

    @Test func staleCachedPasswordIsForgottenAndReadOnceMore() async throws {
        let config = try Self.config([Self.key(scopes: "user:profile"): Self.entry("t", expiresIn: 5)])
        let forgotten = Counter()
        let recovered = await Self.lookup(config: config, passwords: [
            .found("Claude", Data("stale".utf8)), .found("Claude", Self.password)], forgotten: forgotten)
        guard case .found = recovered else { Issue.record("Did not recover from stale password"); return }
        #expect(await forgotten.value == 1)

        let neverRight = Counter()
        let failed = await Self.lookup(config: config, passwords: [.found("Claude", Data("wrong".utf8))], forgotten: neverRight)
        guard case .unreadable = failed else { Issue.record("Wrong key not reported"); return }
        #expect(await neverRight.value == 1)
    }

    // MARK: Fetch

    static func found(_ token: String = "fixture-token") -> ClaudeDesktopSession.Lookup {
        .found(.init(accessToken: token, expiresAt: now.addingTimeInterval(86_400), scopes: ["user:profile"],
                     subscriptionType: "max", rateLimitTier: "default_claude_max_20x"))
    }

    static func response(_ status: Int, _ body: String = "{}") -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: ClaudeUsageFetcher.usageURL, statusCode: status,
                                         httpVersion: nil, headerFields: nil)!)
    }

    @Test func usageIsReadWithTheDesktopToken() async {
        let snapshot = await ClaudeUsageFetcher.loadSnapshot(session: { Self.found() }, transport: { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
            #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
            return Self.response(200, #"{"five_hour":null,"seven_day":{"utilization":24,"resets_at":"2026-11-26T19:59:59.721261+00:00"}}"#)
        }, now: { Self.now })
        #expect(snapshot.errorMessage == nil)
        #expect(snapshot.planName == "Max 20x")
        #expect(snapshot.windows.map(\.label) == ["Weekly"])
        #expect(snapshot.windows.first?.usedPercent == 24)
    }

    @Test func refusedSignInIsReportedAndNeverRenewedHere() async {
        let calls = Counter()
        let snapshot = await ClaudeUsageFetcher.loadSnapshot(session: { Self.found() }, transport: { _ in
            await calls.increment(); return Self.response(401)
        })
        #expect(await calls.value == 1)
        #expect(snapshot.errorMessage?.contains("Open Claude") == true)
        #expect(!snapshot.isTransient)
        #expect(!snapshot.requiresKeychainAccess)
    }

    @Test func accessAndSignInProblemsNeverContactAnthropic() async {
        let lapsed = ClaudeDesktopSession.Token(accessToken: "old", expiresAt: Self.now.addingTimeInterval(-60),
            scopes: ["user:profile"], subscriptionType: "pro", rateLimitTier: nil)
        let cases: [ClaudeDesktopSession.Lookup] = [.needsKeychainAccess("allow"), .expired(lapsed),
                                                    .notSignedIn("sign in"), .unreadable("broken")]
        for lookup in cases {
            let snapshot = await ClaudeUsageFetcher.loadSnapshot(session: { lookup }, transport: { _ in
                Issue.record("Contacted Anthropic without a usable token"); throw URLError(.cancelled)
            })
            #expect(snapshot.errorMessage != nil)
            #expect(snapshot.windows.isEmpty)
            if case .needsKeychainAccess = lookup {
                #expect(snapshot.requiresKeychainAccess && snapshot.isTransient)
            } else {
                #expect(!snapshot.requiresKeychainAccess)
            }
            if case .expired = lookup { #expect(snapshot.planName == "Pro") }
        }
    }
}
