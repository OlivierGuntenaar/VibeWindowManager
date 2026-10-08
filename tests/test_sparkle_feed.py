"""Real Sparkle + signed localhost feeds. Uses ephemeral test signing keys,
never touches the installed app or its preference domain, never installs updates.
Run: python3 -m unittest discover -s tests -p 'test_*.py' -v
"""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import threading
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
SPARKLE = ROOT / 'build/SourcePackages/artifacts/sparkle/Sparkle'


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


class SparkleFeedTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='vibe-sparkle-test-')
        cls.folder = Path(cls.temporary.name)
        cls.binary = cls.folder / 'probe'
        framework = SPARKLE / 'Sparkle.xcframework/macos-arm64_x86_64'
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-F', str(framework),
                        '-framework', 'Sparkle', '-Xlinker', '-rpath', '-Xlinker', str(framework),
                        str(ROOT / 'tests/SparkleFeedProbe.swift'), '-o', str(cls.binary)], check=True)
        keys = json.loads(subprocess.check_output([str(cls.binary), '--test-key'], text=True))
        cls.public_key = keys['publicKey']
        cls.key_file = cls.folder / 'test-signing-key'
        cls.key_file.write_text(keys['seed'])
        cls.key_file.chmod(0o600)
        other = json.loads(subprocess.check_output([str(cls.binary), '--test-key'], text=True))
        cls.wrong_key = other['publicKey']
        cls.server = ThreadingHTTPServer(('127.0.0.1', 0), partial(QuietHandler, directory=str(cls.folder)))
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()
        cls.temporary.cleanup()

    def probe(self, *, current=3, offered=4, signed=True, tampered=False, minimum='26.2', malformed=False, wrong_key=False, corrupt_signature=False,
              remove_signature=False, channel=None, empty=False, maximum=None, offers=None):
        test_id = uuid.uuid4().hex
        feed = self.folder / f'{test_id}.xml'
        xml = f'''<?xml version="1.0"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
        <channel><title>Vibe updater test</title><item><title>Test update</title>
        <sparkle:version>{offered}</sparkle:version><sparkle:shortVersionString>1.0.1</sparkle:shortVersionString>
        <sparkle:minimumSystemVersion>{minimum}</sparkle:minimumSystemVersion>
        <enclosure url="https://example.invalid/never-downloaded.dmg" length="1" type="application/octet-stream"/>
        </item></channel></rss>'''
        if channel:
            xml = xml.replace('<item>', f'<item><sparkle:channel>{channel}</sparkle:channel>')
        if maximum:
            xml = xml.replace('<item>', f'<item><sparkle:maximumSystemVersion>{maximum}</sparkle:maximumSystemVersion>')
        if offers is not None:
            item = re.search(r'<item>.*?</item>', xml, re.S).group()
            xml = xml.replace(item, ''.join(item.replace(f'<sparkle:version>{offered}</sparkle:version>',
                               f'<sparkle:version>{version}</sparkle:version>') for version in offers))
        if empty:
            xml = re.sub(r'<item>.*?</item>', '', xml, flags=re.S)
        feed.write_text(xml if not malformed else '<rss><broken')
        if signed:
            subprocess.run([str(SPARKLE / 'bin/sign_update'), '--ed-key-file', str(self.key_file), str(feed)],
                           check=True, stdout=subprocess.DEVNULL)
        if corrupt_signature:
            content = feed.read_text()
            content, count = re.subn(r'(edSignature: )([A-Za-z0-9+/])',
                                    lambda match: match[1] + ('A' if match[2] != 'A' else 'B'), content)
            self.assertEqual(count, 1)
            feed.write_text(content)
        if remove_signature:
            content, count = re.subn(r'<!-- sparkle-signatures:.*?-->\n?', '', feed.read_text(), flags=re.S)
            self.assertEqual(count, 1)
            feed.write_text(content)
        if tampered:
            feed.write_text(feed.read_text().replace('Test update', 'Changed update'))
        host = self.folder / f'{test_id}.app'
        (host / 'Contents').mkdir(parents=True)
        identifier = f'com.thomasguntenaar.VibeFeedTests.{test_id}'
        with (host / 'Contents/Info.plist').open('wb') as handle:
            plistlib.dump({
                'CFBundleIdentifier': identifier, 'CFBundleName': 'Feed test',
                'CFBundlePackageType': 'APPL', 'CFBundleVersion': str(current),
                'CFBundleShortVersionString': '1.0.1',
                'SUFeedURL': f'http://127.0.0.1:{self.server.server_port}/{feed.name}',
                'SUPublicEDKey': self.wrong_key if wrong_key else self.public_key, 'SURequireSignedFeed': True,
                'SUVerifyUpdateBeforeExtraction': True, 'SUEnableAutomaticChecks': False,
                'SUAutomaticallyUpdate': False,
                'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True},
            }, handle)
        try:
            result = subprocess.run([str(self.binary), str(host)], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
            outcome = json.loads(result.stdout.splitlines()[-1])
            self.assertTrue(outcome['completed'])
            return outcome
        finally:
            subprocess.run(['defaults', 'delete', identifier], capture_output=True)

    def test_newer_signed_update_is_found(self):
        outcome = self.probe()
        self.assertEqual(outcome['found'], '4', outcome)
        self.assertEqual(outcome['errorCode'], 0, outcome)

    def test_same_build_is_not_offered(self):
        outcome = self.probe(current=4)
        self.assertEqual(outcome['found'], '', outcome)
        self.assertTrue(outcome['noUpdate'], outcome)

    def test_older_build_is_not_offered(self):
        outcome = self.probe(current=5)
        self.assertEqual(outcome['found'], '', outcome)
        self.assertTrue(outcome['noUpdate'], outcome)

    def test_tampered_feed_is_rejected(self):
        outcome = self.probe(tampered=True)
        self.assertEqual(outcome['found'], '', outcome)
        self.assertNotEqual(outcome['errorCode'], 0, outcome)
        self.assertFalse(outcome['noUpdate'], outcome)

    def test_unsigned_feed_is_rejected(self):
        outcome = self.probe(signed=False)
        self.assertEqual(outcome['found'], '', outcome)
        self.assertNotEqual(outcome['errorCode'], 0, outcome)
        self.assertFalse(outcome['noUpdate'], outcome)

    def test_unsupported_os_is_not_offered(self):
        outcome = self.probe(minimum='99.0')
        self.assertEqual(outcome['found'], '', outcome)
        self.assertTrue(outcome['noUpdate'], outcome)

    def test_signature_from_another_key_is_rejected(self):
        outcome = self.probe(wrong_key=True)
        self.assertEqual(outcome['found'], '', outcome)
        self.assertNotEqual(outcome['errorCode'], 0, outcome)
        self.assertFalse(outcome['noUpdate'], outcome)

    def test_corrupted_signature_is_rejected(self):
        outcome = self.probe(corrupt_signature=True)
        self.assertEqual(outcome['found'], '', outcome)
        self.assertNotEqual(outcome['errorCode'], 0, outcome)
        self.assertFalse(outcome['noUpdate'], outcome)

    def test_signature_stripped_from_signed_feed_is_rejected(self):
        outcome = self.probe(remove_signature=True)
        self.assertEqual(outcome['found'], '', outcome)
        self.assertNotEqual(outcome['errorCode'], 0, outcome)
        self.assertFalse(outcome['noUpdate'], outcome)

    def test_beta_channel_is_excluded_by_default(self):
        outcome = self.probe(channel='beta')
        self.assertEqual(outcome['found'], '', outcome)
        self.assertTrue(outcome['noUpdate'], outcome)

    def test_empty_signed_feed_has_no_update(self):
        outcome = self.probe(empty=True)
        self.assertEqual(outcome['found'], '', outcome)
        self.assertTrue(outcome['noUpdate'], outcome)

    def test_maximum_os_excludes_obsolete_update(self):
        outcome = self.probe(minimum='10.0', maximum='10.15')
        self.assertEqual(outcome['found'], '', outcome)
        self.assertTrue(outcome['noUpdate'], outcome)

    def test_numeric_versions_are_not_compared_lexicographically(self):
        outcome = self.probe(current='9', offered='10')
        self.assertEqual(outcome['found'], '10', outcome)

    def test_dotted_versions_compare_each_numeric_component(self):
        outcome = self.probe(current='1.9', offered='1.10')
        self.assertEqual(outcome['found'], '1.10', outcome)

    def test_final_version_replaces_prerelease(self):
        outcome = self.probe(current='2.0b1', offered='2.0')
        self.assertEqual(outcome['found'], '2.0', outcome)

    def test_prerelease_does_not_replace_final_version(self):
        outcome = self.probe(current='2.0', offered='2.0b1')
        self.assertEqual(outcome['found'], '', outcome)
        self.assertTrue(outcome['noUpdate'], outcome)

    def test_highest_update_selected_from_unsorted_feed(self):
        outcome = self.probe(offers=['5', '12', '7'])
        self.assertEqual(outcome['found'], '12', outcome)

    def test_malformed_signed_feed_is_rejected(self):
        outcome = self.probe(malformed=True)
        self.assertEqual(outcome['found'], '', outcome)
        self.assertNotEqual(outcome['errorCode'], 0, outcome)


if __name__ == '__main__':
    unittest.main()
