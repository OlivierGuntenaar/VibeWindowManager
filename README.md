# VibeWindowManager

**VibeWindowManager** is a macOS app and command-line tool for managing window layout and focus—tailored for terminal-heavy setups (e.g. **Ghostty** column splits, app grids, cascade layouts). A **bridge** on your Mac streams live window geometry to a companion [iOS app](https://github.com/Tguntenaar/VibeWindowManagerIOS) so you can see and control layout from an iPhone or iPad on the same network.

## Highlights

- **Layout engine** — Arrange and mirror windows for supported apps; focus and cycle windows from the app or CLI.
- **LAN / Tailnet bridge** — WebSocket server (default `19842`, path `/bridge`) with **Bonjour** discovery (`_vibewm._tcp`) and optional **Tailscale MagicDNS** for off-LAN or split-network setups.
- **Accessibility** — Uses macOS Accessibility APIs; grant permissions when prompted.
- **Command-line** — `windows` (and related) subcommands; see the docs below.

v1 targets a **trusted network** (home/small office). For hardening, treat future `wss://` and pairing as follow-ups.

## Requirements

- **macOS** with a recent **Xcode** (open `VibeWindowManager.xcodeproj`).
- For Ghostty- or app-specific features, have those apps installed as needed.
- For **Tailnet** from iOS, run **Tailscale** on the Mac (CLI or app) so the bridge UI can show this machine’s **MagicDNS** hostname. The iOS app connects with that hostname or with **manual `IP:port`**; it does not use Bonjour. The Mac still advertises `_vibewm._tcp` for other use.

## Quick start (bridge + iOS)

1. Open the project in Xcode, build, and run the **VibeWindowManager** app.
2. Turn on the **iOS layout bridge** in the app (default app query, port `19842`).
3. On your iPhone or iPad, install and run **[VibeWindowManagerIOS](https://github.com/Tguntenaar/VibeWindowManagerIOS)**. Connect with **Connect via Tailnet** (MagicDNS name) or **manual** `100.x.x.x:19842` / LAN `IP:19842`.
4. Grant **local network** access on iOS if the system prompt appears.

### tmux buffer on iPad (optional)

To **read terminal text** on the phone/tablet (not just window outlines), run your shell **inside tmux** on the Mac (e.g. Ghostty → `tmux new -s dev`). In the Mac Vibe app, set **tmux target** to a pane spec that `tmux list-panes -a` would accept (examples: `dev`, `dev:0.0`, `0`). On iOS, while mirroring, open the **tmux** button (text icon): **Refresh** fetches a snapshot; **Auto (2s)** polls the Mac. The server runs `tmux capture-pane` with your line/byte limits (see `docs/PROTOCOL.md`).

`windows bridge-dump <app>` prints the same `layout` JSON the bridge sends (useful for debugging).

## Documentation

| Doc | Description |
|-----|-------------|
| [`docs/CLI.md`](docs/CLI.md) | `VibeWindowManager` / `windows` commands |
| [`docs/PROTOCOL.md`](docs/PROTOCOL.md) | WebSocket message types (bridge protocol) |
| [`docs/RESEARCH_GHOSTTY_PHONE_REMOTE.md`](docs/RESEARCH_GHOSTTY_PHONE_REMOTE.md) | Design notes: transport, where speech-to-text runs, phased work |

**Where to implement what:** add **server** behavior (bridge, Bonjour, STT) in this repo. Add **iOS client** features in the [iOS repository](https://github.com/Tguntenaar/VibeWindowManagerIOS). Shared message shapes belong in the protocol doc first, then in code.

## Related repository

- **[VibeWindowManagerIOS](https://github.com/Tguntenaar/VibeWindowManagerIOS)** — Remote layout map, window selection, and connect UI for iPhone / iPad.

If you have both projects cloned as siblings, paths like `../VibeWindowManagerIOS` match that layout.

## Phone and SSH

Open **Phone & SSH** to enable this Mac’s private Tailscale terminal gateway, pair an iPhone with a two-minute QR code, import named aliases from `~/.ssh/config`, and revoke paired devices. **Use Mac mini** manages the mini gateway through the existing SSH connection. The phone can switch between paired Macs and import aliases itself. Keys remain on the Mac making each SSH connection. The laptop must stay awake for laptop-hosted sessions; use the mini for sessions that should survive closing the laptop.

The runtime is packaged from the sibling iOS repository with `python3 ../VibeWindowManagerIOS/server/bundle_desktop.py`. See that repository’s `server/README.md` for protocol and setup details.

## Share a desktop test build

Run `python3 scripts/build-release.py 1.0.2 5` to build a universal Mac DMG with
Sparkle updates. No paid Apple developer account is needed for this unnotarized
test build. See [shipping and updates](docs/SHIPPING.md) for installation, release
publishing, and protecting the update signing key.

The menu-bar usage panel includes Claude, Codex, Cursor, and Grok Bot. Claude shows the
Pro/Max subscription allowance using the **Claude desktop app's** own sign-in: no Claude
Code CLI login and no terminal. Vibe decrypts the desktop app's token cache with its
"Claude Safe Storage" Keychain key, read through Apple's `security` tool. The first time,
choose **Reconnect Claude** on the Usage page and click **Always Allow**; later refreshes
are silent, including after Vibe updates. Access is read-only: Vibe never renews, revokes
or rewrites the token (the desktop app renews its own sign-in, which lasts weeks), and it
only uses the narrowest-scoped `api.anthropic.com` token for the app's current account.
Usage refreshes are shared and cached for at least five minutes. Rate limits honor
`Retry-After` and use increasing cooldowns that survive relaunches.

Cursor reads its local login from its SQLite settings database (read-only). Newer
Cursor versions encrypt that token; Vibe instead uses an existing Cursor Agent CLI
login after verifying its account matches Cursor and its token is still valid.
Keychain reads require existing Apple-tool trust and never request approval in the
background. Vibe never decrypts the desktop token, renews the CLI login, or logs tokens.

Cursor's Auto/API pools and Grok Bot's weekly allowance have separate cards. Unified
plans identify their weekly allowance as shared. Grok Bot uses the matching active
account; a recent local usage snapshot is a timestamped fallback for other accounts,
team sessions, or network failures. Expired snapshots are not shown as current usage.
The DashboardService calls share a five-minute cache and persisted rate-limit
backoff that honors `Retry-After`, including across app restarts. These are internal
app APIs and storage formats, so future changes may require an update.

Reduce Motion is available in the menu-bar panel, the VibeWindowManager app menu,
and the main window’s sidebar. All three control the macOS setting and track changes
made in System Settings. Vibe also suppresses its own animated transitions while
Reduce Motion is enabled. macOS protects direct preference writes, so the app runs
Apple’s built-in action through the bundled, signed **Vibe Toggle Reduce Motion**
shortcut. On a new Mac, use **Set Up…** once and add that shortcut in Shortcuts.
Subsequent clicks run it in the background. Launching Vibe never changes the setting.

## Usage meters

The menu-bar panel shows providers with a usable usage meter. Choose **Manage usage…**
or **Show Window → Usage** for all provider connection messages, setup, and refresh controls.
Usage comes from signed-in accounts; an app does not need to stay open for its meter to appear.

Cursor's encrypted desktop login alone is not readable by Window Manager. Sign in to
**Cursor Agent (the CLI)** with the same account, then use **Reconnect Cursor** on the Usage page.
Only this explicit action may request Keychain access; automatic refresh stays silent.
Window Manager does not decrypt or rewrite Cursor's login store.

Grok Bot can supply its own fresh, account-scoped usage snapshot (cache schemas 2 and 3).
Open Grok Bot's usage panel to create or update that snapshot. Expired snapshots are ignored.
