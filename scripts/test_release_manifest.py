"""Exercise manifest signing against disposable ad hoc bundles, never owner keys."""
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

import release_acceptance

ROOT = Path(__file__).resolve().parent.parent


@unittest.skipUnless(sys.platform == 'darwin', 'macOS bundle/signing fixtures')
class ReleaseManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compiled = tempfile.TemporaryDirectory(prefix='puddle-release-tools-')
        cls.signer = Path(cls.compiled.name) / 'manifest'
        cls.verifier = Path(cls.compiled.name) / 'verify-release'
        for source, output in [('release-manifest.swift', cls.signer), ('verify-release.swift', cls.verifier)]:
            subprocess.run(['swiftc', '-module-cache-path', str(ROOT / '.build/module-cache'),
                            str(ROOT / 'scripts' / source), '-o', str(output)], check=True,
                           capture_output=True, timeout=120)

    @classmethod
    def tearDownClass(cls):
        cls.compiled.cleanup()

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='puddle-manifest-fixture-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.key = self.root / 'private-key'
        generated = subprocess.run([str(self.signer), '--generate-key', str(self.key)],
                                   capture_output=True, text=True, check=True, timeout=30)
        self.public = generated.stdout.strip().removeprefix('Public key: ')
        self.app = self.root / 'Puddle.app'
        binary = self.app / 'Contents/MacOS/Puddle'
        binary.parent.mkdir(parents=True)
        shutil.copyfile('/usr/bin/true', binary)
        binary.chmod(0o755)
        self.info = self.app / 'Contents/Info.plist'
        self.info.write_bytes(plistlib.dumps({'CFBundleIdentifier': 'app.puddle.release-fixture',
            'CFBundleExecutable': 'Puddle', 'CFBundlePackageType': 'APPL',
            'CFBundleShortVersionString': '1.0.0', 'CFBundleVersion': '10',
            'LSMinimumSystemVersion': '14.0', 'PuddleUpdateManifestURL': 'https://release.example.test/stable.json',
            'PuddleUpdatePublicKey': self.public}))
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(self.app)],
                       capture_output=True, check=True, timeout=30)
        self.archive = self.root / 'Puddle-1.0.0-10.zip'
        self.manifest = self.root / 'manifest.json'

    def sign(self, version='1.0.0'):
        subprocess.run(['/usr/bin/ditto', '-c', '-k', '--keepParent', str(self.app), str(self.archive)],
                       capture_output=True, check=True, timeout=30)
        return subprocess.run([str(self.signer), str(self.archive), version, '10',
            'https://release.example.test/1.0.0-10/Puddle.zip', str(self.manifest)],
            env={**os.environ, 'PUDDLE_UPDATE_SIGNING_KEY_FILE': str(self.key)},
            capture_output=True, text=True, timeout=30)

    def test_manifest_is_bound_to_final_archive_and_pinned_key(self):
        result = self.sign()
        self.assertEqual(result.returncode, 0, result.stderr)
        envelope = json.loads(self.manifest.read_bytes())
        release = json.loads(base64.b64decode(envelope['payload']))
        self.assertEqual(release['sha256'], hashlib.sha256(self.archive.read_bytes()).hexdigest())
        self.assertEqual((release['version'], release['build']), ('1.0.0', 10))
        self.assertEqual(len(base64.b64decode(envelope['signature'])), 64)
        envelope['signature'] = base64.b64encode(bytes(64)).decode()
        self.manifest.write_text(json.dumps(envelope))
        rejected = subprocess.run([str(self.verifier), str(self.archive), str(self.manifest), self.public, str(self.root / 'acceptance.json')],
                                  capture_output=True, text=True, timeout=30)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn('signature verification failed', rejected.stderr)

    def test_wrong_version_does_not_create_manifest(self):
        result = self.sign('2.0.0')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.manifest.exists())

    def test_pending_acceptance_stops_the_remote_check_before_publication(self):
        signed = self.sign()
        self.assertEqual(signed.returncode, 0, signed.stderr)
        record = release_acceptance.create_record(self.archive, self.root / 'acceptance', ['synthetic-model'])
        rejected = subprocess.run([str(self.verifier), str(self.archive), str(self.manifest), self.public, str(record)],
                                  capture_output=True, text=True, timeout=30)
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn('Release acceptance is incomplete', rejected.stderr)
        self.assertIn('native-macos-14', rejected.stdout)

    def test_tampered_bundle_does_not_create_manifest(self):
        info = plistlib.loads(self.info.read_bytes())
        info['UnexpectedUnsignedValue'] = True
        self.info.write_bytes(plistlib.dumps(info))
        result = self.sign()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.manifest.exists())

    def test_wrong_pinned_key_does_not_create_manifest(self):
        self.key = self.root / 'other-private-key'
        subprocess.run([str(self.signer), '--generate-key', str(self.key)],
                       capture_output=True, check=True, timeout=30)
        result = self.sign()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.manifest.exists())
