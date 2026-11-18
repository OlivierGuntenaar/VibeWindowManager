//
//  AwayRemoteDesktopView.swift
//  VibeWindowManager
//
//  away-from-desk: copyable VNC (Screen Sharing) URLs for iPhone/iPad clients.
//  The Mac remains the source of truth; the phone is a remote display + use the
//  iOS bridge tab for layout mirror and mic/Whisper.
//

import AppKit
import SwiftUI

/// Default TCP port for macOS Screen Sharing (VNC).
private enum VNCEndpoint {
    static let port = 5900

    static func urlString(host: String) -> String {
        "vnc://\(host):\(port)"
    }
}

struct AwayRemoteDesktopView: View {
    /// First enumerated LAN IPv4 (same source as the bridge tab).
    let primaryLANAddress: String?
    let tailnetSelf: TailscaleSelfStatus?
    let tailnetChecked: Bool
    let onRefresh: () -> Void
    let onCopy: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Connections")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Button(action: onRefresh) {
                        Label("Refresh network", systemImage: "arrow.clockwise")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.bordered)
                    .help("Refresh network addresses")
                }

                copyRowsCard
                vncPrerequisitesCard
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var vncPrerequisitesCard: some View {
        DisclosureGroup("Connection setup") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Enable Screen Sharing on this Mac.")
                Button("Sharing settings…") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preferences.sharing?") {
                        NSWorkspace.shared.open(u)
                    }
                }
                .buttonStyle(.borderedProminent)
                Text("Paste a connection URL into a VNC app on your phone or tablet. Sign in with your Mac username and password.")
                Text("For a manual connection, use the host above and port \(VNCEndpoint.port). Keep Tailscale connected on both devices when away from home.")
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            VibeCardSurface()
        }
    }

    private var copyRowsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            vncRow(
                title: "Tailscale",
                unavailableMessage: tailnetChecked ? "Connect Tailscale or use the local network." : "Checking…",
                hostForURL: tailnetHost,
                systemImage: "network.badge.shield.half.filled",
                tint: .green
            )
            vncRow(
                title: "Local network",
                unavailableMessage: "No local address found.",
                hostForURL: primaryLANAddress,
                systemImage: "wifi",
                tint: .secondary
            )
            if let ip = tailnetSelf?.ipv4, !ip.isEmpty, ip != tailnetHost {
                DisclosureGroup("Alternate address") {
                    vncRow(
                        title: "Tailscale IP",
                        unavailableMessage: "No Tailscale IP found.",
                        hostForURL: ip,
                        systemImage: "link",
                        tint: .secondary
                    )
                    .padding(.top, 8)
                }
                .help("Use the IP address if the Tailscale hostname won’t connect.")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            VibeCardSurface()
        }
    }

    private var tailnetHost: String? {
        guard let s = tailnetSelf else { return nil }
        let h = s.dnsName.isEmpty ? s.hostName : s.dnsName
        return h.isEmpty ? s.ipv4 : h
    }

    @ViewBuilder
    private func vncRow(
        title: String,
        unavailableMessage: String,
        hostForURL: String?,
        systemImage: String,
        tint: Color
    ) -> some View {
        let vnc = hostForURL.map { VNCEndpoint.urlString(host: $0) }
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                if let u = vnc {
                    Text(u)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                } else {
                    Text(unavailableMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let u = vnc {
                Button {
                    onCopy(u)
                } label: {
                    Label("Copy \(title) URL", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Copy VNC URL")
            } else {
                Color.clear
                    .frame(width: 28, height: 28)
            }
        }
    }
}
