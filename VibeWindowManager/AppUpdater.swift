import Combine
import Sparkle
import SwiftUI

/// A single updater shared by the main app and menu-bar panel. Development builds
/// and CLI invocations never start it; the distribution script explicitly enables it.
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()
    @Published private(set) var canCheckForUpdates = false
    private var controller: SPUStandardUpdaterController?

    func start() {
        guard controller == nil,
              Bundle.main.object(forInfoDictionaryKey: "VibeEnableUpdater") as? Bool == true else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
        controller.startUpdater()
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = AppUpdater.shared
    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!updater.canCheckForUpdates)
    }
}
