import Foundation
import Testing
@testable import VibeWindowManager

@MainActor
struct WindowCLIBoundaryTests {
    @Test(arguments: ["help", "--help", "-h", "HELP"])
    func helpAliasesDoNotRequireApp(alias: String) throws {
        #expect(try WindowCLI.parse(userArguments: [alias]) == .help)
    }

    @Test func noArgumentsShowsHelp() throws {
        #expect(try WindowCLI.parse(userArguments: []) == .help)
    }

    @Test(arguments: ["columns", "rows", "grid", "cascade", "one-plus-two"])
    func allLayoutsPreserveAppQuery(layout: String) throws {
        #expect(try WindowCLI.parse(userArguments: ["Visual Studio Code", layout.uppercased()]) ==
                .layout(appQuery: "Visual Studio Code", layout: WindowCLILayout(rawValue: layout)!, pixel: nil))
    }

    @Test func missingAppForBridgeDumpIsActionable() {
        do {
            _ = try WindowCLI.parse(userArguments: ["bridge-dump"])
            Issue.record("Missing app was accepted")
        } catch WindowCLIParseError.missingAppQuery { } catch { Issue.record(error) }
    }

    @Test func missingLayoutIsRejected() {
        do {
            _ = try WindowCLI.parse(userArguments: ["Cursor"])
            Issue.record("Missing layout was accepted")
        } catch WindowCLIParseError.missingLayout { } catch { Issue.record(error) }
    }

    @Test func unknownLayoutIdentifiesTheBadValue() {
        do {
            _ = try WindowCLI.parse(userArguments: ["Cursor", "spiral"])
            Issue.record("Unknown layout was accepted")
        } catch WindowCLIParseError.unknownLayout(let value) { #expect(value == "spiral") }
        catch { Issue.record(error) }
    }

    @Test func missingPixelValueIsRejected() {
        do {
            _ = try WindowCLI.parse(userArguments: ["Cursor", "cascade", "--pixel"])
            Issue.record("Missing pixel was accepted")
        } catch WindowCLIParseError.missingPixelValue { } catch { Issue.record(error) }
    }

    @Test(arguments: ["NaN", "nan", "Infinity", "-inf", "1e999", "abc", ""])
    func malformedOrNonfinitePixelsAreRejected(value: String) {
        do {
            _ = try WindowCLI.parse(userArguments: ["Cursor", "cascade", "--pixel", value])
            Issue.record("Invalid pixel accepted: \(value)")
        } catch WindowCLIParseError.invalidPixelValue(let rejected) { #expect(rejected == value) }
        catch { Issue.record(error) }
    }

    @Test func fractionalPixelValueIsPreserved() throws {
        #expect(try WindowCLI.parse(userArguments: ["Cursor", "cascade", "--pixel", "12.5"]) ==
                .layout(appQuery: "Cursor", layout: .cascade, pixel: 12.5))
    }

    @Test func unknownOptionCannotAccidentallyMoveWindows() {
        do {
            _ = try WindowCLI.parse(userArguments: ["Cursor", "grid", "--surprise"])
            Issue.record("Unknown option was accepted")
        } catch WindowCLIParseError.unknownOption(let value) { #expect(value == "--surprise") }
        catch { Issue.record(error) }
    }

    @Test(arguments: [
        ["-psn_0_123"], ["-NSShowNonLocalizedStrings", "YES"],
        ["-XCTest", "/tmp/FakeTests.xctest"], ["-NSDocumentRevisionsDebugMode", "YES"],
        ["-NSTreatUnknownArgumentsAsOpen", "NO", "-ApplePersistenceIgnoreState", "YES"]
    ])
    func launchInfrastructureArgumentsDoNotEnterCLI(flags: [String]) {
        #expect(!WindowCLI.shouldRun(arguments: ["/Applications/VibeWindowManager.app/Contents/MacOS/VibeWindowManager"] + flags))
    }

    @Test func genuineCommandsSurviveLaunchFlags() {
        #expect(WindowCLI.shouldRun(arguments: ["VibeWindowManager", "-psn_0_123", "-NSShowNonLocalizedStrings", "YES", "list-apps"]))
    }

    @Test func finderLaunchDoesNotEnterCLI() {
        #expect(!WindowCLI.shouldRun(arguments: ["/Applications/VibeWindowManager.app/Contents/MacOS/VibeWindowManager"]))
    }
}

@MainActor
struct TerminalTextBoundaryTests {
    @Test(arguments: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
    func unicodeSuffixRemainsValidAndWithinByteBudget(budget: Int) {
        let input = "A€🙂終"
        let (output, truncated) = TmuxPaneCapture.utf8ByteSuffix(input, maxBytes: budget)
        #expect(output.utf8.count <= budget)
        #expect(input.hasSuffix(output))
        #expect(!output.contains("�"))
        #expect(truncated)
    }

    @Test func exactByteBudgetPreservesWholeInput() {
        let input = "🙂€"
        let (output, truncated) = TmuxPaneCapture.utf8ByteSuffix(input, maxBytes: input.utf8.count)
        #expect(output == input)
        #expect(!truncated)
    }

    @Test func emptyInputNeverReportsTruncation() {
        for budget in [-1, 0, 1, 100] {
            let (output, truncated) = TmuxPaneCapture.utf8ByteSuffix("", maxBytes: budget)
            #expect(output.isEmpty)
            #expect(!truncated)
        }
    }

    @Test func trailingEmptyLineIsRetained() {
        let result = TmuxPaneCapture.applyLineAndByteLimits("old\nnew\n", lineLimit: 2)
        #expect(result.text == "new\n")
        #expect(result.truncated)
    }

    @Test func byteLimitStillAppliesAfterLineLimit() {
        let result = TmuxPaneCapture.applyLineAndByteLimits("discard\n12345\n🙂END", lineLimit: 2, maxBytes: 6)
        #expect(result.text == "END")
        #expect(result.truncated)
    }

    @Test(arguments: [-10, 0]) func nonpositiveLineLimitKeepsAtLeastOneLine(limit: Int) {
        let result = TmuxPaneCapture.applyLineAndByteLimits("old\nnew", lineLimit: limit)
        #expect(result.text == "new")
        #expect(result.truncated)
    }
}
