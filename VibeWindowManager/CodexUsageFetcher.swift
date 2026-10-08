//
//  CodexUsageFetcher.swift
//  VibeWindowManager
//
//  Reads the OpenAI Codex (ChatGPT plan) rate-limit windows — the same numbers
//  Codex CLI's `/status` shows.
//
//  Live source: spawn `codex app-server` (JSON-RPC 2.0, newline-delimited over
//  stdio), send `initialize` → `initialized` → `account/rateLimits/read`, read the
//  response, then shut the process down. Response shape (codex-cli 0.160):
//    { rateLimits: { limitId, limitName, planType,
//                    primary:   { usedPercent, windowDurationMins, resetsAt (unix s) } | null,
//                    secondary: { ... } | null, ... },
//      rateLimitsByLimitId: { "<limitId>": RateLimitSnapshot, ... } | null, ... }
//
//  Fallback: the newest `~/.codex/sessions/**/rollout-*.jsonl` — the last
//  `event_msg` / `token_count` entry carries `rate_limits` in snake_case
//  ({ primary: { used_percent, window_minutes, resets_at | resets_in_seconds }, plan_type }).
//
//  Never reads ~/.codex/auth.json; the codex binary handles auth itself.
//

import Foundation

struct CodexUsageFetcher: UsageFetching {
    /// Hard cap on how long the live `codex app-server` round trip may take.
    var timeout: TimeInterval = 8
    /// Explicit codex binary path; nil = auto-resolve (Homebrew, npm, nvm, login shell…).
    var binaryPath: String? = nil

    func fetch() async -> ProviderUsage {
        let timeout = self.timeout
        let binaryPath = self.binaryPath
        let result = await Task.detached(priority: .utility) {
            CodexUsageEngine.fetch(timeout: timeout, binaryPath: binaryPath)
        }.value
        return result.asProviderUsage()
    }
}

// MARK: - Sendable intermediate result (built off the main actor)

nonisolated struct CodexUsageResult: Sendable {
    struct Window: Sendable {
        let label: String
        let usedPercent: Double
        let resetsAt: Date?
        let sortKey: Int
    }

    var planName: String?
    var windows: [Window]
    var fetchedAt: Date
    var errorMessage: String?
    var source: String

    static func failure(_ message: String) -> CodexUsageResult {
        CodexUsageResult(planName: nil, windows: [], fetchedAt: Date(), errorMessage: message, source: "none")
    }
}

extension CodexUsageResult {
    func asProviderUsage() -> ProviderUsage {
        ProviderUsage(
            provider: .codex,
            planName: planName,
            windows: windows.map { UsageWindow(label: $0.label, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt) },
            fetchedAt: fetchedAt,
            errorMessage: errorMessage
        )
    }
}

// MARK: - Engine

nonisolated enum CodexUsageEngine {
    static func fetch(timeout: TimeInterval, binaryPath: String?) -> CodexUsageResult {
        var liveError: String
        if let binary = binaryPath ?? CodexBinaryLocator.resolve() {
            switch CodexAppServerClient.readRateLimits(binary: binary, timeout: timeout) {
            case .success(let json):
                if let parsed = parseLive(json), !parsed.windows.isEmpty {
                    return parsed
                }
                liveError = "Codex returned no rate-limit windows"
            case .failure(let message):
                liveError = message
            }
        } else {
            liveError = "Codex CLI not found"
        }

        if let fallback = CodexRolloutReader.latestRateLimits() {
            return fallback
        }
        return .failure(liveError)
    }

    // MARK: Live (camelCase) parsing

    static func parseLive(_ result: [String: Any]) -> CodexUsageResult? {
        var snapshots: [[String: Any]] = []
        var seenIds = Set<String>()

        if let main = result["rateLimits"] as? [String: Any] {
            snapshots.append(main)
            if let id = main["limitId"] as? String { seenIds.insert(id) }
        }
        if let byId = result["rateLimitsByLimitId"] as? [String: Any] {
            // Main ("codex") bucket first, then any extra metered buckets in a stable order.
            for key in byId.keys.sorted(by: { ($0 == "codex" ? 0 : 1, $0) < ($1 == "codex" ? 0 : 1, $1) }) {
                guard let snap = byId[key] as? [String: Any] else { continue }
                let id = (snap["limitId"] as? String) ?? key
                if seenIds.contains(id) { continue }
                seenIds.insert(id)
                snapshots.append(snap)
            }
        }
        guard !snapshots.isEmpty else { return nil }

        let now = Date()
        var planName: String?
        var windows: [CodexUsageResult.Window] = []
        var labels = Set<String>()

        for (index, snap) in snapshots.enumerated() {
            if planName == nil { planName = displayPlanName(snap["planType"] as? String) }
            // Extra buckets get a prefix so labels (the UI's ids) stay unique.
            let prefix: String? = index == 0 ? nil : ((snap["limitName"] as? String) ?? (snap["limitId"] as? String))
            for (slot, key) in ["primary", "secondary"].enumerated() {
                guard let w = snap[key] as? [String: Any], let used = number(w["usedPercent"]) else { continue }
                let minutes = number(w["windowDurationMins"]).map { Int($0) }
                let resets = number(w["resetsAt"]).map { Date(timeIntervalSince1970: $0) }
                var label = windowLabel(minutes: minutes, fallback: slot == 0 ? "Primary" : "Secondary")
                if let prefix, !prefix.isEmpty { label = "\(prefix) · \(label)" }
                guard labels.insert(label).inserted else { continue }
                windows.append(makeWindow(label: label, used: used, resetsAt: resets, minutes: minutes,
                                          bucket: index, slot: slot, now: now))
            }
        }

        return CodexUsageResult(planName: planName, windows: sortWindows(windows), fetchedAt: now,
                                errorMessage: nil, source: "app-server")
    }

    // MARK: Shared helpers

    static func makeWindow(label: String, used: Double, resetsAt: Date?, minutes: Int?,
                           bucket: Int, slot: Int, now: Date) -> CodexUsageResult.Window {
        var used = min(max(used, 0), 100)
        var resetsAt = resetsAt
        // A reset time in the past means the window has already rolled over (stale snapshot).
        if let r = resetsAt, r <= now {
            used = 0
            resetsAt = nil
        }
        let sortKey = bucket * 1_000_000 + (minutes ?? (slot == 0 ? 999_000 : 999_001))
        return .init(label: label, usedPercent: used, resetsAt: resetsAt, sortKey: sortKey)
    }

    static func sortWindows(_ windows: [CodexUsageResult.Window]) -> [CodexUsageResult.Window] {
        windows.sorted { $0.sortKey < $1.sortKey }
    }

    static func windowLabel(minutes: Int?, fallback: String) -> String {
        guard let minutes, minutes > 0 else { return fallback }
        switch minutes {
        case 300: return "Session (5h)"
        case 10080: return "Weekly"
        default:
            if minutes % 60 == 0 { return "\(minutes / 60)h window" }
            if minutes < 60 { return "\(minutes)m window" }
            return String(format: "%.1fh window", Double(minutes) / 60)
        }
    }

    static func displayPlanName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw != "unknown" else { return nil }
        let known: [String: String] = [
            "free": "Free", "go": "Go", "plus": "Plus", "pro": "Pro", "prolite": "Pro Lite",
            "promax": "Pro Max", "team": "Team", "business": "Business", "enterprise": "Enterprise",
            "edu": "Edu", "edu_plus": "Edu Plus", "edu_pro": "Edu Pro",
        ]
        if let name = known[raw] { return name }
        return raw.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }
}

// MARK: - codex binary resolution

nonisolated enum CodexBinaryLocator {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: String?

    static func resolve() -> String? {
        lock.lock()
        if let cached, FileManager.default.isExecutableFile(atPath: cached) {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let found = searchCandidates() ?? loginShellLookup()
        lock.lock()
        cached = found
        lock.unlock()
        return found
    }

    private static func searchCandidates() -> String? {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["CODEX_BIN"], !env.isEmpty { candidates.append(env) }
        candidates += [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.bun/bin/codex",
            "\(home)/.volta/bin/codex",
            "\(home)/.cargo/bin/codex",
            "\(home)/Library/pnpm/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
        ]
        // nvm installs: newest node version first.
        let nvmRoot = "\(home)/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmRoot) {
            for v in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                candidates.append("\(nvmRoot)/\(v)/bin/codex")
            }
        }
        // Also respect whatever PATH the app did inherit.
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/codex" }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    /// Last resort: ask the user's login shell (picks up custom PATH setups). Bounded to 4s.
    private static func loginShellLookup() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v codex"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch { return nil }
        if done.wait(timeout: .now() + 4) == .timedOut {
            p.terminate()
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline).last.map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        guard let path, path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }
}

// MARK: - codex app-server JSON-RPC client

nonisolated enum CodexAppServerClient {
    enum Outcome {
        case success([String: Any])
        case failure(String)
    }

    static func readRateLimits(binary: String, timeout: TimeInterval) -> Outcome {
        let deadline = Date().addingTimeInterval(timeout)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server"]

        // GUI apps get a minimal PATH; npm-installed codex is a node script that needs `node`.
        var env = ProcessInfo.processInfo.environment
        let binDir = (binary as NSString).deletingLastPathComponent
        let extra = [binDir, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existing = env["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []
        var seen = Set<String>()
        env["PATH"] = (extra + existing).filter { seen.insert($0).inserted }.joined(separator: ":")
        env["NO_COLOR"] = "1"
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let reader = LineReader(handle: stdoutPipe.fileHandleForReading)
        do {
            try process.run()
        } catch {
            reader.stop()
            return .failure("Couldn't launch codex: \(error.localizedDescription)")
        }

        defer { shutdown(process, stdin: stdinPipe, reader: reader, exited: exited) }

        let writer = stdinPipe.fileHandleForWriting
        func send(_ object: [String: Any]) -> Bool {
            guard var data = try? JSONSerialization.data(withJSONObject: object) else { return false }
            data.append(0x0A)
            do { try writer.write(contentsOf: data); return true } catch { return false }
        }

        let initialize: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["clientInfo": ["name": "vibewindowmanager", "title": "VibeWindowManager", "version": "1.0"],
                       "capabilities": NSNull()],
        ]
        guard send(initialize) else { return .failure("Couldn't talk to codex app-server") }

        switch awaitResponse(id: 1, reader: reader, deadline: deadline) {
        case .failure(let message): return .failure(message)
        case .success: break
        }

        guard send(["jsonrpc": "2.0", "method": "initialized"]),
              send(["jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read",
                    "params": ["excludeResetCreditDetails": true]])
        else { return .failure("Couldn't talk to codex app-server") }

        return awaitResponse(id: 2, reader: reader, deadline: deadline)
    }

    private static func awaitResponse(id: Int, reader: LineReader, deadline: Date) -> Outcome {
        while true {
            guard let line = reader.nextLine(deadline: deadline) else {
                return .failure(reader.isAtEOF ? "codex app-server exited unexpectedly" : "codex app-server timed out")
            }
            guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let responseId = CodexUsageEngine.number(obj["id"]), Int(responseId) == id,
                  obj["method"] == nil
            else { continue } // notifications / server requests / noise
            if let error = obj["error"] as? [String: Any] {
                let message = (error["message"] as? String) ?? "unknown error"
                return .failure("Codex: \(message)")
            }
            return .success((obj["result"] as? [String: Any]) ?? [:])
        }
    }

    private static func shutdown(_ process: Process, stdin: Pipe, reader: LineReader, exited: DispatchSemaphore) {
        try? stdin.fileHandleForWriting.close() // EOF on stdin makes app-server exit on its own
        reader.stop()
        if exited.wait(timeout: .now() + 0.5) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }
}

/// Collects newline-delimited output from a pipe on a background handler; blocking `nextLine` with deadline.
nonisolated private final class LineReader: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var lines: [Data] = []
    private var eof = false

    init(handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] h in
            self?.ingest(h.availableData)
        }
    }

    var isAtEOF: Bool {
        lock.lock(); defer { lock.unlock() }
        return eof
    }

    private func ingest(_ data: Data) {
        lock.lock()
        if data.isEmpty {
            eof = true
            handle.readabilityHandler = nil
            if !buffer.isEmpty { lines.append(buffer); buffer.removeAll() }
        } else {
            buffer.append(data)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                if !line.isEmpty { lines.append(Data(line)) }
                buffer.removeSubrange(buffer.startIndex...nl)
            }
        }
        lock.unlock()
        signal.signal()
    }

    func nextLine(deadline: Date) -> Data? {
        while true {
            lock.lock()
            if !lines.isEmpty {
                let line = lines.removeFirst()
                lock.unlock()
                return line
            }
            let finished = eof
            lock.unlock()
            if finished { return nil }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { return nil }
            _ = signal.wait(timeout: .now() + remaining)
        }
    }

    func stop() {
        handle.readabilityHandler = nil
        try? handle.close()
    }
}

// MARK: - Session rollout fallback

nonisolated enum CodexRolloutReader {
    /// Latest `rate_limits` snapshot from the most recently modified session rollouts.
    static func latestRateLimits() -> CodexUsageResult? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sessions = home.appendingPathComponent(".codex/sessions", isDirectory: true)
        for file in newestRollouts(in: sessions, limit: 6) {
            if let result = parseTail(of: file) { return result }
        }
        return nil
    }

    /// sessions/YYYY/MM/DD/rollout-*.jsonl — walk the newest few day folders only.
    private static func newestRollouts(in root: URL, limit: Int) -> [URL] {
        let fm = FileManager.default
        func subdirs(_ url: URL) -> [URL] {
            let names = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            return names.filter { Int($0) != nil }.sorted(by: >).map { url.appendingPathComponent($0, isDirectory: true) }
        }
        var files: [(URL, Date)] = []
        var dayFoldersScanned = 0
        outer: for year in subdirs(root) {
            for month in subdirs(year) {
                for day in subdirs(month) {
                    let names = (try? fm.contentsOfDirectory(atPath: day.path)) ?? []
                    for name in names where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                        let url = day.appendingPathComponent(name)
                        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                            .contentModificationDate ?? .distantPast
                        files.append((url, mtime))
                    }
                    if !names.isEmpty { dayFoldersScanned += 1 }
                    if dayFoldersScanned >= 3 { break outer }
                }
            }
        }
        return files.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    private static func parseTail(of url: URL) -> CodexUsageResult? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let maxBytes: UInt64 = 4 * 1024 * 1024
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > maxBytes ? size - maxBytes : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd() else { return nil }

        let needle1 = Data("\"token_count\"".utf8)
        let needle2 = Data("\"rate_limits\"".utf8)
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        for line in lines.reversed() {
            guard line.range(of: needle1) != nil, line.range(of: needle2) != nil,
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  (obj["type"] as? String) == "event_msg",
                  let payload = obj["payload"] as? [String: Any],
                  (payload["type"] as? String) == "token_count",
                  let limits = payload["rate_limits"] as? [String: Any]
            else { continue }

            let stamp = (obj["timestamp"] as? String).flatMap(parseISODate)
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            let snapshotDate = stamp ?? mtime ?? Date()
            if let result = parseSnakeCase(limits, snapshotDate: snapshotDate), !result.windows.isEmpty {
                return result
            }
        }
        return nil
    }

    private static func parseSnakeCase(_ limits: [String: Any], snapshotDate: Date) -> CodexUsageResult? {
        let now = Date()
        var windows: [CodexUsageResult.Window] = []
        var labels = Set<String>()
        for (slot, key) in ["primary", "secondary"].enumerated() {
            guard let w = limits[key] as? [String: Any],
                  let used = CodexUsageEngine.number(w["used_percent"]) else { continue }
            let minutes = CodexUsageEngine.number(w["window_minutes"]).map { Int($0) }
            var resets: Date?
            if let at = CodexUsageEngine.number(w["resets_at"]) {
                resets = Date(timeIntervalSince1970: at)
            } else if let inSeconds = CodexUsageEngine.number(w["resets_in_seconds"]) {
                resets = snapshotDate.addingTimeInterval(inSeconds) // relative to when it was logged
            }
            let label = CodexUsageEngine.windowLabel(minutes: minutes, fallback: slot == 0 ? "Primary" : "Secondary")
            guard labels.insert(label).inserted else { continue }
            windows.append(CodexUsageEngine.makeWindow(label: label, used: used, resetsAt: resets,
                                                       minutes: minutes, bucket: 0, slot: slot, now: now))
        }
        guard !windows.isEmpty else { return nil }
        return CodexUsageResult(planName: CodexUsageEngine.displayPlanName(limits["plan_type"] as? String),
                                windows: CodexUsageEngine.sortWindows(windows),
                                fetchedAt: snapshotDate, // when Codex last logged it, not now
                                errorMessage: nil, source: "session-log")
    }

    private static func parseISODate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
