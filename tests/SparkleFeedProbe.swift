// Used by test_sparkle_feed.py: probe with the real Sparkle engine, never install.
import AppKit
import Foundation
import CryptoKit
import Sparkle

@MainActor
final class Probe: NSObject, SPUUpdaterDelegate {
    var foundVersion: String?
    var done = false
    var failure: NSError?
    var noUpdate = false
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        foundVersion = item.versionString
    }
    func updaterDidNotFindUpdate(_ updater: SPUUpdater) { noUpdate = true }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        failure = error as NSError?
        done = true
    }
}

@main
struct Main {
    @MainActor static func main() throws {
        if CommandLine.arguments.dropFirst().first == "--test-key" {
            let key = Curve25519.Signing.PrivateKey()
            let output = ["seed": key.rawRepresentation.base64EncodedString(),
                          "publicKey": key.publicKey.rawRepresentation.base64EncodedString()]
            print(String(data: try JSONSerialization.data(withJSONObject: output), encoding: .utf8)!)
            return
        }
        guard CommandLine.arguments.count == 2, let host = Bundle(path: CommandLine.arguments[1]) else {
            fatalError("Expected a test host bundle")
        }
        let delegate = Probe()
        let driver = SPUStandardUserDriver(hostBundle: host, delegate: nil)
        let updater = SPUUpdater(hostBundle: host, applicationBundle: host, userDriver: driver, delegate: delegate)
        try updater.start()
        updater.checkForUpdateInformation()
        let timeout = Date().addingTimeInterval(15)
        while !delegate.done && Date() < timeout {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        let output: [String: Any] = [
            "completed": delegate.done,
            "found": delegate.foundVersion ?? "",
            "noUpdate": delegate.noUpdate,
            "errorCode": delegate.failure?.code ?? 0,
            "error": delegate.failure?.localizedDescription ?? "",
        ]
        print(String(data: try JSONSerialization.data(withJSONObject: output), encoding: .utf8)!)
        if !delegate.done { exit(2) }
    }
}
