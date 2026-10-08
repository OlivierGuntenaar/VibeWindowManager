# Direct distribution and updates

VibeWindowManager is a native macOS app distributed directly as a DMG. The
window-control target is not sandboxed. Test builds require no paid Apple account.

## Build a family test installer

Requirements: Xcode, Python 3, and the original Sparkle release key in your login
Keychain. The build supports Apple Silicon and Intel and currently requires macOS
26.2 or newer.

```sh
python3 scripts/build-release.py 1.0.2 5
```

Use a new, strictly increasing build number for every release; Sparkle compares
that number, not just the display version. Outputs live in
`build/releases/v1.0.2-5/`:

- `VibeWindowManager-1.0.2-5.dmg` — share this file.
- `appcast.xml` — signed update feed, with a signed DMG enclosure.
- `SHA256SUMS` and `release-notes.md`.

The script checks the release key, builds both architectures, enables Sparkle in
the packaged app, applies an ad-hoc signature, verifies the app and DMG, and signs
the update archive/feed. It refuses to overwrite an existing output directory.
Regular Xcode development builds do not start the updater.

The test build disables Hardened Runtime because ad-hoc signing cannot satisfy
its library validation for the embedded Sparkle framework. Normal project settings
retain Hardened Runtime. A future Developer ID distribution script should retain
it, sign the nested code correctly, notarize, and staple before packaging/signing
updates. Do not use this test script for a notarized release.

## Install

1. Open the DMG and drag the app into Applications.
2. Open the app from Applications. If macOS blocks this unnotarized build, use
   System Settings → Privacy & Security → Open Anyway after attempting launch.
3. Grant Accessibility for window control and Screen Recording for previews.
4. Sign in to Cursor, Claude Code, and Codex locally to populate their usage cards.

Xcode is not required on the recipient's Mac. No developer credentials or local
usage credentials are bundled. With ad-hoc signing, macOS may require granting
Accessibility/Screen Recording again after replacing the app with an update.

## Publish updates

The configured public repository is `Tguntenaar/VibeWindowManager`. Review the DMG
and `release-notes.md` before publishing. Publishing makes the binary publicly
downloadable, even if you only send the link to family.

```sh
python3 scripts/publish-release.py v1.0.2-5
```

This checks the checksum, archive signature, feed signature, download URL and build
number before creating a GitHub release and marking it latest. It does not commit
or push your local source changes. The release tag is created against GitHub's
current default branch; commit/push the intended source before publishing when
source-to-release traceability is required.

Sparkle reads:

`https://github.com/Tguntenaar/VibeWindowManager/releases/latest/download/appcast.xml`

That URL becomes available only after the first release is published. Before then,
the DMG is installable, but update checks cannot reach a published feed. Users can
check manually from the app menu or menu-bar panel. Packaged builds check
automatically and ask before installing; they require valid Ed25519 signatures for
both feed and downloads. Each feed points at the immutable version-specific DMG.

## Protect the update key

The public key and Keychain account name live in `scripts/release-config.json`.
The private key is stored only in the macOS login Keychain, in Sparkle's signing
key entry for account `com.thomasguntenaar.VibeWindowManager`. Keep a secure backup:
losing it means existing installations cannot trust subsequent updates. Never put
the private key in Git, the DMG, or release assets. On another release machine,
restore that same key using Sparkle's `generate_keys` export/import tools.

See [Sparkle setup](https://sparkle-project.org/documentation/) and
[Apple's unnotarized-app instructions](https://support.apple.com/en-gb/102445).

## Release validation and tests

Run the complete Xcode suite (unit and UI tests) with local ad-hoc signing:

```sh
xcodebuild -project VibeWindowManager.xcodeproj -scheme VibeWindowManager \
  -configuration Debug -derivedDataPath build/TestDerivedData \
  -clonedSourcePackagesDirPath build/SourcePackages \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  ENABLE_HARDENED_RUNTIME=NO test
python3 -m unittest discover -s scripts/tests -v
python3 -m unittest discover -s tests -p 'test_*.py' -v
```

Swift tests cover Cursor parsing, credentials, offline HTTP outcomes, independent
provider refreshes, formatting boundaries, and real Sparkle startup validation.
The release-script suite rejects tampered artifacts, incorrect versions/URLs,
missing security settings, and non-increasing builds before publication.
The Sparkle integration suite serves signed feeds on loopback and uses the actual
framework to test newer/same/older versions, OS eligibility, and rejection of
unsigned, tampered, or malformed feeds. It uses temporary test signing keys and requires resolved Sparkle tools; it
does not access the release signing key or Keychain. It never installs an update or changes the
installed app's settings.

Each new release includes `provenance.json`: source commit, whether the checkout
was dirty, hashes of source inputs, and the DMG digest. This records local changes
without committing or publishing unrelated work-in-progress source files.
