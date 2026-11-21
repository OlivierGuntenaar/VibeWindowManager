#!/usr/bin/env python3
"""Build a universal, ad-hoc-signed DMG and a signed Sparkle feed. No upload."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
from release_validation import validate_app, validate_artifacts, validate_config, write_provenance

ROOT = Path(__file__).resolve().parents[1]
CONFIG = json.loads((ROOT / "scripts/release-config.json").read_text())


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], cwd=ROOT, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", help="Display version, e.g. 1.0.1")
    parser.add_argument("build", type=int, help="Positive, strictly increasing build number")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]+(?:\.[0-9]+){0,2}", args.version) or args.build < 1:
        parser.error("Use a numeric version and a positive build number")
    validate_config(CONFIG)
    tag = f"v{args.version}-{args.build}"
    output = ROOT / "build/releases" / tag
    if output.exists():
        parser.error(f"Output already exists: {output}. Use a new build number.")
    packages = ROOT / "build/SourcePackages"
    run("xcodebuild", "-resolvePackageDependencies", "-project", "VibeWindowManager.xcodeproj",
        "-scheme", "VibeWindowManager", "-clonedSourcePackagesDirPath", packages)
    tools = packages / "artifacts/sparkle/Sparkle/bin"
    public_key = run(tools / "generate_keys", "--account", CONFIG["keychainAccount"], "-p",
                     capture_output=True, text=True).stdout.strip()
    if public_key != CONFIG["publicKey"]:
        raise SystemExit("Signing key mismatch. Restore the original release key; do not rotate it casually.")
    derived = ROOT / "build/DerivedData"
    run("xcodebuild", "-project", "VibeWindowManager.xcodeproj", "-scheme", "VibeWindowManager",
        "-configuration", "Release", "-derivedDataPath", derived,
        "-clonedSourcePackagesDirPath", packages, "-destination", "generic/platform=macOS",
        "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO", "CODE_SIGN_IDENTITY=-",
        "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=", "ENABLE_HARDENED_RUNTIME=NO",
        f"MARKETING_VERSION={args.version}", f"CURRENT_PROJECT_VERSION={args.build}", "build")
    output.mkdir(parents=True)
    staging = output / "staging"
    staging.mkdir()
    app = staging / "VibeWindowManager.app"
    run("ditto", derived / "Build/Products/Release/VibeWindowManager.app", app)
    plist_path = app / "Contents/Info.plist"
    with plist_path.open("rb") as f:
        plist = plistlib.load(f)
    plist.update({
        "VibeEnableUpdater": True,
        "SUFeedURL": f'https://github.com/{CONFIG["repository"]}/releases/latest/download/appcast.xml',
        "SUPublicEDKey": CONFIG["publicKey"],
        "SUEnableAutomaticChecks": True,
        "SUAutomaticallyUpdate": False,
        "SURequireSignedFeed": True,
        "SUVerifyUpdateBeforeExtraction": True,
    })
    with plist_path.open("wb") as f:
        plistlib.dump(plist, f)
    validate_app(app, CONFIG, tag)
    # Changing Info.plist invalidates the outer signature. Nested frameworks retain
    # the signatures produced/preserved by Xcode. No personal signing identity needed.
    run("codesign", "--force", "--sign", "-", "--timestamp=none", app)
    run("codesign", "--verify", "--deep", "--strict", app)
    architectures = run("lipo", "-archs", app / "Contents/MacOS/VibeWindowManager",
                        capture_output=True, text=True).stdout.split()
    if not {"arm64", "x86_64"}.issubset(architectures):
        raise SystemExit("Release is missing a required Mac architecture")
    (staging / "Applications").symlink_to("/Applications")
    (staging / "READ ME.txt").write_text(
        "VibeWindowManager — family test build\n\n"
        "Requires macOS 26.2 or newer. Supports Apple Silicon and Intel.\n"
        "Drag VibeWindowManager into Applications, then open it from there.\n"
        "This build is not notarized. If macOS blocks it, open System Settings >\n"
        "Privacy & Security > Open Anyway after trying to launch the app.\n"
        "Grant Accessibility for window control; Screen Recording for previews.\n"
        "Sign into the Claude app, Cursor, and Codex on YOUR Mac for usage limits.\n"
        "Updates are checked automatically; you choose when to install them.\n"
        "Use Check for Updates in the app menu or menu-bar panel.\n")
    dmg = output / f"VibeWindowManager-{args.version}-{args.build}.dmg"
    run("hdiutil", "create", "-volname", "VibeWindowManager", "-srcfolder", staging,
        "-format", "UDZO", dmg)
    run("hdiutil", "verify", dmg)
    run(tools / "generate_appcast", "--account", CONFIG["keychainAccount"],
        "--download-url-prefix", f'https://github.com/{CONFIG["repository"]}/releases/download/{tag}/',
        "--maximum-deltas", "0", output)
    run(tools / "sign_update", "--account", CONFIG["keychainAccount"], "--verify", output / "appcast.xml")
    digest = hashlib.sha256(dmg.read_bytes()).hexdigest()
    (output / "SHA256SUMS").write_text(f"{digest}  {dmg.name}\n")
    (output / "release-notes.md").write_text(
        f"VibeWindowManager {args.version} (build {args.build})\n\n"
        "- Direct-download installer for Apple Silicon and Intel Macs.\n"
        "- Signed Sparkle updates; choose when to install.\n"
        "- Cursor Auto/API usage limits alongside Claude and Codex.\n\n"
        "Requires macOS 26.2+. This family test build is not Apple-notarized.\n"
        "After installing, use Privacy & Security → Open Anyway if macOS blocks launch.\n")
    provenance = write_provenance(ROOT, output, tag)
    with (output / "release-notes.md").open("a") as notes:
        notes.write(f"\nBuilt from local checkout at {provenance['commit']} "
                    f"(uncommitted changes: {provenance['dirty']}).\n"
                    f"Source input SHA-256: {provenance['sourceSHA256']}. "
                    "See provenance.json for exact input hashes.\n")
    validate_artifacts(output, CONFIG, tag)
    print(f"\nReady to share: {dmg}\nPublish when ready: python3 scripts/publish-release.py {tag}")


if __name__ == "__main__":
    main()
