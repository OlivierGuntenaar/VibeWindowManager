"""Fail-closed release metadata validation shared by build and publication."""
import base64
import hashlib
import json
import subprocess
import plistlib
import re
import xml.etree.ElementTree as ET

SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
TAG = re.compile(r'v([0-9]+(?:\.[0-9]+){0,2})-([1-9][0-9]*)')


def parse_tag(tag):
    match = TAG.fullmatch(tag)
    if not match:
        raise ValueError('Expected a tag such as v1.0.1-2')
    return match[1], int(match[2])


def validate_config(config):
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', config['repository']):
        raise ValueError('Invalid release repository')
    if len(base64.b64decode(config['publicKey'], validate=True)) != 32:
        raise ValueError('Invalid Sparkle public key')
    if not config['keychainAccount']:
        raise ValueError('Missing signing account')


def validate_app(app, config, tag):
    version, build = parse_tag(tag)
    with (app / 'Contents/Info.plist').open('rb') as handle:
        info = plistlib.load(handle)
    required = {
        'CFBundleIdentifier': 'com.thomasguntenaar.VibeWindowManager',
        'LSMinimumSystemVersion': '26.2',
        'CFBundleShortVersionString': version,
        'CFBundleVersion': str(build),
        'SUPublicEDKey': config['publicKey'],
        'SUFeedURL': f'https://github.com/{config["repository"]}/releases/latest/download/appcast.xml',
        'VibeEnableUpdater': True,
        'SUEnableAutomaticChecks': True,
        'SUAutomaticallyUpdate': False,
        'SURequireSignedFeed': True,
        'SUVerifyUpdateBeforeExtraction': True,
    }
    for key, value in required.items():
        if type(info.get(key)) is not type(value) or info.get(key) != value:
            raise ValueError(f'Invalid application release metadata: {key}')


def validate_artifacts(release, config, tag):
    validate_config(config)
    version, build = parse_tag(tag)
    dmgs = list(release.glob('*.dmg'))
    expected_name = f'VibeWindowManager-{version}-{build}.dmg'
    if len(dmgs) != 1 or dmgs[0].name != expected_name:
        raise ValueError('Expected exactly one DMG with the release version')
    dmg = dmgs[0]
    checksum = f'{hashlib.sha256(dmg.read_bytes()).hexdigest()}  {dmg.name}\n'
    if (release / 'SHA256SUMS').read_text() != checksum:
        raise ValueError('DMG checksum mismatch or incorrect filename')
    if not (release / 'release-notes.md').read_text().strip():
        raise ValueError('Missing release notes')
    items = ET.parse(release / 'appcast.xml').findall('./channel/item')
    if len(items) != 1:
        raise ValueError('Expected exactly one feed item')
    if items[0].findtext(SPARKLE + 'minimumSystemVersion') != '26.2':
        raise ValueError('Incorrect feed minimum macOS version')
    enclosures = items[0].findall('enclosure')
    if len(enclosures) != 1:
        raise ValueError('Expected exactly one update enclosure')
    enclosure = enclosures[0]
    expected_url = f'https://github.com/{config["repository"]}/releases/download/{tag}/{dmg.name}'
    if enclosure.get('url') != expected_url:
        raise ValueError('Feed does not point to the configured release')
    for key, expected in [('version', str(build)), ('shortVersionString', version)]:
        # Sparkle emits version metadata as item children in newer versions.
        actual = items[0].findtext(SPARKLE + key) or enclosure.get(SPARKLE + key)
        if actual != expected:
            raise ValueError(f'Incorrect feed {key}')
    if enclosure.get('length') != str(dmg.stat().st_size):
        raise ValueError('Incorrect update length')
    signature = enclosure.get(SPARKLE + 'edSignature', '')
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError('Missing or invalid update signature')
    validate_provenance(release, tag, dmg)
    return dmg, signature


def validate_build(existing, tag):
    _, build = parse_tag(tag)
    for item in existing:
        match = TAG.fullmatch(item['tagName'])
        if match and int(match[2]) >= build:
            raise ValueError('Build number must exceed all existing releases')


def write_provenance(root, release, tag):
    """Record the exact tracked/untracked source inputs without collecting build outputs."""
    version, build = parse_tag(tag)
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip()
    dirty = bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=root, text=True).strip())
    paths = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=root).decode().split('\0')
    inputs = {}
    for name in sorted(set(paths)):
        path = root / name
        if not name or name.startswith(('build/', '.git/')) or name.endswith(('.profraw', '.pyc')) or '__pycache__/' in name:
            continue
        if path.is_file():
            inputs[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    source_digest = hashlib.sha256(json.dumps(inputs, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    dmg = release / f'VibeWindowManager-{version}-{build}.dmg'
    manifest = {'commit': commit, 'dirty': dirty, 'sourceSHA256': source_digest,
                'inputs': inputs, 'version': version, 'build': build, 'tag': tag,
                'artifact': dmg.name, 'artifactSHA256': hashlib.sha256(dmg.read_bytes()).hexdigest()}
    (release / 'provenance.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    return manifest


def validate_provenance(release, tag, dmg):
    version, build = parse_tag(tag)
    manifest = json.loads((release / 'provenance.json').read_text())
    expected = {'version': version, 'build': build, 'tag': tag, 'artifact': dmg.name,
                'artifactSHA256': hashlib.sha256(dmg.read_bytes()).hexdigest()}
    for key, value in expected.items():
        if type(manifest.get(key)) is not type(value) or manifest.get(key) != value:
            raise ValueError(f'Invalid provenance: {key}')
    if not re.fullmatch(r'[0-9a-f]{40,64}', manifest.get('commit', '')) or type(manifest.get('dirty')) is not bool:
        raise ValueError('Invalid source revision provenance')
    inputs = manifest.get('inputs')
    if not isinstance(inputs, dict) or not inputs:
        raise ValueError('Missing source provenance inputs')
    digest = hashlib.sha256(json.dumps(inputs, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    if manifest.get('sourceSHA256') != digest:
        raise ValueError('Source provenance hash mismatch')
