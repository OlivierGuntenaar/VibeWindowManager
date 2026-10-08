#!/usr/bin/env python3
"""Publish an already-built release to the configured public GitHub repository."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
from release_validation import parse_tag, validate_artifacts, validate_app, validate_build

ROOT = Path(__file__).resolve().parents[1]
CONFIG = json.loads((ROOT / 'scripts/release-config.json').read_text())


def publish(tag):
    parse_tag(tag)
    release = ROOT / 'build/releases' / tag
    feed = release / 'appcast.xml'
    dmg, signature = validate_artifacts(release, CONFIG, tag)
    tools = ROOT / 'build/SourcePackages/artifacts/sparkle/Sparkle/bin'
    subprocess.run([str(tools / 'sign_update'), '--account', CONFIG['keychainAccount'],
                    '--verify', str(feed)], check=True)
    subprocess.run([str(tools / 'sign_update'), '--account', CONFIG['keychainAccount'],
                    '--verify', str(dmg), signature], check=True)
    subprocess.run(['hdiutil', 'verify', str(dmg)], check=True)
    with tempfile.TemporaryDirectory(prefix='vibe-release-') as mount:
        subprocess.run(['hdiutil', 'attach', str(dmg), '-readonly', '-nobrowse',
                        '-mountpoint', mount], check=True)
        try:
            app = Path(mount) / 'VibeWindowManager.app'
            validate_app(app, CONFIG, tag)
            subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
        finally:
            subprocess.run(['hdiutil', 'detach', mount], check=True)
    # Paginate: an older release outside the first page must not bypass monotonicity.
    pages = json.loads(subprocess.check_output([
        'gh', 'api', '--paginate', '--slurp',
        f'repos/{CONFIG["repository"]}/releases?per_page=100'], text=True))
    validate_build([{'tagName': item['tag_name']} for page in pages for item in page], tag)
    subprocess.run(['gh', 'release', 'create', tag, str(dmg), str(feed),
                    str(release / 'SHA256SUMS'), str(release / 'provenance.json'), '--repo', CONFIG['repository'],
                    '--title', f'VibeWindowManager {tag}',
                    '--notes-file', str(release / 'release-notes.md'), '--latest'], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('tag')
    args = parser.parse_args()
    try:
        publish(args.tag)
    except ValueError as error:
        parser.error(str(error))


if __name__ == '__main__':
    main()
