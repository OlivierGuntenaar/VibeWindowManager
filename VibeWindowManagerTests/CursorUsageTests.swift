import Foundation
import SQLite3
import Testing
@testable import VibeWindowManager

struct CursorUsageTests {
    @Test func separatePoolsOverrideLegacyAllowance() {
        let result = CursorUsageEngine.parse([
            "billingCycleEnd": "1791894570000",
            "planUsage": ["includedSpend": 2000, "limit": 2000,
                          "autoPercentUsed": 8.37, "apiPercentUsed": 21.15]
        ], info: ["planInfo": ["planName": "Pro"]])
        #expect(result.planName == "Pro")
        #expect(result.windows.map(\.label) == ["Auto", "API"])
        #expect(result.windows.map(\.percent) == [8.37, 21.15])
        #expect(result.windows.first?.reset == Date(timeIntervalSince1970: 1791894570))
    }

    @Test func emptyAndUnlimitedAreNotInventedZeroLimits() {
        #expect(CursorUsageEngine.parse([:]).windows.isEmpty)
        let result = CursorUsageEngine.parse(["spendLimitUsage": ["individualUsed": 42]])
        #expect(result.windows.isEmpty)
        #expect(result.error != nil)
    }

    @Test func legacyZeroUsageAndWeeklyReset() {
        let result = CursorUsageEngine.parse(["planUsage": ["limit": 2000]], info: [
            "planInfo": ["includedUsagePeriod": "INCLUDED_USAGE_PERIOD_WEEKLY",
                         "includedUsageResetsAt": "1791894500000"]
        ])
        #expect(result.windows.first?.label == "Weekly")
        #expect(result.windows.first?.percent == 0)
        #expect(result.windows.first?.reset == Date(timeIntervalSince1970: 1791894500))
    }

    @Test func invalidPercentAndOverage() {
        let result = CursorUsageEngine.parse([
            "planUsage": ["autoPercentUsed": "NaN", "apiPercentUsed": 130],
            "spendLimitUsage": ["individualLimit": 100, "individualUsed": 25]
        ])
        #expect(result.windows.map(\.label) == ["API", "On-demand"])
        #expect(result.windows.map(\.percent) == [100, 25])
    }

    @Test func credentialLookupIsReadOnlyAndScoped() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT, value TEXT); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', 'test-token'), ('unrelated', 'ignored');", nil, nil, nil) == SQLITE_OK)
        #expect(CursorUsageEngine.accessToken(databasePath: path) == "test-token")
        #expect(CursorUsageEngine.accessToken(databasePath: path + "-missing") == nil)
        #expect(!FileManager.default.fileExists(atPath: path + "-missing"))
    }
    @Test(arguments: ["NaN", "Infinity", "-Infinity", "", "not-a-number"])
    func invalidNumericStringsDoNotInventUsage(value: String) {
        let result = CursorUsageEngine.parse(["planUsage": ["autoPercentUsed": value]])
        #expect(result.windows.isEmpty)
        #expect(result.error != nil)
    }

    @Test func booleanPercentIsRejected() throws {
        let json = try #require(JSONSerialization.jsonObject(with: Data(
            #"{"planUsage":{"autoPercentUsed":true,"apiPercentUsed":false}}"#.utf8
        )) as? [String: Any])
        #expect(CursorUsageEngine.parse(json).windows.isEmpty)
    }

    @Test func numericStringsAndZeroRemainValid() {
        let result = CursorUsageEngine.parse(["planUsage": ["autoPercentUsed": "0", "apiPercentUsed": "42.5"]])
        #expect(result.windows.map(\.percent) == [0, 42.5])
        #expect(result.error == nil)
    }

    @Test(arguments: [-100.0, -0.01, 0, 100, 100.01, 1000])
    func percentBounds(value: Double) {
        let result = CursorUsageEngine.parse(["planUsage": ["autoPercentUsed": value]])
        #expect(result.windows.first?.percent == min(100, max(0, value)))
    }

    @Test func oneValidPoolSuppressesLegacyTotal() {
        let result = CursorUsageEngine.parse(["planUsage": ["apiPercentUsed": 17, "totalPercentUsed": 85]])
        #expect(result.windows.map(\.label) == ["API"])
        #expect(result.windows.map(\.percent) == [17])
    }

    @Test func malformedPoolsFallBackToLegacyTotal() {
        let result = CursorUsageEngine.parse(["planUsage": ["autoPercentUsed": NSNull(), "apiPercentUsed": [], "totalPercentUsed": "35", "limit": 100, "includedSpend": 80]])
        #expect(result.windows.map(\.label) == ["Plan"])
        #expect(result.windows.map(\.percent) == [35])
    }

    @Test func invalidTotalFallsBackToSpend() {
        let result = CursorUsageEngine.parse(["planUsage": ["totalPercentUsed": "bad", "limit": "200", "includedSpend": "50"]])
        #expect(result.windows.map(\.percent) == [25])
    }

    @Test(arguments: [0.0, -1, -100])
    func nonpositiveAllowancesDoNotProduceWindows(limit: Double) {
        let result = CursorUsageEngine.parse(["planUsage": ["limit": limit], "spendLimitUsage": ["individualLimit": limit]])
        #expect(result.windows.isEmpty)
    }

    @Test func malformedSpendingIsNotReportedAsZero() {
        for malformed in ["invalid", NSNull(), true, [1], Double.infinity] as [Any] {
            let result = CursorUsageEngine.parse(["planUsage": ["limit": 100, "includedSpend": malformed], "spendLimitUsage": ["individualLimit": 100, "individualUsed": malformed]])
            #expect(result.windows.isEmpty)
            #expect(result.error != nil)
        }
    }

    @Test func omittedOnDemandSpendMeansZero() {
        let result = CursorUsageEngine.parse(["spendLimitUsage": ["individualLimit": 100]])
        #expect(result.windows.map(\.label) == ["On-demand"])
        #expect(result.windows.map(\.percent) == [0])
        #expect(result.error == nil)
    }

    @Test func planAndOnDemandHaveIndependentResetDates() {
        let result = CursorUsageEngine.parse(["billingCycleEnd": "2000000000000", "planUsage": ["autoPercentUsed": 10], "spendLimitUsage": ["individualLimit": 100, "individualUsed": 150]], info: ["planInfo": ["includedUsageResetsAt": "1900000000000"]])
        #expect(result.windows.map(\.reset) == [Date(timeIntervalSince1970: 1900000000), Date(timeIntervalSince1970: 2000000000)])
        #expect(result.windows.map(\.percent) == [10, 100])
    }

    @Test func invalidPlanResetFallsBackToBillingDate() {
        let result = CursorUsageEngine.parse(["billingCycleEnd": 2000000000000, "planUsage": ["totalPercentUsed": 1]], info: ["planInfo": ["includedUsageResetsAt": "NaN"]])
        #expect(result.windows.first?.reset == Date(timeIntervalSince1970: 2000000000))
    }

    @Test func invalidDatesNeverHideValidUsage() {
        for invalid in [0, -1, true, "NaN", NSNull(), []] as [Any] {
            let result = CursorUsageEngine.parse(["billingCycleEnd": invalid, "planUsage": ["totalPercentUsed": 1]], info: ["planInfo": ["includedUsageResetsAt": invalid]])
            #expect(result.windows.count == 1)
            #expect(result.windows.first?.reset == nil)
            #expect(result.error == nil)
        }
    }

    @Test func malformedContainersAndPlanNameAreIgnored() {
        let result = CursorUsageEngine.parse(["planUsage": "invalid", "spendLimitUsage": [1, 2]], info: ["planInfo": ["planName": 12]])
        #expect(result.planName == nil)
        #expect(result.windows.isEmpty)
        #expect(result.error != nil)
    }

    @Test func usageSurvivesMissingPlanInfo() {
        let result = CursorUsageEngine.parse(["planUsage": ["autoPercentUsed": 25]], info: ["planInfo": NSNull()])
        #expect(result.windows.map(\.percent) == [25])
        #expect(result.planName == nil)
        #expect(result.error == nil)
    }

    @Test(arguments: [
        "CREATE TABLE OtherTable (value TEXT);",
        "CREATE TABLE ItemTable (key TEXT, value TEXT);",
        "CREATE TABLE ItemTable (key TEXT, value TEXT); INSERT INTO ItemTable VALUES ('unrelated', 'secret');",
        "CREATE TABLE ItemTable (key TEXT, value TEXT); INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', NULL);"
    ])
    func unavailableCredentialReturnsNil(schema: String) throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var db: OpaquePointer?
        #expect(sqlite3_open(path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        #expect(sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK)
        #expect(CursorUsageEngine.accessToken(databasePath: path) == nil)
    }

    @Test func corruptCredentialDatabaseReturnsNilWithoutChangingFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let contents = Data("not a sqlite database".utf8)
        try contents.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(CursorUsageEngine.accessToken(databasePath: url.path) == nil)
        #expect(try Data(contentsOf: url) == contents)
    }

    @Test(arguments: [401, 403, 429, 500])
    func httpFailuresProvideActionableErrors(status: Int) async {
        let result = await CursorUsageEngine.fetch(tokenLookup: { "test-token" }) { request in
            (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
        }
        let expected: String
        switch status {
        case 401, 403: expected = "Cursor rejected the usage login. Reconnect Cursor Agent."
        case 429: expected = "Cursor usage is rate-limited — try again in a few minutes."
        default: expected = "Cursor usage request failed (HTTP \(status))."
        }
        #expect(result.error == expected)
        #expect(result.windows.isEmpty)
    }

    @Test func networkFailureIsReportedWithoutCredentialLeak() async {
        let result = await CursorUsageEngine.fetch(tokenLookup: { "test-sensitive-token" }) { _ in
            throw URLError(.notConnectedToInternet)
        }
        #expect(result.error == "Couldn't load Cursor usage. Open Cursor and try refreshing.")
        #expect(result.windows.isEmpty)
        #expect(result.error?.contains("test-sensitive-token") == false)
    }

    @Test(arguments: ["not json", "[]", "null", "42", ""])
    func invalidResponseBodiesAreReported(body: String) async {
        let result = await CursorUsageEngine.fetch(tokenLookup: { "test-token" }) { request in
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(result.error == "Couldn't load Cursor usage. Open Cursor and try refreshing.")
        #expect(result.windows.isEmpty)
    }

    @Test func nonHTTPResponseIsNotTreatedAsSuccess() async {
        let result = await CursorUsageEngine.fetch(tokenLookup: { "test-token" }) { request in
            (Data(#"{"planUsage":{"autoPercentUsed":15}}"#.utf8), URLResponse(url: request.url!, mimeType: "application/json", expectedContentLength: -1, textEncodingName: nil))
        }
        #expect(result.windows.isEmpty)
        #expect(result.error == "Cursor usage request failed (HTTP 0).")
    }

    @Test(arguments: [false, true])
    func absentOrEmptyTokenDoesNotContactServer(empty: Bool) async {
        let result = await CursorUsageEngine.fetch(tokenLookup: { empty ? "" : nil }) { _ in
            Issue.record("A missing credential must not trigger a network request")
            throw URLError(.badURL)
        }
        #expect(result.error == "Cursor usage needs a readable login. Open Cursor Agent and sign in.")
        #expect(result.windows.isEmpty)
    }

    @Test(arguments: [401, 429, 500])
    func planInfoFailureDoesNotHideUsage(status: Int) async {
        let result = await CursorUsageEngine.fetch(tokenLookup: { "test-token" }) { request in
            let isUsage = request.url?.lastPathComponent == "GetCurrentPeriodUsage"
            return (Data((isUsage ? #"{"planUsage":{"autoPercentUsed":12,"apiPercentUsed":34}}"# : "{}").utf8), HTTPURLResponse(url: request.url!, statusCode: isUsage ? 200 : status, httpVersion: nil, headerFields: nil)!)
        }
        #expect(result.windows.map(\.percent) == [12, 34])
        #expect(result.planName == nil)
        #expect(result.error == nil)
    }

    @Test func malformedPlanInfoDoesNotHideUsage() async {
        let result = await CursorUsageEngine.fetch(tokenLookup: { "test-token" }) { request in
            let isUsage = request.url?.lastPathComponent == "GetCurrentPeriodUsage"
            return (Data((isUsage ? #"{"planUsage":{"autoPercentUsed":12}}"# : "bad json").utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(result.windows.map(\.percent) == [12])
        #expect(result.error == nil)
    }

    @Test func requestsUseDashboardProtocolAndCombinePlanInfo() async {
        let result = await CursorUsageEngine.fetch(tokenLookup: { "test-token" }) { request in
            #expect(request.httpMethod == "POST")
            #expect(request.httpBody == Data("{}".utf8))
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.value(forHTTPHeaderField: "Connect-Protocol-Version") == "1")
            #expect(request.timeoutInterval == 12)
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            let isUsage = request.url?.lastPathComponent == "GetCurrentPeriodUsage"
            #expect(request.url?.absoluteString == "https://api2.cursor.sh/aiserver.v1.DashboardService/" + (isUsage ? "GetCurrentPeriodUsage" : "GetPlanInfo"))
            let body = isUsage ? #"{"planUsage":{"autoPercentUsed":12}}"# : #"{"planInfo":{"planName":"Pro","includedUsageResetsAt":"2000000000000"}}"#
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(result.planName == "Pro")
        #expect(result.windows.map(\.percent) == [12])
        #expect(result.windows.first?.reset == Date(timeIntervalSince1970: 2000000000))
        #expect(result.error == nil)
    }

}
