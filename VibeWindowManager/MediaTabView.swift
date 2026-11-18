//
//  MediaTabView.swift
//  VibeWindowManager
//
//  Media key forwarding + AirPods → Spotify redirect controls.
//

import SwiftUI

struct MediaTabView: View {
    @ObservedObject var media: MediaControlService
    @AppStorage("vibeMediaKeysEnabled") private var mediaKeysEnabled: Bool = false
    @AppStorage("vibeMusicRedirectEnabled") private var musicRedirectEnabled: Bool = false
    @AppStorage("vibeAirPodsCaptureEnabled") private var airPodsCaptureEnabled: Bool = false
    @AppStorage("vibeF5NoiseToggleEnabled") private var f5NoiseToggleEnabled: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Spotify & AirPods")
                    .font(.title2.weight(.semibold))

                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Media keys → Spotify", isOn: $mediaKeysEnabled)
                        .toggleStyle(.switch)
                        .help("Play, pause, skip, and go back in Spotify. Play also opens Spotify if it’s closed.")

                    if mediaKeysEnabled && !media.accessibilityTrusted {
                        Label("Allow Accessibility in System Settings, then turn media keys off and on.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .help("System Settings → Privacy & Security → Accessibility")
                    }

                    Divider()

                    Toggle("AirPods clicks → Spotify", isOn: $airPodsCaptureEnabled)
                        .toggleStyle(.switch)
                        .help("An AirPods stem click opens Spotify when it’s closed. Spotify handles clicks while it’s running.")

                    Divider()

                    Toggle(isOn: $musicRedirectEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Replace Apple Music with Spotify")
                                .font(.subheadline.weight(.medium))
                            Text("Quits Apple Music whenever it opens.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .help("Fallback if Apple Music still opens: quit it and start Spotify. Turn off to use Apple Music.")

                    Divider()

                    Toggle("F5: Noise Cancellation ↔ Transparency", isOn: $f5NoiseToggleEnabled)
                        .toggleStyle(.switch)
                        .help("Switch AirPods noise modes with F5. Without AirPods, F5 works normally.")

                    Divider()

                    Toggle("Open at login", isOn: $media.launchAtLogin)
                        .toggleStyle(.switch)
                        .help("Start Vibe automatically when you log in.")
                }
                .font(.subheadline.weight(.medium))
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardBackground)

                if let action = media.lastAction {
                    Text(action)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                DisclosureGroup("Status & troubleshooting") {
                    VStack(alignment: .leading, spacing: 10) {
                        statusRow(ok: media.mediaKeyTapActive, on: "Media keys active", off: "Media keys inactive")
                        statusRow(ok: media.accessibilityTrusted, on: "Accessibility allowed", off: "Accessibility needed")
                        statusRow(ok: media.spotifyRunning, on: "Spotify running", off: "Spotify closed")
                        if media.airPodsCaptureActive {
                            statusRow(ok: media.decoyHoldsNowPlaying, on: "AirPods ready to open Spotify", off: "Spotify handles AirPods")
                        }
                        if media.f5NoiseToggleActive, let mode = media.lastNoiseMode {
                            Text("Last F5 toggle: \(mode)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if media.musicRedirectCount > 0 {
                            Text("Blocked Apple Music \(media.musicRedirectCount)× this session")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Refresh") { media.refreshPermissions() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Text("If media keys conflict, quit MacMediaKeyForwarder and remove it from Login Items.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(cardBackground)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            media.refreshPermissions()
            media.setMediaKeysEnabled(mediaKeysEnabled)
            media.setMusicInterceptionEnabled(musicRedirectEnabled)
            media.setAirPodsCaptureEnabled(airPodsCaptureEnabled)
            media.setF5NoiseToggleEnabled(f5NoiseToggleEnabled)
        }
        .onChange(of: mediaKeysEnabled) { _, enabled in
            media.setMediaKeysEnabled(enabled)
        }
        .onChange(of: f5NoiseToggleEnabled) { _, enabled in
            media.setF5NoiseToggleEnabled(enabled)
        }
        .onChange(of: musicRedirectEnabled) { _, enabled in
            media.setMusicInterceptionEnabled(enabled)
        }
        .onChange(of: airPodsCaptureEnabled) { _, enabled in
            media.setAirPodsCaptureEnabled(enabled)
        }
    }

    private func statusRow(ok: Bool, on: String, off: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ok ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 10, height: 10)
            Text(ok ? on : off)
                .font(.subheadline)
                .foregroundStyle(ok ? .primary : .secondary)
        }
    }

    private var cardBackground: some View {
        VibeCardSurface()
    }
}
