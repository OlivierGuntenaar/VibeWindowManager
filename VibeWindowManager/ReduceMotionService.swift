import AppKit
import Combine
import SwiftUI

nonisolated enum ReduceMotionWriteResult: Sendable { case completed, needsSetup, failed }

/// One system setting shared by the status panel, app menu, and main window.
@MainActor
final class ReduceMotionService: ObservableObject {
    static let shared = ReduceMotionService()

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isUpdating = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var needsSetup = false

    private let read: () -> Bool
    private let write: ((Bool) async -> ReduceMotionWriteResult)?
    private let verificationAttempts: Int
    private let verificationDelay: Duration
    private var subscriptions: Set<AnyCancellable> = []

    init(read: @escaping () -> Bool = SystemReduceMotion.read,
         write: ((Bool) async -> ReduceMotionWriteResult)? = { _ in await ReduceMotionShortcut.run() },
         observeSystem: Bool = true,
         verificationAttempts: Int = 40,
         verificationDelay: Duration = .milliseconds(100)) {
        self.read = read
        self.write = write
        self.verificationAttempts = max(1, verificationAttempts)
        self.verificationDelay = verificationDelay
        isEnabled = read()
        if observeSystem {
            NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &subscriptions)
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.refresh() }
                .store(in: &subscriptions)
        }
    }

    var binding: Binding<Bool> {
        Binding(get: { self.isEnabled }, set: { self.setEnabled($0) })
    }

    func refresh() {
        let actual = read()
        if actual != isEnabled { errorMessage = nil }
        isEnabled = actual
    }

    func setEnabled(_ enabled: Bool) {
        guard !isUpdating else { return }
        refresh()
        errorMessage = nil
        guard enabled != isEnabled else { return }
        guard let write else {
            errorMessage = "Change Reduce Motion in System Settings."
            return
        }
        isUpdating = true
        Task { [weak self] in
            guard let self else { return }
            defer { isUpdating = false }
            switch await write(enabled) {
            case .completed:
                needsSetup = false
            case .needsSetup:
                needsSetup = true
                errorMessage = "Add Vibe’s shortcut, then try again."
                refresh()
                return
            case .failed:
                errorMessage = "Couldn’t change Reduce Motion. Try again."
                refresh()
                return
            }
            for attempt in 0..<verificationAttempts {
                refresh()
                if isEnabled == enabled { return }
                if attempt + 1 < verificationAttempts {
                    try? await Task.sleep(for: verificationDelay)
                }
            }
            errorMessage = "macOS didn’t apply the change."
        }
    }

    func installHelper() {
        guard let url = Bundle.main.url(forResource: ReduceMotionShortcut.name, withExtension: "shortcut") else {
            errorMessage = "The Reduce Motion helper is missing."
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Motion") else { return }
        NSWorkspace.shared.open(url)
    }
}

private enum SystemReduceMotion {
    private static let domain = "com.apple.universalaccess" as CFString
    private static let key = "reduceMotion" as CFString

    static func read() -> Bool {
        // Read the persistent system value, not a process-local AppKit override.
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return (CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool)
            ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

}

/// Apple's supported Shortcuts action owns the protected preference change.
/// One signed, bundled helper contains only “Toggle Reduce Motion”. The CLI runs
/// it in the background only after an explicit click; no private APIs or writes.
nonisolated enum ReduceMotionShortcut {
    static let name = "Vibe Toggle Reduce Motion"

    @concurrent static func run() async -> ReduceMotionWriteResult {
        let listed = command(["list"])
        guard listed.status == 0 else { return .failed }
        guard let names = String(data: listed.output, encoding: .utf8),
              names.components(separatedBy: .newlines).contains(name) else { return .needsSetup }
        guard !Task.isCancelled else { return .failed }
        return command(["run", name]).status == 0 ? .completed : .failed
    }

    private static func command(_ arguments: [String]) -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (-1, Data()) }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: deadline)
        defer { deadline.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}

struct ReduceMotionControl: View {
    @ObservedObject var motion = ReduceMotionService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: motion.binding) {
                Label("Reduce Motion", systemImage: "figure.walk")
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.callout)
            .disabled(motion.isUpdating)
            .help("Reduce motion throughout macOS")
            .accessibilityIdentifier("reduce-motion-toggle")
            if let error = motion.errorMessage {
                Text(error).font(.caption).foregroundStyle(.secondary)
                Button(motion.needsSetup ? "Set Up…" : "Open Motion Settings…") {
                    if motion.needsSetup { motion.installHelper() } else { motion.openSettings() }
                }
                .font(.caption)
            }
        }
        .onAppear { motion.refresh() }
    }
}

struct ReduceMotionCommands: Commands {
    @ObservedObject var motion = ReduceMotionService.shared

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Toggle("Reduce Motion", isOn: motion.binding)
                .disabled(motion.isUpdating)
                .help("Reduce motion throughout macOS")
            if motion.errorMessage != nil {
                Button(motion.needsSetup ? "Set Up Reduce Motion…" : "Open Motion Settings…") {
                    if motion.needsSetup { motion.installHelper() } else { motion.openSettings() }
                }
            }
        }
    }
}
