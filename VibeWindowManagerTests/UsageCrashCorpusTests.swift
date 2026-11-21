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
            let key = "acct:a|c:o:https://api.anthropic.com:user:profile"
            if !(value is String) || (value as? String)?.isEmpty == true {
                #expect(ClaudeDesktopSession.usableTokens(in: [key: ["token": value]], account: nil).isEmpty)
            }
            #expect(ClaudeDesktopSession.usableTokens(in: [key: value], account: nil).isEmpty)
        }
    }

    @Test func malformedEncryptedBlobsNeverDecrypt() {
        let password = Data("fixture-password".utf8)
        var state: UInt64 = 0x5AFE5AFE
        var blobs = ["", "v10", "djEw", "not base64!", Data("v11".utf8).base64EncodedString(),
                     (Data("v10".utf8) + Data(repeating: 0, count: 15)).base64EncodedString()]
        for length in stride(from: 16, through: 256, by: 16) {
            let noise = (0..<length).map { _ -> UInt8 in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return UInt8(truncatingIfNeeded: state >> 33)
            }
            blobs.append((Data("v10".utf8) + Data(noise)).base64EncodedString())
        }
        for blob in blobs {
            if let plain = ClaudeDesktopSession.decrypt(blob, password: password) {
                // Random ciphertext can occasionally carry valid padding; it must never parse as a cache.
                #expect((try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] == nil)
            }
        }
        #expect(ClaudeDesktopSession.decrypt(blobs.last!, password: Data()) == nil)
    }
}
