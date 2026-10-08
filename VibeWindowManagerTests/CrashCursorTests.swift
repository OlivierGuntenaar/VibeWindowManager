import Foundation
import SQLite3
import Testing
@testable import VibeWindowManager

/// Deterministic hostile-input corpora: no live Cursor credentials or requests.
struct CrashCursorTests {
    @Test func malformedFieldCorpusNeverEmitsUnsafePercentages() {
        let values: [Any] = [NSNull(), true, false, [], ["nested": ["value": 1]],
            "", "NaN", "Infinity", "-Infinity", "1e9999", "-1e9999",
            String(repeating: "9", count: 4096), "\u{0}",
            Double.nan, Double.infinity, -Double.infinity,
            Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude,
            Double.leastNonzeroMagnitude, 0, 100, "34.25"]
        for value in values {
            let result = CursorUsageEngine.parse([
                "planUsage": ["autoPercentUsed": value, "apiPercentUsed": value,
                    "totalPercentUsed": value, "includedSpend": value, "limit": value],
                "spendLimitUsage": ["individualUsed": value, "individualLimit": value],
                "billingCycleEnd": value
            ], info: ["planInfo": ["planName": value, "includedUsageResetsAt": value]])
            #expect(result.windows.count <= 3)
            #expect(Set(result.windows.map(\.label)).count == result.windows.count)
            for window in result.windows {
                #expect(window.percent.isFinite)
                #expect((0...100).contains(window.percent))
                if let reset = window.reset { #expect(reset.timeIntervalSince1970.isFinite) }
            }
        }
    }

    @Test func tinyAndHugeAllowancesCannotOverflowDisplayedUsage() {
        let amounts: [Double] = [.leastNonzeroMagnitude, .leastNormalMagnitude, 0.01, 1,
            1e100, .greatestFiniteMagnitude]
        let usages: [Double] = [-Double.greatestFiniteMagnitude, -1, 0,
            .leastNonzeroMagnitude, 0.01, 1, 1e100, .greatestFiniteMagnitude]
        for limit in amounts {
            for used in usages {
                let result = CursorUsageEngine.parse([
                    "planUsage": ["limit": limit, "includedSpend": used],
                    "spendLimitUsage": ["individualLimit": limit, "individualUsed": used]
                ])
                #expect(result.windows.count == 2)
                for window in result.windows {
                    #expect(window.percent.isFinite)
                    #expect((0...100).contains(window.percent))
                    if used >= limit { #expect(window.percent == 100) }
                    if used <= 0 { #expect(window.percent == 0) }
                }
            }
        }
    }

    @MainActor @Test func extremeParsedDatesAndPercentagesAreSafeToRender() {
        for value in [Double.greatestFiniteMagnitude, 1e100, 1e22, 1791894570000, 1] {
            let result = CursorUsageEngine.parse([
                "billingCycleEnd": value,
                "planUsage": ["autoPercentUsed": value]
            ])
            #expect(result.windows.count == 1)
            for window in result.windows {
                #expect(UsageFormat.percentText(window.percent, showsRemaining: false) == "100% used" || value == 1)
                let resetText = UsageFormat.resetText(window.reset, now: Date(timeIntervalSince1970: 1700000000))
                if value >= 1e100 { #expect(resetText == nil) }
                else { #expect(resetText != nil) }
            }
        }
    }

    @Test func wrongContainerCorpusDoesNotCrash() {
        for container in [NSNull(), false, 12, "planUsage", [1, 2], [["autoPercentUsed": 1]]] as [Any] {
            let result = CursorUsageEngine.parse([
                "planUsage": container, "spendLimitUsage": container
            ], info: ["planInfo": container])
            #expect(result.windows.isEmpty)
            #expect(result.error != nil)
        }
    }

    @Test(arguments: ["{", "\u{0}", "[null,true,42]", "1e9999", "{\"planUsage\":{\"autoPercentUsed\":1e9999}}", "{\"planUsage\":{\"autoPercentUsed\":\"1e9999\"}}"])
    func hostileResponseBodiesReturnErrors(body: String) async {
        let result = await CursorUsageEngine.fetch(tokenLookup: { "fake-test-token" }) { request in
            (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(result.windows.isEmpty)
        #expect(result.error != nil)
    }

    @Test func invalidUTF8ResponseReturnsError() async {
        let result = await CursorUsageEngine.fetch(tokenLookup: { "fake-test-token" }) { request in
            (Data([0xFF, 0xFE, 0x80, 0xC0]), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        #expect(result.windows.isEmpty)
        #expect(result.error != nil)
    }

    @Test func truncatedSQLiteCorpusDoesNotCrashOrRewriteFiles() throws {
        let corpus = [Data(), Data([0]), Data("SQLite format 3\0".utf8),
            Data(repeating: 0xFF, count: 4096), Data((0..<256).map(UInt8.init))]
        for data in corpus {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try data.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(CursorUsageEngine.accessToken(databasePath: url.path) == nil)
            #expect(try Data(contentsOf: url) == data)
        }
    }
}
