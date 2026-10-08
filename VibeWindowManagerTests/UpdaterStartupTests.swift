import Foundation
import Sparkle
import Testing
@testable import VibeWindowManager

/// Exercise Sparkle itself, not a stub. Fixtures have isolated preference domains
/// and automatic checks disabled, so these tests never show alerts or use the network.
@MainActor
struct UpdaterStartupTests {
    private func withUpdater(
        changes: [String: Any] = [:], removing keys: [String] = [],
        _ body: (SPUUpdater) throws -> Void
    ) throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("VibeUpdaterTests-\(UUID().uuidString).app")
        let identifier = "com.thomasguntenaar.VibeUpdaterTests.\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removePersistentDomain(forName: identifier)
            try? FileManager.default.removeItem(at: folder)
        }
        let contents = folder.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleName": "Updater fixture",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "3",
            "CFBundleShortVersionString": "1.0.1",
            "SUFeedURL": "https://example.invalid/appcast.xml",
            "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString(),
            "SUEnableAutomaticChecks": false,
            "SUAutomaticallyUpdate": false,
            "SURequireSignedFeed": true,
            "SUVerifyUpdateBeforeExtraction": true,
        ]
        info.merge(changes) { _, new in new }
        keys.forEach { info.removeValue(forKey: $0) }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: folder))
        let driver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
        let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle,
                                 userDriver: driver, delegate: nil)
        try body(updater)
    }

    @Test func signedFeedConfigurationStartsWithoutAnAppleIdentity() throws {
        try withUpdater { updater in
            try updater.start()
            #expect(updater.canCheckForUpdates)
            #expect(!updater.automaticallyChecksForUpdates)
            #expect(!updater.automaticallyDownloadsUpdates)
        }
    }

    @Test func startingTwiceKeepsTheUpdaterUsable() throws {
        try withUpdater { updater in
            try updater.start()
            try updater.start()
            #expect(updater.canCheckForUpdates)
            #expect(!updater.sessionInProgress)
        }
    }

    @Test func signedFeedWithoutPreExtractionVerificationReproducesStartupRegression() throws {
        try withUpdater(removing: ["SUVerifyUpdateBeforeExtraction"]) { updater in
            do {
                try updater.start()
                Issue.record("Sparkle accepted the configuration that broke build 2")
            } catch {
                #expect(error.localizedDescription.contains("SUVerifyUpdateBeforeExtraction"))
                #expect(!updater.canCheckForUpdates)
            }
        }
    }

    @Test func falsePreExtractionVerificationAlsoFails() throws {
        try withUpdater(changes: ["SUVerifyUpdateBeforeExtraction": false]) { updater in
            #expect(throws: (any Error).self) { try updater.start() }
            #expect(!updater.canCheckForUpdates)
        }
    }

    @Test func unsignedHostCannotRequireSignedUpdatesWithoutPublicKey() throws {
        try withUpdater(removing: ["SUPublicEDKey"]) { updater in
            #expect(throws: (any Error).self) { try updater.start() }
            #expect(!updater.canCheckForUpdates)
        }
    }

    @Test(arguments: ["not base64", Data(repeating: 7, count: 31).base64EncodedString(),
                      Data(repeating: 7, count: 33).base64EncodedString()])
    func invalidPublicKeyIsRejected(key: String) throws {
        try withUpdater(changes: ["SUPublicEDKey": key]) { updater in
            #expect(throws: (any Error).self) { try updater.start() }
        }
    }

    @Test func missingBuildNumberCannotStart() throws {
        try withUpdater(removing: ["CFBundleVersion"]) { updater in
            #expect(throws: (any Error).self) { try updater.start() }
        }
    }

    @Test func developmentBuildDoesNotStartUpdater() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "VibeEnableUpdater") as? Bool != true)
        let updater = AppUpdater()
        updater.start()
        updater.start()
        #expect(!updater.canCheckForUpdates)
    }
}
