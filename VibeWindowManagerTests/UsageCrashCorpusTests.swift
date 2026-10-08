import Foundation
import Testing
@testable import VibeWindowManager

/// Fixed seeds keep adversarial coverage reproducible; no credentials or network are used.
@MainActor
struct UsageCrashCorpusTests {
    private func doubles() -> [Double] {
        var state: UInt64 = 0xC0DEC0FFEE
        return (0..<2048).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(bitPattern: state)
        } + [.nan, .infinity, -.infinity, .greatestFiniteMagnitude,
             -.greatestFiniteMagnitude, 0, -0.0, Double(Int.max), Double(Int.min)]
    }

    @Test func arbitraryDoubleBitsCannotCrashUsageFormatting() {
        let now = Date(timeIntervalSince1970: 0)
        for value in doubles() {
            let text = UsageFormat.percentText(value, showsRemaining: false)
            #expect(!text.isEmpty)
            #expect(!UsageFormat.percentText(value, showsRemaining: true).isEmpty)
            #expect(!UsageFormat.compactDuration(value).isEmpty)
            let date = Date(timeIntervalSince1970: value)
            #expect(!UsageFormat.updatedText(date, now: now).isEmpty)
            _ = UsageFormat.resetText(date, now: now)
            _ = UsageFormat.barColor(value)
            if !value.isFinite { #expect(text == "unavailable") }
        }
    }

    @Test func arbitraryDoubleBitsProduceOnlyBoundedUsageWindows() {
        for value in doubles() {
            let claude = ClaudeUsageFetcher.parseWindows([
                "five_hour": ["utilization": value, "resets_at": value]
            ])
            for window in claude {
                #expect(window.usedPercent.isFinite && (0...100).contains(window.usedPercent))
            }
            let codex = CodexUsageEngine.parseLive([
                "rateLimits": ["primary": ["usedPercent": value,
                                           "windowDurationMins": value, "resetsAt": value]]
            ])
            for window in codex?.windows ?? [] {
                #expect(window.usedPercent.isFinite && (0...100).contains(window.usedPercent))
            }
        }
    }

    @Test func unexpectedJSONShapesAreRejectedWithoutCrashing() {
        let values: [Any] = [NSNull(), true, false, [], [:], ["nested": [1, 2]],
                             "", "nan", "1e999", ["wrong"], 1e300]
        for value in values {
            #expect(ClaudeUsageFetcher.parseWindows(["five_hour": value]).isEmpty)
            #expect(CodexUsageEngine.parseLive(["rateLimits": value])?.windows.isEmpty != false)
            let credential: [String: Any] = ["claudeAiOauth": ["accessToken": value]]
            if !(value is String) || (value as? String)?.isEmpty == true {
                let data = try? JSONSerialization.data(withJSONObject: credential)
                if let data { #expect(ClaudeUsageFetcher.parseCredential(data) == nil) }
            }
        }
    }

    @Test func truncatedCredentialDocumentsNeverYieldPartialCredentials() {
        let valid = Data(#"{"claudeAiOauth":{"accessToken":"test-only-token","expiresAt":2000000000000}}"#.utf8)
        for length in 0..<valid.count {
            #expect(ClaudeUsageFetcher.parseCredential(valid.prefix(length)) == nil)
        }
        for bytes: [UInt8] in [[0xff], [0xc0, 0xaf], [0x7b, 0xff, 0x7d], [0, 0, 0]] {
            #expect(ClaudeUsageFetcher.parseCredential(Data(bytes)) == nil)
        }
    }
}
