import Foundation
import Testing
@testable import VibeWindowManager

private actor OAuthStoreFixture {
    private var document: ClaudeOAuthStore.Document
    var writes = 0
    var allowWrite = true

    init(refreshToken: String? = "refresh-old") {
        var oauth: [String: Any] = ["accessToken": "access-old", "expiresAt": 1_700_000_000_000,
                                   "subscriptionType": "max", "rateLimitTier": "20x", "scopes": ["user:profile"]]
        oauth["refreshToken"] = refreshToken
        document = .init(origin: .file(URL(fileURLWithPath: "/fixture/credentials")),
                         data: try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth, "unrelated": ["keep": true]]))
    }
    func read() -> [ClaudeOAuthStore.Document] { [document] }
    func credential() -> ClaudeUsageFetcher.OAuthCredential { document.credential! }
    func setAllowWrite(_ allow: Bool) { allowWrite = allow }
    func replace(access: String, refresh: String, expires: Date) {
        var json = document.json!
        var oauth = document.oauth!
        oauth["accessToken"] = access; oauth["refreshToken"] = refresh
        oauth["expiresAt"] = expires.timeIntervalSince1970 * 1000
        json["claudeAiOauth"] = oauth
        document = .init(origin: document.origin, data: try! JSONSerialization.data(withJSONObject: json))
    }
    func write(_ old: ClaudeOAuthStore.Document, _ data: Data) -> Bool {
        writes += 1
        guard allowWrite, old.data == document.data else { return false }
        document = .init(origin: document.origin, data: data)
        return true
    }
}

private actor OAuthNetworkFixture {
    var calls = 0
    var requests: [URLRequest] = []
    var status = 200
    var body = Data(#"{"access_token":"access-new","refresh_token":"refresh-new","expires_in":28800,"scope":"user:profile"}"#.utf8)
    var headers: [String: String] = [:]
    var hold = false
    private var pending: CheckedContinuation<Void, Never>?

    func configure(status: Int = 200, body: Data? = nil, headers: [String: String] = [:], hold: Bool = false) {
        self.status = status; if let body { self.body = body }; self.headers = headers; self.hold = hold
    }
    func send(_ request: URLRequest) async -> (Data, URLResponse) {
        calls += 1; requests.append(request)
        if hold { await withCheckedContinuation { pending = $0 } }
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
    func release() { hold = false; pending?.resume(); pending = nil }
}

nonisolated private final class OAuthClockFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    var date: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}
nonisolated private struct OAuthLockFixture: ClaudeOAuthLocking {
    var isOwned: Bool { true }
    func release() {}
}

struct ClaudeOAuthSessionTests {
    private func makeSession(_ store: OAuthStoreFixture, _ network: OAuthNetworkFixture,
                             clock: OAuthClockFixture = OAuthClockFixture(), defaults: UserDefaults? = nil) -> ClaudeOAuthSession {
        ClaudeOAuthSession(read: { await store.read() }, write: { await store.write($0, $1) },
                           acquireLock: { OAuthLockFixture() }, transport: { await network.send($0) },
                           now: { clock.date }, defaults: defaults)
    }
    private func waitForRequest(_ network: OAuthNetworkFixture) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await network.calls == 0, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await network.calls == 1)
    }

    @Test func expiredLoginRenewsOnceAndPreservesUnrelatedCredentials() async throws {
        let store = OAuthStoreFixture(), network = OAuthNetworkFixture(), clock = OAuthClockFixture()
        let session = makeSession(store, network, clock: clock)
        let result = await session.renew(replacing: store.credential())
        guard case .ready(let fresh) = result else { Issue.record("Renewal failed"); return }
        #expect(fresh.accessToken == "access-new")
        #expect(fresh.expiresAt == clock.date.addingTimeInterval(28800))
        #expect(fresh.subscriptionType == "max")
        let document = await store.read()[0]
        #expect(document.oauth?["refreshToken"] as? String == "refresh-new")
        #expect((document.json?["unrelated"] as? [String: Bool])?["keep"] == true)
        #expect(await store.writes == 1)
        let requests = await network.requests
        #expect(requests.count == 1)
        #expect(requests[0].url == ClaudeOAuthSession.tokenURL)
        #expect(requests[0].httpMethod == "POST")
        let body = try #require(JSONSerialization.jsonObject(with: requests[0].httpBody!) as? [String: String])
        #expect(body["grant_type"] == "refresh_token")
        #expect(body["refresh_token"] == "refresh-old")
        #expect(body["scope"] == "user:profile")
        #expect(body["client_id"] == ClaudeOAuthSession.clientID)
    }

    @Test func concurrentRenewalRequestsShareOneExchange() async {
        let store = OAuthStoreFixture(), network = OAuthNetworkFixture()
        await network.configure(hold: true)
        let session = makeSession(store, network)
        let old = await store.credential()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 { group.addTask { _ = await session.renew(replacing: old) } }
            await waitForRequest(network)
            await network.release()
        }
        #expect(await network.calls == 1)
        #expect(await store.writes == 1)
    }

    @Test func callerCancellationStillPersistsRotatedCredentials() async {
        let store = OAuthStoreFixture(), network = OAuthNetworkFixture()
        await network.configure(hold: true)
        let session = makeSession(store, network)
        let old = await store.credential()
        let waiter = Task { await session.renew(replacing: old) }
        await waitForRequest(network)
        waiter.cancel()
        await network.release()
        _ = await waiter.value
        #expect(await store.credential().accessToken == "access-new")
        #expect(await store.writes == 1)
    }

    @Test func anotherProcessRefreshedBeforeLockSkipsExchange() async {
        let store = OAuthStoreFixture(), network = OAuthNetworkFixture(), clock = OAuthClockFixture()
        let old = await store.credential()
        await store.replace(access: "sibling", refresh: "sibling-refresh", expires: clock.date.addingTimeInterval(3600))
        let session = makeSession(store, network, clock: clock)
        guard case .ready(let credential) = await session.renew(replacing: old) else { Issue.record("No sibling token"); return }
        #expect(credential.accessToken == "sibling")
        #expect(await network.calls == 0)
    }

    @Test func concurrentSignInIsNeverOverwritten() async {
        let store = OAuthStoreFixture(), network = OAuthNetworkFixture(), clock = OAuthClockFixture()
        await network.configure(hold: true)
        let session = makeSession(store, network, clock: clock)
        let old = await store.credential()
        let waiter = Task { await session.renew(replacing: old) }
        await waitForRequest(network)
        await store.replace(access: "new-login", refresh: "new-login-refresh", expires: clock.date.addingTimeInterval(3600))
        await network.release()
        guard case .ready(let credential) = await waiter.value else { Issue.record("New login lost"); return }
        #expect(credential.accessToken == "new-login")
        #expect(await store.writes == 0)
    }

    @Test func saveFailureRetriesPersistenceWithoutRotatingAgain() async {
        let store = OAuthStoreFixture(), network = OAuthNetworkFixture(), clock = OAuthClockFixture()
        await store.setAllowWrite(false)
        let session = makeSession(store, network, clock: clock)
        let old = await store.credential()
        guard case .failed(let failure) = await session.renew(replacing: old) else { Issue.record("Unstored token accepted"); return }
        #expect(failure.isTransient)
        for _ in 0..<10 { _ = await session.renew(replacing: old) }
        #expect(await store.writes == 1)
        await store.setAllowWrite(true)
        clock.advance(300)
        guard case .ready = await session.renew(replacing: old) else { Issue.record("Save did not recover"); return }
        #expect(await network.calls == 1)
        #expect(await store.writes == 2)
    }

    @Test func rateLimitCooldownSurvivesRelaunchAndDoesNotStoreSecrets() async throws {
        let suite = "ClaudeOAuthSessionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OAuthStoreFixture(), network = OAuthNetworkFixture(), clock = OAuthClockFixture()
        await network.configure(status: 429, headers: ["Retry-After": "7200"])
        let old = await store.credential()
        let session = makeSession(store, network, clock: clock, defaults: defaults)
        guard case .failed(let failure) = await session.renew(replacing: old) else { Issue.record("429 accepted"); return }
        #expect(failure.httpStatus == 429)
        #expect(failure.retryAfter == clock.date.addingTimeInterval(7200))
        let restarted = makeSession(store, network, clock: clock, defaults: defaults)
        clock.advance(7199)
        _ = await restarted.renew(replacing: old)
        #expect(await network.calls == 1)
        clock.advance(1)
        _ = await restarted.renew(replacing: old)
        #expect(await network.calls == 2)
        #expect(await store.writes == 0)
        #expect(Set(defaults.persistentDomain(forName: suite)!.keys) ==
                Set([ClaudeOAuthSession.cooldownKey, ClaudeOAuthSession.failureCountKey]))
    }

    @Test func revokedRefreshTokenIsNotRetriedEvenAfterRelaunch() async throws {
        let suite = "ClaudeOAuthSessionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OAuthStoreFixture(), network = OAuthNetworkFixture()
        await network.configure(status: 400, body: Data(#"{"error":"invalid_grant","error_description":"never display token details"}"#.utf8))
        let old = await store.credential()
        let session = makeSession(store, network, defaults: defaults)
        _ = await session.renew(replacing: old)
        let restarted = makeSession(store, network, defaults: defaults)
        guard case .failed(let failure) = await restarted.renew(replacing: old) else { Issue.record("Revoked token accepted"); return }
        #expect(!failure.isTransient)
        #expect(failure.errorMessage?.contains("never display") == false)
        #expect(await network.calls == 1)
        #expect(defaults.string(forKey: ClaudeOAuthSession.rejectedTokenKey)?.count == 64)
    }

    @Test func missingRefreshTokenDoesNotContactServer() async {
        let store = OAuthStoreFixture(refreshToken: nil), network = OAuthNetworkFixture()
        let session = makeSession(store, network)
        guard case .failed = await session.renew(replacing: store.credential()) else { Issue.record("Missing refresh accepted"); return }
        #expect(await network.calls == 0)
    }

    @Test(arguments: [#"{}"#, #"{"access_token":"new","expires_in":0}"#,
                      #"{"access_token":"new","expires_in":true}"#, #"{"access_token":"new","expires_in":60,"refresh_token":""}"#])
    func malformedRenewalNeverOverwritesCredentials(body: String) async {
        let store = OAuthStoreFixture(), network = OAuthNetworkFixture()
        await network.configure(body: Data(body.utf8))
        let session = makeSession(store, network)
        guard case .failed = await session.renew(replacing: store.credential()) else { Issue.record("Malformed token accepted"); return }
        #expect(await store.writes == 0)
        #expect(await store.credential().accessToken == "access-old")
    }

    @Test func validAccessTokenMakesOnlyUsageRequest() async {
        let result = await ClaudeUsageFetcher.loadSnapshot(
            credentialLookup: { .found(.init(accessToken: "valid", expiresAt: nil, subscriptionType: "max", rateLimitTier: nil)) },
            transport: { request in
                #expect(request.url == ClaudeUsageFetcher.usageURL)
                return (Data(#"{"five_hour":{"utilization":12}}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }, configPlan: { nil }, renewCredential: { _ in Issue.record("Unexpected renewal"); return .failed(.init(errorMessage: "unexpected")) })
        #expect(result.windows.first?.usedPercent == 12)
    }

    @Test func expiryIsRenewedBeforeUsageIsRequested() async {
        let store = OAuthStoreFixture(), network = OAuthNetworkFixture(), clock = OAuthClockFixture()
        let session = makeSession(store, network, clock: clock)
        let old = await store.credential()
        let result = await ClaudeUsageFetcher.loadSnapshot(credentialLookup: { .expired(old) }, transport: { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-new")
            #expect(await store.writes == 1)
            return (Data(#"{"seven_day":{"utilization":20}}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, configPlan: { nil }, now: { clock.date }, renewCredential: { await session.renew(replacing: $0) })
        #expect(result.errorMessage == nil)
        #expect(result.windows.first?.usedPercent == 20)
        #expect(await network.calls == 1)
    }

    @Test func repeated401OnlyRenewsOnceAndBlocksFurtherRenewal() async {
        let store = OAuthStoreFixture(), network = OAuthNetworkFixture(), usage = OAuthNetworkFixture()
        await usage.configure(status: 401)
        let session = makeSession(store, network)
        let old = await store.credential()
        let result = await ClaudeUsageFetcher.loadSnapshot(credentialLookup: { .found(old) },
            transport: { await usage.send($0) }, configPlan: { nil },
            renewCredential: { await session.renew(replacing: $0) },
            rejectRenewedCredential: { await session.rejectRenewedCredential($0) })
        #expect(result.httpStatus == 401)
        #expect(await usage.calls == 2)
        #expect(await network.calls == 1)
        _ = await session.renew(replacing: store.credential())
        #expect(await network.calls == 1)
    }

    @Test func filesystemLocksExcludeOtherRefreshersAndReleaseBothPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("claude")
        let lock = try ClaudeOAuthFileLock.acquire(directory: directory)
        #expect(lock.isOwned)
        #expect(throws: ClaudeOAuthFileLock.Failure.self) { try ClaudeOAuthFileLock.acquire(directory: directory) }
        lock.release()
        let next = try ClaudeOAuthFileLock.acquire(directory: directory)
        #expect(next.isOwned)
        next.release()
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(".oauth_refresh.lock").path))
        #expect(!FileManager.default.fileExists(atPath: directory.path + ".lock"))
    }
}
