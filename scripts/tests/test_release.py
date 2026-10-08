"""Offline release safety tests; only external executable calls are mocked."""
import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import release_validation as validation
spec = importlib.util.spec_from_file_location('publish_release', Path(__file__).resolve().parents[1] / 'publish-release.py')
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.tag = 'v1.2.3-8'
        self.config = dict(publisher.CONFIG)
        self.release = self.root / 'build/releases' / self.tag
        self.release.mkdir(parents=True)
        self.dmg = self.release / 'VibeWindowManager-1.2.3-8.dmg'
        self.dmg.write_bytes(b'fixture disk image')
        self.checksum()
        inputs = {'source.swift': 'a' * 64}
        self.manifest = {'commit': 'b' * 40, 'dirty': True,
                         'sourceSHA256': hashlib.sha256(json.dumps(inputs, sort_keys=True, separators=(',', ':')).encode()).hexdigest(),
                         'inputs': inputs, 'version': '1.2.3', 'build': 8, 'tag': self.tag,
                         'artifact': self.dmg.name, 'artifactSHA256': hashlib.sha256(self.dmg.read_bytes()).hexdigest()}
        self.save_manifest()
        (self.release / 'release-notes.md').write_text('Changes for testers')
        self.feed = ET.Element('rss')
        item = ET.SubElement(ET.SubElement(self.feed, 'channel'), 'item')
        self.item = item
        ET.SubElement(item, validation.SPARKLE + 'minimumSystemVersion').text = '26.2'
        self.enclosure = ET.SubElement(item, 'enclosure', {
            'url': f'https://github.com/{self.config["repository"]}/releases/download/{self.tag}/{self.dmg.name}',
            'length': str(self.dmg.stat().st_size),
            validation.SPARKLE + 'version': '8',
            validation.SPARKLE + 'shortVersionString': '1.2.3',
            validation.SPARKLE + 'edSignature': base64.b64encode(b's' * 64).decode(),
        })
        self.save_feed()
        self.info = {
            'CFBundleIdentifier': 'com.thomasguntenaar.VibeWindowManager',
            'LSMinimumSystemVersion': '26.2',
            'CFBundleShortVersionString': '1.2.3', 'CFBundleVersion': '8',
            'SUPublicEDKey': self.config['publicKey'],
            'SUFeedURL': f'https://github.com/{self.config["repository"]}/releases/latest/download/appcast.xml',
            'VibeEnableUpdater': True, 'SUEnableAutomaticChecks': True,
            'SUAutomaticallyUpdate': False, 'SURequireSignedFeed': True,
            'SUVerifyUpdateBeforeExtraction': True,
        }
        self.calls = []
        self.fail = None
        self.pages = [[{'tag_name': 'v1.2.2-7'}]]
        self.addCleanup(patch.stopall)
        patch.object(publisher, 'ROOT', self.root).start()
        patch.object(publisher, 'CONFIG', self.config).start()
        patch.object(publisher.subprocess, 'run', side_effect=self.run_external).start()
        patch.object(publisher.subprocess, 'check_output', side_effect=lambda *a, **kw: json.dumps(self.pages)).start()

    def save_manifest(self):
        (self.release / 'provenance.json').write_text(json.dumps(self.manifest))

    def checksum(self):
        (self.release / 'SHA256SUMS').write_text(f'{hashlib.sha256(self.dmg.read_bytes()).hexdigest()}  {self.dmg.name}\n')

    def save_feed(self):
        ET.ElementTree(self.feed).write(self.release / 'appcast.xml')

    def run_external(self, command, **kwargs):
        self.calls.append(command)
        self.assertTrue(kwargs.get('check'))
        if self.fail and self.fail(command):
            raise subprocess.CalledProcessError(1, command)
        if command[:2] == ['hdiutil', 'attach']:
            app = Path(command[-1]) / 'VibeWindowManager.app/Contents'
            app.mkdir(parents=True)
            (app / 'Info.plist').write_bytes(plistlib.dumps(self.info))
        return subprocess.CompletedProcess(command, 0)

    def rejected(self, tag=None):
        with self.assertRaises((ValueError, OSError, ET.ParseError, subprocess.CalledProcessError)):
            publisher.publish(tag or self.tag)
        self.assertFalse(any(c[:3] == ['gh', 'release', 'create'] for c in self.calls))

    def test_valid_publish(self):
        publisher.publish(self.tag)
        self.assertEqual(self.calls[-1][:4], ['gh', 'release', 'create', self.tag])
        self.assertIn(self.config['repository'], self.calls[-1])

    def test_modern_feed_child_versions(self):
        for key in ['version', 'shortVersionString']:
            ET.SubElement(self.item, validation.SPARKLE + key).text = self.enclosure.attrib.pop(validation.SPARKLE + key)
        self.save_feed()
        publisher.publish(self.tag)

    def test_feed_wrong_minimum_macos(self):
        self.item.find(validation.SPARKLE + 'minimumSystemVersion').text = '26.1'
        self.save_feed()
        self.rejected()

    def test_feed_missing_minimum_macos(self):
        self.item.remove(self.item.find(validation.SPARKLE + 'minimumSystemVersion'))
        self.save_feed()
        self.rejected()

    def test_checksum_tampering(self):
        self.dmg.write_bytes(b'tampered')
        self.rejected()

    def test_checksum_wrong_filename(self):
        p = self.release / 'SHA256SUMS'
        p.write_text(p.read_text().replace(self.dmg.name, 'wrong.dmg'))
        self.rejected()

    def test_extra_dmg(self):
        (self.release / 'extra.dmg').write_bytes(b'other')
        self.rejected()

    def test_wrong_dmg_version(self):
        self.dmg.rename(self.release / 'VibeWindowManager-1.2.4-8.dmg')
        self.rejected()

    def test_missing_dmg(self):
        self.dmg.unlink()
        self.rejected()

    def test_empty_notes(self):
        (self.release / 'release-notes.md').write_text(' ')
        self.rejected()

    def test_duplicate_feed_items(self):
        self.feed.find('channel').append(self.item)
        self.save_feed()
        self.rejected()

    def test_duplicate_enclosures(self):
        self.item.append(self.enclosure)
        self.save_feed()
        self.rejected()

    def test_malformed_feed(self):
        (self.release / 'appcast.xml').write_text('<broken')
        self.rejected()

    def test_monotonicity_checks_all_pages(self):
        self.pages.append([{'tag_name': 'v0.1-99'}])
        self.rejected()

    def test_same_build_other_version(self):
        self.pages = [[{'tag_name': 'v9.0-8'}]]
        self.rejected()

    def test_no_releases(self):
        self.pages = [[]]
        publisher.publish(self.tag)

    def test_unrelated_tags_ignored(self):
        self.pages = [[{'tag_name': 'experimental'}]]
        publisher.publish(self.tag)


def feed_test(key, value):
    def test(self):
        self.enclosure.set(key, value)
        self.save_feed()
        self.rejected()
    return test

for name, key, value in [
    ('wrong_host', 'url', 'https://evil.example/releases/download/v1.2.3-8/VibeWindowManager-1.2.3-8.dmg'),
    ('wrong_repo', 'url', 'https://github.com/other/repo/releases/download/v1.2.3-8/VibeWindowManager-1.2.3-8.dmg'),
    ('http', 'url', 'http://github.com/Tguntenaar/VibeWindowManager/releases/download/v1.2.3-8/VibeWindowManager-1.2.3-8.dmg'),
    ('wrong_version', validation.SPARKLE + 'version', '7'),
    ('wrong_display_version', validation.SPARKLE + 'shortVersionString', '1.2.4'),
    ('wrong_length', 'length', '999'),
    ('missing_signature', validation.SPARKLE + 'edSignature', ''),
    ('invalid_signature', validation.SPARKLE + 'edSignature', 'not-base64'),
    ('short_signature', validation.SPARKLE + 'edSignature', 'YQ=='),
]:
    setattr(ReleaseTests, 'test_feed_' + name, feed_test(key, value))


def app_test(key, value):
    def test(self):
        self.info[key] = value
        self.rejected()
        self.assertTrue(any(c[:2] == ['hdiutil', 'detach'] for c in self.calls))
    return test

for key, value in [
    ('CFBundleIdentifier', 'com.other.application'), ('LSMinimumSystemVersion', '26.1'),
    ('CFBundleVersion', '7'), ('CFBundleShortVersionString', '1.2.4'),
    ('SUPublicEDKey', 'wrong-key'), ('SUFeedURL', 'https://evil.example/appcast.xml'),
    ('VibeEnableUpdater', False), ('SUEnableAutomaticChecks', False),
    ('SUAutomaticallyUpdate', True), ('SURequireSignedFeed', False),
    ('SUVerifyUpdateBeforeExtraction', False), ('SURequireSignedFeed', 1),
]:
    setattr(ReleaseTests, 'test_app_' + key + '_' + str(value), app_test(key, value))


def failure_test(predicate):
    def test(self):
        self.fail = predicate
        self.rejected()
    return test

for name, predicate in {
    'feed_signature': lambda c: c[0].endswith('sign_update') and c[-1].endswith('appcast.xml'),
    'artifact_signature': lambda c: c[0].endswith('sign_update') and not c[-1].endswith('appcast.xml'),
    'dmg_verify': lambda c: c[:2] == ['hdiutil', 'verify'],
    'mount': lambda c: c[:2] == ['hdiutil', 'attach'],
    'codesign': lambda c: c[0] == 'codesign',
    'unmount': lambda c: c[:2] == ['hdiutil', 'detach'],
}.items():
    setattr(ReleaseTests, 'test_failure_' + name, failure_test(predicate))


def tag_test(tag):
    def test(self):
        self.rejected(tag)
        self.assertEqual(self.calls, [])
    return test

for index, tag in enumerate(['../../oops', 'v1.2.3-0', 'v1.2.3--1', 'v1.2.3-01', 'v1.2.3-8/evil', '--help', 'v1.2.3-8\n', 'v1.2.3.4-8']):
    setattr(ReleaseTests, f'test_unsafe_tag_{index}', tag_test(tag))

def provenance_test(key, value):
    def test(self):
        self.manifest[key] = value
        self.save_manifest()
        self.rejected()
    return test

for key, value in [('commit', 'invalid'), ('dirty', 'true'), ('build', 9), ('version', '2.0'),
                   ('tag', 'v1.2.3-9'), ('artifact', 'wrong.dmg'), ('artifactSHA256', '0' * 64),
                   ('sourceSHA256', '0' * 64), ('inputs', {})]:
    setattr(ReleaseTests, 'test_provenance_' + key, provenance_test(key, value))

class ProvenanceWriterTests(unittest.TestCase):
    def test_source_changes_change_digest_and_build_outputs_do_not(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            release = root / 'build/releases/v1.0-1'
            release.mkdir(parents=True)
            (release / 'VibeWindowManager-1.0-1.dmg').write_bytes(b'dmg')
            source = root / 'main.swift'
            source.write_text('first')
            profile = root / 'default.profraw'
            profile.write_text('profile')
            build_output = root / 'build/output'
            build_output.write_text('output')
            def external(command, **kwargs):
                if command[1] == 'rev-parse':
                    return 'a' * 40 + '\n'
                if command[1] == 'status':
                    return ' M main.swift\n'
                return b'main.swift\0default.profraw\0build/output\0'
            with patch.object(validation.subprocess, 'check_output', side_effect=external):
                first = validation.write_provenance(root, release, 'v1.0-1')
                validation.validate_provenance(release, 'v1.0-1', release / first['artifact'])
                self.assertEqual(list(first['inputs']), ['main.swift'])
                self.assertTrue(first['dirty'])
                profile.write_text('different profile')
                build_output.write_text('different output')
                second = validation.write_provenance(root, release, 'v1.0-1')
                self.assertEqual(first['sourceSHA256'], second['sourceSHA256'])
                source.write_text('changed code')
                third = validation.write_provenance(root, release, 'v1.0-1')
                self.assertNotEqual(first['sourceSHA256'], third['sourceSHA256'])


if __name__ == '__main__':
    unittest.main()
