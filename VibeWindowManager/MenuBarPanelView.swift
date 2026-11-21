//
//  MenuBarPanelView.swift
//  VibeWindowManager
//
//  The `.window`-style menu bar extra: Claude / Codex usage limits on top, then the quick actions,
//  the local-servers list and Quit.
//

import AppKit
import SwiftUI

// MARK: - Shared actions (also used by the app's `.commands`)

@MainActor
enum VibeMenuBarActions {
    static func cascadeCursorOnExtraOrMainDisplay() {
        if let message = WindowCLI.applyCascadeForAppOnExtraOrMainScreen(appQuery: "cursor") {
            let alert = NSAlert()
            alert.messageText = "Couldn’t cascade Cursor"
            alert.informativeText = message
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    /// Modal confirmation for a destructive signal. Returns true when the user went through with it.
    static func confirmKill(_ server: LocalServerProcess, force: Bool, uptime: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = force
            ? "Force kill “\(server.displayName)”?"
            : "Quit “\(server.displayName)”?"
        alert.informativeText = """
            \(VibeServerMenuFormat.portsSentence(server)) · pid \(server.pid) · up \(uptime)

            \(force
                ? "SIGKILL cannot be caught — the process dies immediately and will not save state or clean up."
                : "SIGTERM asks the process to shut down cleanly.")
            """
        alert.alertStyle = force ? .critical : .warning
        alert.addButton(withTitle: force ? "Force Kill" : "Quit Process")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func openInBrowser(port: Int) {
        guard let url = URL(string: "http://localhost:\(port)") else { return }
        NSWorkspace.shared.open(url)
    }

    static func copyCommand(_ server: LocalServerProcess) {
        let command = server.commandLine.isEmpty ? server.command : server.commandLine
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
    }

    static func isLikelyHTTPPort(_ port: Int) -> Bool {
        LocalServerProcess.isLikelyHTTPPort(port)
    }
}

/// Pure label formatting for the menu-bar server entries.
///
/// Everything here returns a plain `String` on purpose: `Menu`/`Button`/`Text` take a
/// `LocalizedStringKey`, which number-formats an interpolated `Int` for the user's locale — port 5000
/// would render as “:5.000” in nl_NL. Swift string interpolation never does that, and passing a
/// `String` picks the verbatim `StringProtocol` overloads of those initialisers (or use
/// `Text(verbatim:)`).
enum VibeServerMenuFormat {
    /// `:8787`, or `:80 +11` when the process listens on more ports than the primary one.
    static func portBadge(_ server: LocalServerProcess) -> String {
        let extra = max(server.ports.count - 1, 0)
        return extra > 0 ? ":\(server.primaryPort) +\(extra)" : ":\(server.primaryPort)"
    }

    /// `:8787 — sayso_bridge · Dev server · sayso · 5d 1h · 30 MB`
    static func entryTitle(_ server: LocalServerProcess, uptime: String) -> String {
        var parts = [portBadge(server), "— \(server.displayName)"]
        let subtitle = server.subtitle
        if !subtitle.isEmpty { parts.append("· \(subtitle)") }
        if !uptime.isEmpty { parts.append("· \(uptime)") }
        if server.residentBytes != nil { parts.append("· \(server.memoryText)") }
        return parts.joined(separator: " ")
    }

    /// `Dev server · sayso · 5d 1h · 30 MB` — the part of `entryTitle` after the name, for the
    /// panel's second line.
    static func detailLine(_ server: LocalServerProcess, uptime: String) -> String {
        var parts: [String] = []
        let subtitle = server.subtitle
        if !subtitle.isEmpty { parts.append(subtitle) }
        if !uptime.isEmpty { parts.append(uptime) }
        if server.residentBytes != nil { parts.append(server.memoryText) }
        return parts.joined(separator: " · ")
    }

    /// `80, 443, 8080` — all ports of the process, for the multi-port detail row.
    static func portList(_ server: LocalServerProcess) -> String {
        server.ports.map { "\($0)" }.joined(separator: ", ")
    }

    /// `Port 8787` / `Ports 80, 443` — used inside the kill confirmation.
    static func portsSentence(_ server: LocalServerProcess) -> String {
        server.ports.count > 1 ? "Ports \(portList(server))" : "Port \(server.primaryPort)"
    }
}

// MARK: - Usage formatting

enum UsageFormat {
    /// `resets in 2h 14m`, `resets in 4d 3h`, `resets in 9m`, or `reset` once the time has passed.
    static func resetText(_ resetsAt: Date?, now: Date) -> String? {
        guard let resetsAt else { return nil }
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds.isFinite else { return nil }
        guard seconds > 0 else { return "reset" }
        guard Int(exactly: (seconds / 60).rounded(.up)) != nil else { return nil }
        return "resets in \(compactDuration(seconds))"
    }

    /// `just now`, `1m ago`, `3h ago`, `2d ago`.
    static func updatedText(_ date: Date?, now: Date) -> String {
        guard let date else { return "not updated yet" }
        let elapsed = now.timeIntervalSince(date)
        guard elapsed.isFinite else { return "update time unavailable" }
        let seconds = max(elapsed, 0)
        if seconds < 60 { return "updated just now" }
        guard let minutes = Int(exactly: (seconds / 60).rounded(.towardZero)) else {
            return "update time unavailable"
        }
        if minutes < 60 { return "updated \(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "updated \(hours)h ago" }
        return "updated \(hours / 24)d ago"
    }

    static func compactDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, let roundedMinutes = Int(exactly: (seconds / 60).rounded(.up)) else {
            return "unknown"
        }
        let totalMinutes = max(roundedMinutes, 1)
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes % (24 * 60)) / 60
        let minutes = totalMinutes % 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(minutes)m"
    }

    static func errorText(_ message: String) -> AttributedString {
        (try? AttributedString(
            markdown: message,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(message)
    }

    /// `42% used`, or `58% left` for providers that count down (Codex).
    static func percentText(_ used: Double, showsRemaining: Bool) -> String {
        guard used.isFinite else { return "unavailable" }
        let clamped = min(max(used, 0), 100)
        return showsRemaining
            ? "\(Int((100 - clamped).rounded()))% left"
            : "\(Int(clamped.rounded()))% used"
    }

    /// Green under 60 %, amber under 85 %, red from 85 %.
    static func barColor(_ used: Double) -> Color {
        guard used.isFinite else { return .gray }
        if used >= 85 { return .red }
        if used >= 60 { return .orange }
        return .green
    }
}

extension UsageProvider {
    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .grokBot: return "Grok Bot"
        }
    }

    var symbolName: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow"
        case .grokBot: return "bolt"
        }
    }

    /// Codex counts down (100 % → 0 % left), Claude counts up (0 % → 100 % used) — matching how
    /// each CLI reports its own limits. Colour severity is always driven by the used share.
    var showsRemaining: Bool {
        switch self {
        case .claude, .cursor, .grokBot: return false
        case .codex: return true
        }
    }

    var tint: Color {
        switch self {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: return Color(red: 0.25, green: 0.55, blue: 0.95)
        case .cursor: return Color(red: 0.55, green: 0.45, blue: 0.85)
        case .grokBot: return Color(red: 0.35, green: 0.65, blue: 0.75)
        }
    }
}

// MARK: - Panel

private enum PanelMetrics {
    static let width: CGFloat = 340
    static let padding: CGFloat = 12
    /// Rows carry their own inner padding so the hover highlight can bleed past the text.
    static let rowInset: CGFloat = 6
    static let maxServerListHeight: CGFloat = 300
}

struct MenuBarPanelView: View {
    let mainWindowID: String

    @EnvironmentObject private var bridge: VibeBridgeServer
    @ObservedObject var usage: UsageLimitsService = .shared
    @ObservedObject var servers: LocalServerScanService = .shared
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @AppStorage("menuBarPanel.serversExpanded") private var serversExpanded = true
    @AppStorage("menuBarPanel.backgroundExpanded") private var backgroundExpanded = false

    @State private var windowBox = PanelWindowBox()
    @State private var serverListHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            UsageSection(usage: usage, showDiagnostics: false) {
                UserDefaults.standard.set(MainTab.usage.rawValue, forKey: MainTab.selectionKey)
                closePanel()
                openWindow(id: mainWindowID)
                NSApp.activate(ignoringOtherApps: true)
            }
                .padding(PanelMetrics.padding)

            Divider()

            actionsSection
                .padding(.horizontal, PanelMetrics.rowInset)
                .padding(.vertical, PanelMetrics.rowInset)

            Divider()

            serversSection
                .padding(.horizontal, PanelMetrics.rowInset)
                .padding(.vertical, PanelMetrics.rowInset)

            Divider()

            CheckForUpdatesButton()
                .padding(PanelMetrics.rowInset)

            PanelActionRow(title: "Quit VibeWindowManager", symbol: "power", shortcut: "⌘Q") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
            .padding(PanelMetrics.rowInset)
        }
        .frame(width: PanelMetrics.width)
        .transaction { transaction in
            if reduceMotion {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .background(PanelWindowReader { windowBox.window = $0 })
        .onAppear { panelDidOpen() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard let window = note.object as? NSWindow, window === windowBox.window else { return }
            panelDidOpen()
        }
    }

    private func panelDidOpen() {
        usage.refreshIfStale(maxAge: 60)
    }

    /// `@Environment(\.dismiss)` doesn't reliably close MenuBarExtra windows, so close the hosting
    /// window directly.
    private func closePanel() {
        if let window = windowBox.window {
            window.close()
        } else {
            NSApp.keyWindow?.close()
        }
    }

    // MARK: Actions

    private var actionsSection: some View {
        VStack(spacing: 0) {
            PanelActionRow(title: "Show Window", symbol: "macwindow") {
                closePanel()
                openWindow(id: mainWindowID)
                NSApp.activate(ignoringOtherApps: true)
            }

            PanelToggleRow(
                title: "iOS bridge server",
                symbol: "iphone.radiowaves.left.and.right",
                isOn: Binding(
                    get: { bridge.isRunning },
                    set: { on in
                        UserDefaults.standard.set(on, forKey: VibeAppPersistence.bridgeServerEnabledKey)
                        if on { bridge.start() } else { bridge.stop() }
                    }
                )
            )

            ReduceMotionControl()
                .padding(.horizontal, PanelMetrics.rowInset)
                .padding(.vertical, 5)

            PanelActionRow(title: "Cascade Cursor (extra display…)", symbol: "rectangle.stack", shortcut: "⇧⌘C") {
                closePanel()
                VibeMenuBarActions.cascadeCursorOnExtraOrMainDisplay()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
        }
    }

    // MARK: Local servers

    @ViewBuilder
    private var serversSection: some View {
        let ranked = servers.ranked
        let background = servers.background

        VStack(spacing: 0) {
            HStack(spacing: 6) {
                DisclosureHeader(
                    title: "Local servers",
                    count: ranked.count,
                    isExpanded: $serversExpanded
                )
                if servers.isScanning {
                    ProgressView().controlSize(.mini)
                }
                PanelIconButton(symbol: "arrow.clockwise", help: "Refresh servers") {
                    servers.refresh()
                }
            }
            .padding(.trailing, PanelMetrics.rowInset)

            if serversExpanded {
                if ranked.isEmpty, background.isEmpty {
                    Text("No listening servers")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, PanelMetrics.rowInset + 24)
                        .padding(.vertical, 6)
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(ranked) { server in
                                ServerRow(server: server, servers: servers)
                            }

                            if !background.isEmpty {
                                DisclosureHeader(
                                    title: "Background services",
                                    count: background.count,
                                    isExpanded: $backgroundExpanded,
                                    isNested: true
                                )
                                if backgroundExpanded {
                                    ForEach(background) { server in
                                        ServerRow(server: server, servers: servers)
                                    }
                                }
                            }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { serverListHeight = $0 }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: min(serverListHeight, PanelMetrics.maxServerListHeight))
                }

                if let error = servers.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, PanelMetrics.rowInset)
                        .padding(.vertical, 4)
                }
            }
        }
    }
}

// MARK: - Usage section

struct UsageSettingsView: View {
    @ObservedObject var usage: UsageLimitsService = .shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Connected meters appear in the menu bar. Connection messages and setup options stay here.")
                    .foregroundStyle(.secondary)
                Text("Usage comes from your signed-in accounts, whether or not their apps are open.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                UsageSection(usage: usage, showDiagnostics: true)
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { usage.refreshIfStale() }
    }
}

private struct UsageSection: View {
    @ObservedObject var usage: UsageLimitsService
    let showDiagnostics: Bool
    var manageUsage: (() -> Void)? = nil

    private func retry(for provider: UsageProvider) -> (() -> Void)? {
        if provider == .claude, usage.claude?.requiresKeychainAccess == true {
            return { usage.authorizeClaudeKeychain() }
        }
        if provider == .cursor, usage.cursor?.errorMessage != nil {
            return { usage.authorizeCursorKeychain() }
        }
        return nil
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("Usage")
                        .font(.callout.weight(.semibold))
                    Spacer(minLength: 4)
                    Text(verbatim: UsageFormat.updatedText(usage.lastRefreshed, now: now))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    if usage.isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 20, height: 20)
                    } else {
                        PanelIconButton(symbol: "arrow.clockwise", help: "Refresh usage") {
                            usage.refresh()
                        }
                    }
                }

                ForEach(showDiagnostics ? UsageProvider.allCases : usage.menuProviders, id: \.self) { provider in
                    ProviderUsageCard(provider: provider, usage: usage.usage(for: provider), now: now,
                        retry: showDiagnostics ? retry(for: provider) : nil,
                        isRetrying: provider == .claude ? usage.isAuthorizingClaude :
                            (provider == .cursor && usage.isAuthorizingCursor),
                        showDiagnostics: showDiagnostics)
                }
                if !showDiagnostics {
                    if usage.menuProviders.isEmpty {
                        Text(usage.isRefreshing ? "Checking usage…" : "No connected usage meters")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let manageUsage {
                        Button("Manage usage…", action: manageUsage)
                            .font(.caption)
                    }
                }
            }
        }
    }
}

private struct ProviderUsageCard: View {
    let provider: UsageProvider
    let usage: ProviderUsage?
    let now: Date
    var retry: (() -> Void)? = nil
    var isRetrying = false
    var showDiagnostics = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: provider.symbolName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(provider.tint)
                    .frame(width: 16)
                Text(verbatim: provider.displayName)
                    .font(.callout.weight(.semibold))
                if let plan = usage?.planName, !plan.isEmpty {
                    PlanBadge(text: plan, tint: provider.tint)
                }
                Spacer(minLength: 0)
                if isRetrying {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 20, height: 20)
                        .accessibilityLabel("Waiting for \(provider.displayName) Keychain access")
                } else if let retry {
                    Button("Reconnect \(provider.displayName)", action: retry)
                        .controlSize(.small)
                        .help("May request Keychain access")
                        .accessibilityIdentifier("\(provider.rawValue)-keychain-retry")
                }
            }

            if let usage {
                ForEach(usage.windows) { window in
                    UsageWindowRow(window: window, now: now, showsRemaining: provider.showsRemaining)
                }
                if let note = usage.sourceNote {
                    Text(verbatim: note + " · " + UsageFormat.updatedText(usage.fetchedAt, now: now))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if showDiagnostics, let error = usage.errorMessage, !error.isEmpty {
                    // Errors may carry inline markdown (e.g. "run `claude` in a terminal and /login");
                    // parse inline-only so backticks render as code, falling back to the raw text.
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(UsageFormat.errorText(error))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if showDiagnostics, usage.windows.isEmpty {
                    Text("No limits reported")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                UsageSkeleton()
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.quaternary.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.5)
        )
    }
}

private struct UsageWindowRow: View {
    let window: UsageWindow
    let now: Date
    let showsRemaining: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: window.label)
                    .font(.callout)
                    .truncationMode(.tail)
                // Some windows (e.g. Claude "Extra usage") have no reset time — just omit it.
                if let reset = UsageFormat.resetText(window.resetsAt, now: now) {
                    Text(verbatim: reset)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .layoutPriority(1)
                }
                Spacer(minLength: 4)
                Text(verbatim: UsageFormat.percentText(window.usedPercent, showsRemaining: showsRemaining))
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(window.usedPercent >= 85 ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                    .layoutPriority(2)
            }
            .lineLimit(1)
            UsageBar(usedPercent: window.usedPercent, showsRemaining: showsRemaining)
        }
    }
}

private struct UsageBar: View {
    let usedPercent: Double
    /// Fill the bar with what's left (drains towards empty) instead of what's used.
    let showsRemaining: Bool

    var body: some View {
        let used = min(max(usedPercent, 0), 100)
        let fraction = (showsRemaining ? 100 - used : used) / 100
        Capsule()
            .fill(.quaternary)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(UsageFormat.barColor(used).gradient)
                        .frame(width: max(proxy.size.width * fraction, fraction > 0 ? 4 : 0))
                }
            }
            .frame(height: 5)
            .animation(.easeOut(duration: 0.25), value: usedPercent)
    }
}

private struct UsageSkeleton: View {
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(["Session window", "Weekly window"], id: \.self) { label in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(verbatim: label).font(.callout)
                        Spacer()
                        Text(verbatim: "00% used").font(.callout)
                    }
                    Capsule().fill(.quaternary).frame(height: 5)
                }
            }
        }
        .redacted(reason: .placeholder)
        .opacity(pulse ? 0.45 : 0.9)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityLabel("Loading usage")
    }
}

private struct PlanBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(verbatim: text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .foregroundStyle(tint)
            .background(Capsule().fill(tint.opacity(0.15)))
    }
}

// MARK: - Server rows

private struct ServerRow: View {
    let server: LocalServerProcess
    @ObservedObject var servers: LocalServerScanService

    @State private var isHovering = false

    var body: some View {
        let uptime = servers.uptimeText(for: server)
        let port = server.primaryPort
        let opensInBrowser = VibeMenuBarActions.isLikelyHTTPPort(port)

        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: server.category.symbolName)
                    .font(.callout)
                    .foregroundStyle(server.category == .scratch ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(verbatim: VibeServerMenuFormat.portBadge(server))
                            .font(.callout.weight(.semibold))
                            .monospacedDigit()
                        Text(verbatim: server.displayName)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if opensInBrowser, isHovering {
                            Image(systemName: "arrow.up.right.square")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    let detail = VibeServerMenuFormat.detailLine(server, uptime: uptime)
                    if !detail.isEmpty {
                        Text(verbatim: detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if opensInBrowser { VibeMenuBarActions.openInBrowser(port: port) }
            }

            Menu {
                ServerActions(server: server, uptime: uptime, servers: servers)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.body)
            }
            .menuStyle(.button)
            .buttonStyle(.borderless)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.secondary)
            .opacity(isHovering ? 1 : 0.55)
            .help("Actions")
        }
        .padding(.horizontal, PanelMetrics.rowInset)
        .padding(.vertical, 4)
        .hoverHighlight(isHovering)
        .onHover { isHovering = $0 }
        .contextMenu {
            ServerActions(server: server, uptime: uptime, servers: servers)
        }
        .help(VibeServerMenuFormat.entryTitle(server, uptime: uptime)
              + (opensInBrowser ? "\nClick to open http://localhost:\(port)" : ""))
    }
}

/// The per-server actions, shared by the ellipsis menu and the context menu.
private struct ServerActions: View {
    let server: LocalServerProcess
    let uptime: String
    let servers: LocalServerScanService

    var body: some View {
        let port = server.primaryPort
        // Same rule as `server.isLikelyHTTP` — routed through the one shared implementation on
        // LocalServerProcess so the panel never drifts from the tab.
        if VibeMenuBarActions.isLikelyHTTPPort(port) {
            Button {
                VibeMenuBarActions.openInBrowser(port: port)
            } label: {
                Label {
                    Text(verbatim: "Open http://localhost:\(port)")
                } icon: {
                    Image(systemName: "safari")
                }
            }
        }

        Button {
            VibeMenuBarActions.copyCommand(server)
        } label: {
            Label("Copy command", systemImage: "doc.on.doc")
        }

        if server.ports.count > 1 {
            Button {} label: {
                Text(verbatim: "Ports \(VibeServerMenuFormat.portList(server))")
            }
            .disabled(true)
        }

        // .selfApp is never killable — VibeWindowManager will not offer to signal itself.
        if server.category.isKillable {
            Divider()

            Button {
                if VibeMenuBarActions.confirmKill(server, force: false, uptime: uptime) {
                    servers.terminate(server, force: false)
                }
            } label: {
                Label("Quit process (SIGTERM)", systemImage: "stop.circle")
            }

            Button(role: .destructive) {
                if VibeMenuBarActions.confirmKill(server, force: true, uptime: uptime) {
                    servers.terminate(server, force: true)
                }
            } label: {
                Label("Force kill (SIGKILL)", systemImage: "xmark.octagon")
            }
        }
    }
}

// MARK: - Building blocks

private struct DisclosureHeader: View {
    let title: String
    let count: Int
    @Binding var isExpanded: Bool
    var isNested = false

    @State private var isHovering = false

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 18)
                Text(verbatim: title)
                    .font(isNested ? .callout : .callout.weight(.semibold))
                    .foregroundStyle(isNested ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                Text(verbatim: String(count))
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.quaternary))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PanelMetrics.rowInset)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .hoverHighlight(isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct PanelActionRow: View {
    let title: String
    let symbol: String
    var shortcut: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(verbatim: title)
                    .font(.callout)
                Spacer(minLength: 4)
                if let shortcut {
                    Text(verbatim: shortcut)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(PanelRowButtonStyle())
    }
}

private struct PanelToggleRow: View {
    let title: String
    let symbol: String
    @Binding var isOn: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Tapping the label flips the switch too; the gesture stays off the Toggle itself so a
            // click on the switch never toggles twice.
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                Text(verbatim: title)
                    .font(.callout)
                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
            .onTapGesture { isOn.toggle() }

            Toggle(isOn: $isOn) { Text(verbatim: title) }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, PanelMetrics.rowInset)
        .padding(.vertical, 5)
        .hoverHighlight(isHovering)
        .onHover { isHovering = $0 }
    }
}

private struct PanelIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.primary.opacity(isHovering ? 0.1 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

private struct PanelRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PanelRowButtonBody(configuration: configuration)
    }
}

private struct PanelRowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .padding(.horizontal, PanelMetrics.rowInset)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : (isHovering && isEnabled ? 0.08 : 0)))
            )
            .opacity(isEnabled ? 1 : 0.5)
            .onHover { isHovering = $0 }
    }
}

private extension View {
    func hoverHighlight(_ isHovering: Bool) -> some View {
        background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.08 : 0))
        )
    }
}

// MARK: - Hosting window access

/// Reference holder so recording the window never triggers a view update.
private final class PanelWindowBox {
    weak var window: NSWindow?
}

private struct PanelWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowReportingView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowReportingView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}

// MARK: - Preview

#Preview("Menu bar panel") {
    let service = UsageLimitsService(fetchers: [:])
    let now = Date()
    service.setForPreview(
        claude: ProviderUsage(
            provider: .claude, planName: "Max",
            windows: [
                UsageWindow(label: "Session", usedPercent: 42, resetsAt: now.addingTimeInterval(2 * 3600 + 14 * 60)),
                UsageWindow(label: "Weekly", usedPercent: 18, resetsAt: now.addingTimeInterval(4 * 86400)),
            ],
            fetchedAt: now, errorMessage: nil
        ),
        codex: ProviderUsage(
            provider: .codex, planName: "Pro",
            windows: [UsageWindow(label: "Weekly", usedPercent: 91, resetsAt: now.addingTimeInterval(-60))],
            fetchedAt: now, errorMessage: "Session limit unavailable — sign in to Codex CLI."
        ),
        lastRefreshed: now.addingTimeInterval(-70)
    )
    return MenuBarPanelView(mainWindowID: "preview", usage: service)
        .environmentObject(VibeBridgeServer())
}
