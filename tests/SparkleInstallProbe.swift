// Disposable integration host. Never points at the installed application.
import AppKit
import Foundation
import Sparkle

@MainActor
final class InstallProbe: NSObject, SPUUpdaterDelegate, SPUUserDriver, NSApplicationDelegate {
    var updater: SPUUpdater?
    var events: [String] = [] {
        didSet {
            if bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "1" {
                try? JSONSerialization.data(withJSONObject: events).write(to: output.appendingPathExtension("stages"), options: .atomic)
            }
        }
    }
    let bundle = Bundle.main
    var output: URL { URL(fileURLWithPath: bundle.object(forInfoDictionaryKey: "TestResultPath") as! String) }

    func finish(error: Error? = nil, installed: Bool = false) {
        let result: [String: Any] = ["events": events, "error": error?.localizedDescription ?? "",
            "errorCode": (error as NSError?)?.code ?? 0,
            "build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "setting": UserDefaults.standard.string(forKey: "integrationSentinel") ?? "",
            "installed": installed]
        try! JSONSerialization.data(withJSONObject: result).write(to: output, options: .atomic)
        NSApp.terminate(nil)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "2" {
            if let data = try? Data(contentsOf: output.appendingPathExtension("stages")),
               let previous = try? JSONSerialization.jsonObject(with: data) as? [String] {
                events = previous
            }
            events.append("relaunched-new-version")
            finish(installed: true)
            return
        }
        UserDefaults.standard.set("preserve-me", forKey: "integrationSentinel")
        UserDefaults.standard.synchronize()
        let value = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: self, delegate: self)
        updater = value
        do { try value.start(); value.checkForUpdates() }
        catch { finish(error: error) }
    }
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error { finish(error: error) }
    }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { events.append("check") }
    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        events.append("found"); reply(.install)
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) { acknowledgement(); finish(error: error) }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) { acknowledgement(); finish(error: error) }
    func showDownloadInitiated(cancellation: @escaping () -> Void) { events.append("download") }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) { if !events.contains("received-data") { events.append("received-data") } }
    func showDownloadDidStartExtractingUpdate() { events.append("extract") }
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        events.append("ready"); reply(.install)
    }
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        events.append("install")
    }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) { acknowledgement() }
    func dismissUpdateInstallation() {}
}

@main
struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = InstallProbe()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
