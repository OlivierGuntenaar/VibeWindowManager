//
//  TinyTVTabView.swift
//  VibeWindowManager
//
//  Convert videos for the TinyCircuits TinyTV 2 — drop-in replacement for the Intel-only
//  official converter app. AVI output only, TinyTV 2 only (210×135 MJPEG @ 24 fps).
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TinyTVTabView: View {
    @ObservedObject var converter: TinyTVConvertService

    @AppStorage("vibeTinyTVFFmpegPath") private var ffmpegOverridePath: String = ""
    @AppStorage("vibeTinyTVScaling") private var scalingRaw: String = TinyTVScaling.contain.rawValue
    @AppStorage("vibeTinyTVNormalizeAudio") private var normalizeAudio: Bool = false
    @AppStorage("vibeTinyTVOutputDir") private var outputDirPath: String = ""

    /// nil means the default: next to each source video.
    private var outputDirectory: URL? {
        guard !outputDirPath.isEmpty else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: outputDirPath, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return URL(fileURLWithPath: outputDirPath, isDirectory: true)
    }

    private var outputDirMissing: Bool {
        !outputDirPath.isEmpty && outputDirectory == nil
    }

    private var scaling: TinyTVScaling {
        TinyTVScaling(rawValue: scalingRaw) ?? .contain
    }

    private var ffmpegPath: String? {
        TinyTVConvertService.resolveFFmpeg(override: ffmpegOverridePath)
    }

    @State private var previewItemID: TinyTVQueueItem.ID?
    @State private var previewFraction: Double = 0.25
    @State private var previewImages: [TinyTVScaling: NSImage] = [:]
    @State private var previewLoading = false
    @State private var previewGeneration = 0

    private var previewItem: TinyTVQueueItem? {
        if let id = previewItemID, let item = converter.items.first(where: { $0.id == id }) {
            return item
        }
        return converter.items.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if ffmpegPath == nil {
                    ffmpegMissingCard
                }
                queueCard
                if !converter.items.isEmpty {
                    previewCard
                }
                optionsCard
                convertCard
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("TinyTV 2 converter")
                    .font(.title2.weight(.semibold))
                Text("Convert any video into the TinyTV 2's AVI format — 210×135 MJPEG at 24 fps with mono 8-bit audio — matching the official TinyCircuits converter's output. Copy the .avi files onto the TV's SD card.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button {
                openVideoPanel()
            } label: {
                Label("Open Videos…", systemImage: "film")
            }
            .buttonStyle(.borderedProminent)
            .disabled(converter.isConverting)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - ffmpeg missing

    private var ffmpegMissingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("ffmpeg not found", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange)
            Text("Conversion uses a local ffmpeg. Install it with `brew install ffmpeg`, or point at a binary below.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("/opt/homebrew/bin/ffmpeg", text: $ffmpegOverridePath)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    // MARK: - Queue

    private var queueCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Videos")
                    .font(.headline)
                Spacer()
                if converter.items.contains(where: { if case .done = $0.status { return true } else { return false } }) {
                    Button("Clear finished") { converter.clearFinished() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if converter.items.isEmpty {
                Text("No videos yet. Open one or more videos to queue them for conversion.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                ForEach(converter.items) { item in
                    queueRow(item)
                    if item.id != converter.items.last?.id {
                        Divider()
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    @ViewBuilder
    private func queueRow(_ item: TinyTVQueueItem) -> some View {
        HStack(spacing: 10) {
            statusIcon(item.status)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.url.lastPathComponent)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    if let duration = item.durationSeconds {
                        Text(Self.timeString(duration))
                    }
                    if let bytes = item.estimatedOutputBytes {
                        Text("≈ \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                    }
                    if case .failed(let message) = item.status {
                        Text(message)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if item.id == converter.currentItemID, converter.isConverting {
                    ProgressView(value: converter.currentProgress)
                        .progressViewStyle(.linear)
                        .padding(.top, 2)
                }
            }
            Spacer()
            if case .done(let outputURL) = item.status {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                } label: {
                    Image(systemName: "magnifyingglass.circle")
                }
                .buttonStyle(.plain)
                .help("Reveal converted file in Finder")
            }
            if !converter.isConverting {
                Button {
                    converter.removeItem(item.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove from queue")
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: TinyTVQueueItem.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
        case .converting:
            ProgressView()
                .controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .cancelled:
            Image(systemName: "slash.circle")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Preview

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Preview")
                    .font(.headline)
                Spacer()
                if converter.items.count > 1 {
                    Picker("Video", selection: $previewItemID) {
                        ForEach(converter.items) { item in
                            Text(item.url.lastPathComponent)
                                .tag(Optional(item.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280)
                }
            }
            Text("How each scaling mode frames this video on the TinyTV's screen. Click one to use it for conversion.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                ForEach(TinyTVScaling.allCases) { mode in
                    previewTile(mode)
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $previewFraction, in: 0...1) { editing in
                    if !editing { regeneratePreviews() }
                }
                Text(Self.timeString((previewItem?.durationSeconds ?? 0) * previewFraction))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .onAppear { regeneratePreviews() }
        .onChange(of: previewItemID) { _, _ in regeneratePreviews() }
        .onChange(of: previewItem?.durationSeconds) { _, _ in regeneratePreviews() }
    }

    @ViewBuilder
    private func previewTile(_ mode: TinyTVScaling) -> some View {
        let isSelected = mode == scaling
        Button {
            scalingRaw = mode.rawValue
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    // Black behind the frame, like the TV's screen — letterbox bars read correctly.
                    Rectangle()
                        .fill(.black)
                        .aspectRatio(210.0 / 135.0, contentMode: .fit)
                    if let image = previewImages[mode] {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else if previewLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "film")
                            .foregroundStyle(.secondary)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.3),
                                      lineWidth: isSelected ? 2.5 : 1)
                }
                HStack(spacing: 4) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    Text(mode.label)
                        .foregroundStyle(isSelected ? .primary : .secondary)
                }
                .font(.caption.weight(isSelected ? .semibold : .regular))
            }
        }
        .buttonStyle(.plain)
        .disabled(converter.isConverting)
    }

    private func regeneratePreviews() {
        guard let ffmpeg = ffmpegPath, let item = previewItem else {
            previewImages = [:]
            return
        }
        previewGeneration += 1
        let generation = previewGeneration
        let url = item.url
        // Without a probed duration yet, sample 1 second in — better than a often-black frame 0.
        let seconds = (item.durationSeconds ?? 4) * previewFraction
        previewLoading = true
        Task.detached(priority: .userInitiated) {
            var frames: [TinyTVScaling: Data] = [:]
            for mode in TinyTVScaling.allCases {
                if let data = TinyTVConvertService.previewFrameData(
                    ffmpeg: ffmpeg, url: url, scaling: mode, seconds: seconds
                ) {
                    frames[mode] = data
                }
            }
            let result = frames
            await MainActor.run {
                guard generation == previewGeneration else { return }
                previewImages = result.compactMapValues { NSImage(data: $0) }
                previewLoading = false
            }
        }
    }

    // MARK: - Options

    private var optionsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Options")
                .font(.headline)
            Picker("Scaling", selection: $scalingRaw) {
                ForEach(TinyTVScaling.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .disabled(converter.isConverting)
            Toggle(isOn: $normalizeAudio) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Normalize audio volume")
                        .font(.subheadline.weight(.medium))
                    Text("Measures each video's peak level first and boosts quiet audio — the TinyTV's speaker is small, so this usually helps. Adds a second pass per video.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .disabled(converter.isConverting)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Output folder")
                    .font(.subheadline.weight(.medium))
                HStack(spacing: 8) {
                    Image(systemName: outputDirPath.isEmpty ? "film.stack" : "folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(outputDirPath.isEmpty
                         ? "Next to each video (default)"
                         : (outputDirPath as NSString).abbreviatingWithTildeInPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if !outputDirPath.isEmpty {
                        Button("Reset") { outputDirPath = "" }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Back to saving next to each video")
                    }
                    Button("Choose…") { chooseOutputDirectory() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                if outputDirMissing {
                    Label("That folder no longer exists — files will be saved next to each video until you pick a new one.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .disabled(converter.isConverting)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    // MARK: - Convert

    private var convertCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = converter.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                if converter.isConverting {
                    Button(role: .cancel) {
                        converter.cancel()
                    } label: {
                        Label("Cancel", systemImage: "stop.circle")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        guard let ffmpeg = ffmpegPath else { return }
                        converter.convertAll(ffmpegPath: ffmpeg, scaling: scaling, normalizeAudio: normalizeAudio, outputDirectory: outputDirectory)
                    } label: {
                        Label("Convert Videos", systemImage: "arrow.right.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(ffmpegPath == nil || converter.items.isEmpty)
                }
                Spacer()
                Text(outputDirectory == nil
                     ? "Output: .avi next to each source file"
                     : "Output: \((outputDirectory!.path as NSString).abbreviatingWithTildeInPath)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    // MARK: - Helpers

    private var cardBackground: some View {
        VibeCardSurface()
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose where converted .avi files are saved — e.g. the TinyTV's SD card"
        panel.prompt = "Use Folder"
        if let dir = outputDirectory {
            panel.directoryURL = dir
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputDirPath = url.path
    }

    private func openVideoPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .avi, .video]
        panel.message = "Choose videos to convert for the TinyTV 2"
        guard panel.runModal() == .OK else { return }
        converter.addVideos(urls: panel.urls, ffmpegPath: ffmpegPath)
    }

    private static func timeString(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
