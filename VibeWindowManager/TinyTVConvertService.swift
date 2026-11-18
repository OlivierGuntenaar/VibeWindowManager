//
//  TinyTVConvertService.swift
//  VibeWindowManager
//
//  Converts videos into the TinyTV 2 AVI format (210×135 MJPEG @ 24 fps, mono 8-bit PCM @ 10 kHz)
//  by driving a local ffmpeg. The ffmpeg arguments mirror TinyCircuits' official TinyTVConverterApp
//  (FFMPEGCommands.getAVIConvertCommand) so the output is bit-compatible with what the stock
//  converter produces — including the asetnsamples=210 audio chunking the firmware expects.
//

import AppKit
import Combine
import Foundation

nonisolated enum TinyTVScaling: String, CaseIterable, Identifiable {
    case contain
    case cover
    case stretch

    var id: String { rawValue }

    var label: String {
        switch self {
        case .contain: return "Contain / Letterbox"
        case .cover: return "Cover / Zoom"
        case .stretch: return "Fill / Stretch"
        }
    }

    /// The exact -vf chains the official converter uses for each scaling mode.
    func filter(width: Int, height: Int) -> String {
        switch self {
        case .contain:
            return "scale=\(width):\(height):force_original_aspect_ratio=decrease,format=yuv444p,pad=\(width):\(height):(ow-iw)/2:(oh-ih)/2,format=yuv420p,hqdn3d"
        case .cover:
            return "scale=\(width):\(height):force_original_aspect_ratio=increase,crop=\(width):\(height):exact=1,hqdn3d"
        case .stretch:
            return "scale=\(width):\(height),hqdn3d"
        }
    }
}

nonisolated struct TinyTVQueueItem: Identifiable, Equatable {
    enum Status: Equatable {
        case pending
        case converting
        case done(outputURL: URL)
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let url: URL
    var durationSeconds: Double?
    var status: Status = .pending

    /// Output lands in `directory` when set, otherwise next to the source video.
    func outputURL(in directory: URL?) -> URL {
        let base = url.deletingPathExtension().lastPathComponent
        let name = url.pathExtension.lowercased() == "avi" ? "\(base)-tinytv.avi" : "\(base).avi"
        return (directory ?? url.deletingLastPathComponent()).appendingPathComponent(name)
    }

    /// The official converter estimates AVI output at 187 500 bytes/second for the TinyTV 2.
    var estimatedOutputBytes: Int64? {
        durationSeconds.map { Int64($0 * 187_500) }
    }
}

/// Lock-protected rolling tail of ffmpeg's stderr, appended from the pipe's readability handler.
private nonisolated final class TextTailBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ chunk: String) {
        lock.lock()
        text = String((text + chunk).suffix(4000))
        lock.unlock()
    }

    func contents() -> String {
        lock.lock()
        defer { lock.unlock() }
        return text
    }
}

@MainActor
final class TinyTVConvertService: ObservableObject {
    // TinyTV 2 / AVI parameters from the official converter (VideoOutputSettings, TVTypeOption 3).
    nonisolated static let outputWidth = 210
    nonisolated static let outputHeight = 135
    nonisolated static let outputFrameRate = 24
    nonisolated static let outputAudioSampleRate = 10_000
    nonisolated static let videoBitRate = "1500k"

    @Published var items: [TinyTVQueueItem] = []
    @Published var isConverting: Bool = false
    @Published var currentProgress: Double = 0
    @Published var currentItemID: TinyTVQueueItem.ID?
    @Published var lastError: String?

    private var currentProcess: Process?
    private var cancelRequested = false

    // MARK: - ffmpeg discovery

    static func ffmpegFromCommonInstalls() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let cands = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "\(home)/.local/bin/ffmpeg",
        ]
        return cands.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Resolved ffmpeg path: the user's override when set and executable, otherwise a common install.
    static func resolveFFmpeg(override: String) -> String? {
        let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return FileManager.default.isExecutableFile(atPath: trimmed) ? trimmed : nil
        }
        return ffmpegFromCommonInstalls()
    }

    /// ffprobe ships next to ffmpeg in every packaging we care about.
    static func ffprobePath(ffmpeg: String) -> String? {
        let probe = URL(fileURLWithPath: ffmpeg).deletingLastPathComponent()
            .appendingPathComponent("ffprobe").path
        return FileManager.default.isExecutableFile(atPath: probe) ? probe : nil
    }

    // MARK: - Queue

    func addVideos(urls: [URL], ffmpegPath: String?) {
        for url in urls where !items.contains(where: { $0.url == url }) {
            let item = TinyTVQueueItem(url: url)
            items.append(item)
            guard let ffmpeg = ffmpegPath, let ffprobe = Self.ffprobePath(ffmpeg: ffmpeg) else { continue }
            let id = item.id
            Task.detached { [weak self] in
                let duration = Self.probeDuration(ffprobe: ffprobe, url: url)
                await self?.setDuration(id: id, duration: duration)
            }
        }
    }

    private func setDuration(id: TinyTVQueueItem.ID, duration: Double?) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].durationSeconds = duration
    }

    func removeItem(_ id: TinyTVQueueItem.ID) {
        guard !isConverting else { return }
        items.removeAll { $0.id == id }
    }

    func clearFinished() {
        items.removeAll {
            if case .pending = $0.status { return false }
            if case .converting = $0.status { return false }
            return true
        }
    }

    // MARK: - Conversion

    func convertAll(ffmpegPath: String, scaling: TinyTVScaling, normalizeAudio: Bool, outputDirectory: URL?) {
        guard !isConverting else { return }
        isConverting = true
        cancelRequested = false
        lastError = nil
        for idx in items.indices where items[idx].status != .pending {
            if case .done = items[idx].status { continue }
            items[idx].status = .pending
        }

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let pending = await MainActor.run { self.items.filter { $0.status == .pending } }
            for item in pending {
                let stop = await MainActor.run { self.cancelRequested }
                if stop {
                    await MainActor.run {
                        if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                            self.items[idx].status = .cancelled
                        }
                    }
                    continue
                }
                await self.convertOne(item: item, ffmpegPath: ffmpegPath, scaling: scaling, normalizeAudio: normalizeAudio, outputDirectory: outputDirectory)
            }
            await MainActor.run {
                self.isConverting = false
                self.currentItemID = nil
                self.currentProgress = 0
            }
        }
    }

    func cancel() {
        cancelRequested = true
        currentProcess?.terminate()
    }

    private nonisolated func convertOne(
        item: TinyTVQueueItem,
        ffmpegPath: String,
        scaling: TinyTVScaling,
        normalizeAudio: Bool,
        outputDirectory: URL?
    ) async {
        let outputURL = item.outputURL(in: outputDirectory)
        await MainActor.run {
            self.currentItemID = item.id
            self.currentProgress = 0
            if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                self.items[idx].status = .converting
            }
        }

        // Same normalization the official app applies: boost by 95% of the detected headroom.
        var volumeAdjust = 0.0
        if normalizeAudio, let maxVolume = Self.detectMaxVolume(ffmpeg: ffmpegPath, url: item.url) {
            volumeAdjust = (0 - maxVolume) * 0.95
        }

        let filter = scaling.filter(width: Self.outputWidth, height: Self.outputHeight)
        let audioFilter = String(
            format: "volume=%.1fdB,aresample=%d,aresample=async=1000,aresample=osf=u8,asetnsamples=n=210:p=0",
            volumeAdjust, Self.outputAudioSampleRate
        )
        let args: [String] = [
            "-i", item.url.path,
            "-r", "\(Self.outputFrameRate)",
            "-pix_fmt", "yuv420p",
            "-strict", "unofficial",
            "-vf", filter,
            "-b:v", Self.videoBitRate,
            "-c:v", "mjpeg",
            "-ac", "1",
            "-acodec", "pcm_u8",
            "-af", audioFilter,
            "-y",
            outputURL.path,
        ]

        let duration = item.durationSeconds
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = args
        process.standardOutput = Pipe()
        let errPipe = Pipe()
        process.standardError = errPipe

        let errBuffer = TextTailBuffer()
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            guard let chunk = String(data: handle.availableData, encoding: .utf8), !chunk.isEmpty else { return }
            errBuffer.append(chunk)
            if let duration, duration > 0, let seconds = Self.parseProgressTime(chunk) {
                Task { @MainActor [weak self] in
                    self?.currentProgress = min(1, seconds / duration)
                }
            }
        }

        await MainActor.run { self.currentProcess = process }
        do {
            try process.run()
        } catch {
            await MainActor.run {
                self.lastError = "ffmpeg failed to launch: \(error.localizedDescription)"
                if let idx = self.items.firstIndex(where: { $0.id == item.id }) {
                    self.items[idx].status = .failed(error.localizedDescription)
                }
            }
            return
        }
        process.waitUntilExit()
        errPipe.fileHandleForReading.readabilityHandler = nil

        let status = process.terminationStatus
        let tail = errBuffer.contents()
        await MainActor.run {
            self.currentProcess = nil
            guard let idx = self.items.firstIndex(where: { $0.id == item.id }) else { return }
            if self.cancelRequested {
                self.items[idx].status = .cancelled
                try? FileManager.default.removeItem(at: outputURL)
            } else if status == 0 {
                self.items[idx].status = .done(outputURL: outputURL)
                self.currentProgress = 1
            } else {
                let lastLine = tail.split(separator: "\n").last.map(String.init) ?? "ffmpeg exited with status \(status)"
                self.items[idx].status = .failed(lastLine)
                self.lastError = lastLine
            }
        }
    }

    // MARK: - Preview

    /// One frame at 2× output size with the scaling filter applied, as PNG data — the same
    /// approach as the official converter's preview (it renders at double size for crispness).
    /// Returns Data rather than NSImage so the result can safely cross actor boundaries.
    nonisolated static func previewFrameData(
        ffmpeg: String,
        url: URL,
        scaling: TinyTVScaling,
        seconds: Double
    ) -> Data? {
        let filter = scaling.filter(width: outputWidth * 2, height: outputHeight * 2)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = [
            "-ss", String(format: "%.3f", max(0, seconds)),
            "-i", url.path,
            "-frames:v", "1",
            "-vf", filter,
            "-f", "image2pipe",
            "-c:v", "png",
            "-",
        ]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }

    // MARK: - ffprobe / volumedetect helpers

    private nonisolated static func probeDuration(ffprobe: String, url: URL) -> Double? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffprobe)
        p.arguments = [
            "-v", "error",
            "-show_entries", "format=duration",
            "-of", "default=noprint_wrappers=1:nokey=1",
            url.path,
        ]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let value = Double(text) else { return nil }
        return value
    }

    private nonisolated static func detectMaxVolume(ffmpeg: String, url: URL) -> Double? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-i", url.path, "-af", "volumedetect", "-vn", "-f", "null", "-"]
        p.standardOutput = Pipe()
        let err = Pipe()
        p.standardError = err
        do { try p.run() } catch { return nil }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        // volumedetect reports e.g. "max_volume: -7.4 dB"
        for line in text.split(separator: "\n") where line.contains("max_volume") {
            let parts = line.split(separator: ":")
            if let last = parts.last {
                let number = last.replacingOccurrences(of: "dB", with: "")
                    .trimmingCharacters(in: .whitespaces)
                return Double(number)
            }
        }
        return nil
    }

    /// ffmpeg progress lines look like "... time=00:01:23.45 bitrate=...".
    private nonisolated static func parseProgressTime(_ chunk: String) -> Double? {
        guard let range = chunk.range(of: "time=", options: .backwards) else { return nil }
        let after = chunk[range.upperBound...].prefix(11)
        let stamp = after.prefix { "0123456789:.".contains($0) }
        let parts = stamp.split(separator: ":").compactMap { Double($0) }
        switch parts.count {
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        case 2: return parts[0] * 60 + parts[1]
        case 1: return parts[0]
        default: return nil
        }
    }
}
