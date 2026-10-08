"""Real Sparkle download/install/relaunch into disposable apps, never /Applications.
Requires macOS GUI session and bundled Sparkle; uses no production signing key.
"""
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import plistlib
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import unittest
import uuid

ROOT = Path(__file__).resolve().parents[1]
SPARKLE = ROOT / 'build/SourcePackages/artifacts/sparkle/Sparkle'


class DownloadHandler(SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path.endswith('/interrupted.zip'):
            data = Path(self.translate_path(self.path)).read_bytes()
            self.send_response(200)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data[:max(1, len(data) // 3)])
            self.wfile.flush()
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return
        super().do_GET()


class SparkleInstallTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='vibe-install-test-')
        cls.folder = Path(cls.temp.name)
        cls.binary = cls.folder / 'InstallProbe'
        framework = SPARKLE / 'Sparkle.xcframework/macos-arm64_x86_64'
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-F', str(framework),
                        '-framework', 'Sparkle', '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks',
                        str(ROOT / 'tests/SparkleInstallProbe.swift'), '-o', str(cls.binary)], check=True)
        key_binary = cls.folder / 'KeyProbe'
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-F', str(framework),
                        '-framework', 'Sparkle', '-Xlinker', '-rpath', '-Xlinker', str(framework),
                        str(ROOT / 'tests/SparkleFeedProbe.swift'), '-o', str(key_binary)], check=True)
        keys = json.loads(subprocess.check_output([str(key_binary), '--test-key'], text=True))
        cls.public_key = keys['publicKey']
        cls.key = cls.folder / 'key'
        cls.key.write_text(keys['seed'])
        cls.key.chmod(0o600)
        cls.server = ThreadingHTTPServer(('127.0.0.1', 0), partial(DownloadHandler, directory=str(cls.folder)))
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join()
        cls.temp.cleanup()

    def app(self, path, identifier, version, feed_url, output):
        contents = path / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        (contents / 'Frameworks').mkdir()
        shutil.copy2(self.binary, contents / 'MacOS/InstallProbe')
        shutil.copytree(SPARKLE / 'Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework',
                        contents / 'Frameworks/Sparkle.framework', symlinks=True)
        info = {'CFBundleIdentifier': identifier, 'CFBundleName': 'Disposable Update Probe',
                'CFBundleExecutable': 'InstallProbe', 'CFBundlePackageType': 'APPL',
                'CFBundleVersion': str(version), 'CFBundleShortVersionString': f'1.0.{version}',
                'LSUIElement': True, 'SUFeedURL': feed_url, 'SUPublicEDKey': self.public_key,
                'SURequireSignedFeed': True, 'SUVerifyUpdateBeforeExtraction': True,
                'SUEnableAutomaticChecks': False, 'SUAutomaticallyUpdate': False,
                'NSAppTransportSecurity': {'NSAllowsLocalNetworking': True},
                'TestResultPath': str(output)}
        (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
        subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none', str(path)],
                       check=True, capture_output=True)

    def scenario(self, mode):
        identifier = 'com.thomasguntenaar.VibeInstallTests.' + uuid.uuid4().hex
        folder = self.folder / identifier
        folder.mkdir()
        output = folder / 'result.json'
        url = f'http://127.0.0.1:{self.server.server_port}/{identifier}/'
        old = folder / 'installed/UpdateProbe.app'
        new = folder / 'next/UpdateProbe.app'
        self.app(old, identifier, 1, url + 'appcast.xml', output)
        self.app(new, identifier, 2, url + 'appcast.xml', output)
        if mode == 'missing-app':
            shutil.rmtree(new)
            new.mkdir()
            (new / 'README.txt').write_text('No executable application in this archive')
        archive = folder / ('interrupted.zip' if mode == 'interrupted' else 'update.dmg' if mode == 'success-dmg' else 'update.zip')
        if mode == 'success-dmg':
            subprocess.run(['hdiutil', 'create', '-volname', 'Disposable Update Probe', '-srcfolder',
                            str(new.parent), '-format', 'UDZO', str(archive)], check=True, capture_output=True)
        else:
            subprocess.run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', str(new), str(archive)], check=True)
        if mode == 'invalid-archive':
            archive.write_bytes(b'Not an archive despite a valid signature')
        signature = subprocess.check_output([str(SPARKLE / 'bin/sign_update'), '--ed-key-file', str(self.key),
                                             '-p', str(archive)], text=True).strip()
        if mode == 'tampered-artifact':
            data = bytearray(archive.read_bytes())
            data[len(data) // 2] ^= 1
            archive.write_bytes(data)
        feed = folder / 'appcast.xml'
        feed.write_text(f'''<?xml version="1.0"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Disposable integration feed</title><item><title>Version 2</title><sparkle:version>2</sparkle:version><sparkle:shortVersionString>1.0.2</sparkle:shortVersionString><enclosure url="{url}{archive.name}" length="{archive.stat().st_size}" type="application/octet-stream" sparkle:edSignature="{signature}"/></item></channel></rss>''')
        subprocess.run([str(SPARKLE / 'bin/sign_update'), '--ed-key-file', str(self.key), str(feed)],
                       check=True, capture_output=True)
        log = folder / 'process.log'
        with log.open('w') as handle:
            process = subprocess.Popen([str(old / 'Contents/MacOS/InstallProbe')], stdout=handle, stderr=handle)
            try:
                deadline = time.monotonic() + 45
                while time.monotonic() < deadline and not output.exists():
                    time.sleep(0.1)
                self.assertTrue(output.exists(), f'No result for {mode}; process={process.poll()}; {log.read_text()}')
                result = json.loads(output.read_text())
                installed = plistlib.loads((old / 'Contents/Info.plist').read_bytes())['CFBundleVersion']
                self.assertEqual(result['setting'], 'preserve-me', result)
                return result, installed
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                subprocess.run(['defaults', 'delete', identifier], capture_output=True)
                cache = Path.home() / 'Library/Caches' / identifier
                if cache.exists():
                    shutil.rmtree(cache)

    def test_real_update_replaces_old_app_relaunches_and_preserves_settings(self):
        result, installed = self.scenario('success')
        self.assertEqual(installed, '2', result)
        self.assertEqual(result['build'], '2', result)
        self.assertTrue(result['installed'], result)
        for stage in ['found', 'download', 'received-data', 'extract', 'ready', 'relaunched-new-version']:
            self.assertIn(stage, result['events'], result)

    def test_real_dmg_update_relaunches_and_preserves_settings(self):
        result, installed = self.scenario('success-dmg')
        self.assertEqual(installed, '2', result)
        self.assertEqual(result['build'], '2', result)
        self.assertTrue(result['installed'], result)
        for stage in ['download', 'extract', 'ready', 'relaunched-new-version']:
            self.assertIn(stage, result['events'], result)

    def test_interrupted_download_preserves_old_app_and_settings(self):
        result, installed = self.scenario('interrupted')
        self.assertEqual(installed, '1', result)
        self.assertFalse(result['installed'], result)
        self.assertNotEqual(result['errorCode'], 0, result)
        self.assertIn('download', result['events'])

    def test_signed_invalid_archive_preserves_old_app_and_settings(self):
        result, installed = self.scenario('invalid-archive')
        self.assertEqual(installed, '1', result)
        self.assertFalse(result['installed'], result)
        self.assertNotEqual(result['errorCode'], 0, result)

    def test_tampered_download_cannot_replace_installed_app(self):
        result, installed = self.scenario('tampered-artifact')
        self.assertEqual(installed, '1', result)
        self.assertFalse(result['installed'], result)
        self.assertNotEqual(result['errorCode'], 0, result)

    def test_archive_without_app_cannot_replace_installed_app(self):
        result, installed = self.scenario('missing-app')
        self.assertEqual(installed, '1', result)
        self.assertFalse(result['installed'], result)
        self.assertNotEqual(result['errorCode'], 0, result)


if __name__ == '__main__':
    unittest.main()
