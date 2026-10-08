import Foundation
import SQLite3
import Testing
@testable import VibeWindowManager

private actor FailureRequestGate {
    private var arrived = 0
    private var waiter: CheckedContinuation<Void, Never>?
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func block() async {
        arrived += 1
        if arrived == 2 { waiter?.resume(); waiter = nil }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitForBothRequests() async {
        if arrived >= 2 { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        for continuation in releaseWaiters { continuation.resume() }
        releaseWaiters.removeAll()
    }
}

struct ProviderFailureTests {
    @Test(arguments: [URLError.timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .cancelled])
    func transportFailuresNeverReturnPartialUsage(code: URLError.Code) async {
        let result = await CursorUsageEngine.fetch(tokenLookup: { "fake" }) { request in
            if request.url?.lastPathComponent == "GetCurrentPeriodUsage" { throw URLError(code) }
            return (Data(#"{"planInfo":{"planName":"Pro"}}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(result.error != nil)
        #expect(result.windows.isEmpty)
    }

    @Test func planTimeoutStillAllowsUsage() async {
        let result = await CursorUsageEngine.fetch(tokenLookup: { "fake" }) { request in
            if request.url?.lastPathComponent == "GetPlanInfo" { throw URLError(.timedOut) }
            return (Data(#"{"planUsage":{"autoPercentUsed":37}}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(result.error == nil)
        #expect(result.windows.map(\.percent) == [37])
    }

    @Test(arguments: [401, 403, 429, 500, 502, 503])
    func httpFailureCannotMasqueradeAsSuccess(status: Int) async {
        let result = await CursorUsageEngine.fetch(tokenLookup: { "fake" }) { request in
            (Data(#"{"planUsage":{"autoPercentUsed":37},"planInfo":{"planName":"Pro"}}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        #expect(result.error != nil)
        #expect(result.windows.isEmpty)
    }

    @Test func cancellationRejectsLateSuccessfulTransportResults() async {
        let gate = FailureRequestGate()
        let task = Task {
            await CursorUsageEngine.fetch(tokenLookup: { "fake" }) { request in
                await gate.block()
                // Simulates a callback transport which completes after cancellation.
                return (Data(#"{"planUsage":{"autoPercentUsed":37}}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        await gate.waitForBothRequests()
        task.cancel()
        await gate.release()
        let result = await task.value
        #expect(result.windows.isEmpty)
        #expect(result.error == "Cursor usage refresh was cancelled.")
    }

    @Test func alreadyCancelledFetchDoesNotReadCredentialsOrNetwork() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await CursorUsageEngine.fetch(tokenLookup: {
                Issue.record("Canceled fetch read credentials")
                return "fake"
            }) { _ in
                Issue.record("Canceled fetch contacted server")
                throw CancellationError()
            }
        }
        let result = await task.value
        #expect(result.windows.isEmpty)
        #expect(result.error == "Cursor usage refresh was cancelled.")
    }

    @Test func failureDoesNotPoisonSubsequentRefresh() async {
        let failed = await CursorUsageEngine.fetch(tokenLookup: { "fake" }) { _ in throw URLError(.timedOut) }
        #expect(failed.error != nil)
        let recovered = await CursorUsageEngine.fetch(tokenLookup: { "fake" }) { request in
            (Data(#"{"planUsage":{"apiPercentUsed":28}}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(recovered.error == nil)
        #expect(recovered.windows.map(\.percent) == [28])
    }

    @Test func simultaneousRefreshesKeepCredentialsAndResultsIsolated() async {
        await withTaskGroup(of: Void.self) { group in
            for index in 1...12 {
                group.addTask {
                    let result = await CursorUsageEngine.fetch(tokenLookup: { "fake-\(index)" }) { request in
                        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-\(index)")
                        await Task.yield()
                        return (Data("{\"planUsage\":{\"autoPercentUsed\":\(index)}}".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                    }
                    #expect(result.error == nil)
                    #expect(result.windows.map(\.percent) == [Double(index)])
                }
            }
        }
    }

    @Test func missingCredentialDatabaseSkipsNetworkAndStaysAbsent() async {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        let result = await CursorUsageEngine.fetch(tokenLookup: { CursorUsageEngine.accessToken(databasePath: path) }) { _ in
            Issue.record("Missing database triggered network")
            throw URLError(.badURL)
        }
        #expect(result.error != nil)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func lockedCredentialDatabaseFailsReadOnlyThenRecovers() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var database: OpaquePointer?
        #expect(sqlite3_open(url.path, &database) == SQLITE_OK)
        defer { sqlite3_close(database) }
        #expect(sqlite3_exec(database, "CREATE TABLE ItemTable (key TEXT, value TEXT); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', 'fake-locked-token');", nil, nil, nil) == SQLITE_OK)
        let original = try Data(contentsOf: url)
        #expect(sqlite3_exec(database, "BEGIN EXCLUSIVE;", nil, nil, nil) == SQLITE_OK)
        #expect(CursorUsageEngine.accessToken(databasePath: url.path) == nil)
        #expect(sqlite3_exec(database, "ROLLBACK;", nil, nil, nil) == SQLITE_OK)
        #expect(CursorUsageEngine.accessToken(databasePath: url.path) == "fake-locked-token")
        #expect(try Data(contentsOf: url) == original)
    }
}
