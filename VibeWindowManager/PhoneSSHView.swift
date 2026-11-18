import AppKit
import Combine
import CoreImage.CIFilterBuiltins
import SwiftUI

private struct DesktopSSHHost: Decodable, Identifiable {
    var id: String { alias }
    let alias: String
    let hostname: String
    let username: String
}
private struct DesktopPairedDevice: Decodable, Identifiable { let id: String; let name: String }

@MainActor
private final class PhoneSSHModel: ObservableObject {
    @Published var busy = false
    @Published var error: String?
    @Published var hosts: [DesktopSSHHost] = []
    @Published var devices: [DesktopPairedDevice] = []
    @Published var selected: Set<String> = []
    @Published var pairingURL: String?
    @Published var pairedNotice: String?
    @Published var expires: Date?
    @Published var endpoint = ""
    @Published var name = "This Mac"
    private var token = ""
    private let state = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vibe-terminal-desktop")

    nonisolated static func run(_ executable: String, _ arguments: [String]) async throws -> Data {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            // stderr goes to a temporary file to avoid a full-pipe deadlock.
            let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let handle = try FileHandle(forWritingTo: log)
            process.standardError = handle
            defer { try? handle.close(); try? FileManager.default.removeItem(at: log) }
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = NSHomeDirectory() + "/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = env
            try process.run()
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 180, execute: timeout)
            defer { timeout.cancel() }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "VibeTerminal", code: 1, userInfo: [NSLocalizedDescriptionKey: "The setup command failed. Check that Tailscale, Python 3 and tmux are installed, and SSH to the mini works."])
            }
            return data
        }.value
    }

    func perform(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }
    func enableLocal() async throws {
        guard let archive = Bundle.main.url(forResource: "TerminalGateway", withExtension: "zip") else {
            throw failure("The terminal runtime is missing from this build.")
        }
        let runtime = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/VibeWindowManager/TerminalGateway")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        _ = try await Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, runtime.path])
        guard let python = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw failure("Install Python 3 and tmux with Homebrew, then enable this Mac again.")
        }
        _ = try await Self.run(python, [runtime.appendingPathComponent("install_desktop.py").path])
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(300))
            if FileManager.default.fileExists(atPath: state.appendingPathComponent("token").path) { break }
        }
        try await loadLocal()
    }
    func loadLocal() async throws {
        struct Connection: Decodable { let endpoint: String; let name: String }
        let config = try JSONDecoder().decode(Connection.self, from: Data(contentsOf: state.appendingPathComponent("connection.json")))
        endpoint = config.endpoint; name = config.name
        token = try String(contentsOf: state.appendingPathComponent("token"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        pairingURL = nil
        try await refresh()
    }
    func useMini() async throws {
        let key = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/id_ed25519").path
        let data = try await Self.run("/usr/bin/ssh", ["-o", "IdentitiesOnly=yes", "-i", key, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "mcmurdo@100.103.214.86", "cat ~/.vibe-terminal/token"])
        token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        endpoint = "http://100.103.214.86:9843"; name = "Mac mini"; pairingURL = nil
        try await refresh()
    }
    func request<T: Decodable>(_ type: T.Type, path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        guard let url = URL(string: endpoint)?.appendingPathComponent(path), !token.isEmpty else { throw failure("Enable this Mac or choose the Mac mini first.") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15; request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw failure(String(String(decoding: data, as: UTF8.self).prefix(300))) }
        return try JSONDecoder().decode(type, from: data)
    }
    func refresh() async throws {
        hosts = try await request([DesktopSSHHost].self, path: "v1/importable-hosts")
        devices = try await request([DesktopPairedDevice].self, path: "v1/devices")
        selected = selected.intersection(Set(hosts.map(\.alias)))
    }
    func pair() async throws {
        struct Grant: Decodable { let code: String; let expiresIn: Int }
        let grant = try await request(Grant.self, path: "v1/pairings", method: "POST")
        var url = URLComponents(); url.scheme = "vibeterminal"; url.host = "pair"
        url.queryItems = [.init(name: "endpoint", value: endpoint), .init(name: "code", value: grant.code), .init(name: "name", value: name)]
        pairedNotice = nil
        pairingURL = url.string; expires = Date().addingTimeInterval(Double(grant.expiresIn))
    }
    func share() async throws {
        struct Host: Decodable { let id: String }
        _ = try await request([Host].self, path: "v1/import-hosts", method: "POST", body: JSONSerialization.data(withJSONObject: ["aliases": Array(selected)]))
        selected = []
        pairedNotice = "Hosts shared. Pull to refresh Terminal on your phone."
        try await refresh()
    }
    func revoke(_ device: DesktopPairedDevice) async throws {
        struct Result: Decodable { let ok: Bool }
        _ = try await request(Result.self, path: "v1/devices/" + device.id, method: "DELETE")
        try await refresh()
    }
    func failure(_ message: String) -> NSError { NSError(domain: "VibeTerminal", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

struct PhoneSSHView: View {
    @StateObject private var model = PhoneSSHModel()
    @State private var revoking: DesktopPairedDevice?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connect a Mac").font(.title2.weight(.semibold))
                HStack {
                    Button("Set up this Mac") { model.perform { try await model.enableLocal() } }
                        .help("Install or update this Mac’s terminal gateway.")
                    Button("Use this Mac") { model.perform { try await model.loadLocal() } }
                        .help("Connect to this Mac’s existing terminal gateway.")
                    Button("Use Mac mini") { model.perform { try await model.useMini() } }
                        .help("Use the mini for sessions that keep running when your laptop closes.")
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small) }
                }.disabled(model.busy)
                if let error = model.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
                if !model.endpoint.isEmpty {
                    GroupBox {
                        HStack(alignment: .top, spacing: 24) {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(model.name).font(.title2.bold())
                                    .help(model.endpoint)
                                Text("Keep this Mac awake and Tailscale connected on both devices.")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Pair phone") { model.perform { try await model.pair() } }.buttonStyle(.borderedProminent).disabled(model.busy)
                                if let link = model.pairingURL, let expiry = model.expires, Date() < expiry {
                                    Button("Copy pairing link") {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(link, forType: .string)
                                    }
                                }
                                if let notice = model.pairedNotice { Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if let url = model.pairingURL {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    if let expiry = model.expires, context.date < expiry, let image = qr(url) {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Image(nsImage: image).interpolation(.none).resizable().frame(width: 220, height: 220).padding(12).background(.white).privacySensitive()
                                                .accessibilityLabel("Phone pairing QR code")
                                            Text("Vibe on iPhone: Terminal → Pair a Mac")
                                                .font(.caption)
                                            Text("Expires \(expiry.formatted(date: .omitted, time: .shortened))")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    } else { Text("Code expired. Pair phone again.").frame(width: 220, height: 220) }
                                }
                            }
                        }.padding(16)
                    }
                    GroupBox("SSH hosts") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(model.hosts) { host in
                                Toggle(isOn: Binding(get: { model.selected.contains(host.alias) }, set: { if $0 { model.selected.insert(host.alias) } else { model.selected.remove(host.alias) } })) {
                                    HStack { Text(host.alias).fontWeight(.medium); Spacer(); Text("\(host.username)@\(host.hostname)").foregroundStyle(.secondary) }
                                }
                            }
                            if model.hosts.isEmpty { Text("No hosts in ~/.ssh/config.").foregroundStyle(.secondary) }
                            HStack {
                                Button {
                                    model.perform { try await model.refresh() }
                                } label: {
                                    Label("Refresh hosts and devices", systemImage: "arrow.clockwise")
                                        .labelStyle(.iconOnly)
                                }
                                .help("Refresh hosts and paired devices")
                                Button("Share with phone") { model.perform { try await model.share() } }.disabled(model.selected.isEmpty)
                                    .help("Share the selected SSH hosts with your phone.")
                            }.disabled(model.busy)
                        }.padding(12)
                    }
                    GroupBox("Paired devices") {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(model.devices) { device in
                                HStack { Text(device.name); Spacer(); Button("Revoke access", role: .destructive) { revoking = device } }
                            }
                            if model.devices.isEmpty { Text("No paired devices.").foregroundStyle(.secondary) }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                DisclosureGroup("Setup & help") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Set up this Mac once, then choose it and pair your phone. Keep Tailscale connected on both devices.")
                        Text("Your Mac must stay awake. Use the mini for sessions that should continue when the laptop closes.")
                        Text("SSH hosts come from ~/.ssh/config and its Include files. Keys and jump-host settings stay on the Mac. Hosts can also be imported from your phone.")
                        if !model.endpoint.isEmpty {
                            Text(model.endpoint).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(20).frame(maxWidth: 1000, alignment: .leading)
        }
        .task(id: model.pairingURL) {
            guard let link = model.pairingURL else { return }
            let initialIDs = Set(model.devices.map(\.id))
            while !Task.isCancelled, model.pairingURL == link, let expiry = model.expires, Date() < expiry {
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                try? await model.refresh()
                if let added = model.devices.first(where: { !initialIDs.contains($0.id) }) {
                    model.pairingURL = nil; model.expires = nil
                    model.pairedNotice = "\(added.name) is paired."
                    return
                }
            }
        }
        .confirmationDialog("Revoke this phone’s terminal access?", isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } })) {
            Button("Revoke access", role: .destructive) { if let device = revoking { model.perform { try await model.revoke(device) } }; revoking = nil }
        }
    }
    private func qr(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
