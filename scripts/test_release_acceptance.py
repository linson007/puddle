import base64
import fcntl
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
import zipfile

import release_acceptance as acceptance


class ReleaseAcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='puddle-acceptance-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.archive = self.root / 'Puddle.zip'
        self.info = {'CFBundleShortVersionString': '1.0.0', 'CFBundleVersion': '10', 'LSMinimumSystemVersion': '14.0',
                     'PuddleUpdateManifestURL': 'https://release.example.test/stable.json',
                     'PuddleUpdatePublicKey': base64.b64encode(bytes(32)).decode()}
        self.write_archive()
        self.record = acceptance.create_record(self.archive, self.root / 'private-evidence', ['synthetic-model'])
        self.evidence = self.root / 'synthetic.txt'
        self.evidence.write_text('Synthetic fixture evidence, not a real release attestation.')

    def write_archive(self):
        with zipfile.ZipFile(self.archive, 'w') as archive:
            archive.writestr('Puddle.app/Contents/Info.plist', plistlib.dumps(self.info))

    def complete_fixture(self):
        ledger = acceptance.read_json(self.record)
        for key in ledger['checks']:
            acceptance.attest(self.archive, self.record, key, 'passed', 'Fixture tester',
                              'Synthetic OS/runtime/hardware', 'Synthetic assertions only', self.evidence)
        policy = {field: 'Fixture owner' for field in acceptance.OPERATIONS}
        for field in ('private_reporting_url', 'support_url', 'incident_runbook_url'):
            policy[field] = 'https://support.example.test/fixture'
        policy['response_target_hours'] = 72; policy['previous_installer_sha256'] = 'a' * 64
        source = self.root / 'operations.json'; acceptance.write_json(source, policy)
        acceptance.configure(self.archive, self.record, source)

    def test_new_record_is_pending_and_includes_minimum_os_providers_and_models(self):
        record = acceptance.read_json(self.record)
        self.assertIn('native-macos-14', record['checks'])
        self.assertIn('accessibility-macos-14', record['checks'])
        for provider in ('google', 'microsoft', 'github', 'atlassian'):
            self.assertIn('provider-' + provider, record['checks'])
        self.assertIn('model-synthetic-model', record['checks'])
        self.assertTrue(all(check['status'] == 'pending' for check in record['checks'].values()))
        self.assertFalse(acceptance.readiness(self.archive, self.record)['ready'])
        self.assertEqual(self.record.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.record.parent.stat().st_mode & 0o777, 0o700)

    def test_complete_fixture_requires_immutable_evidence_and_can_be_reset(self):
        self.complete_fixture()
        self.assertTrue(acceptance.readiness(self.archive, self.record)['ready'])
        acceptance.attest(self.archive, self.record, 'distribution', 'pending')
        self.assertFalse(acceptance.readiness(self.archive, self.record)['ready'])

    def test_missing_or_changed_evidence_blocks_acceptance(self):
        self.complete_fixture()
        ledger = acceptance.read_json(self.record)
        path = acceptance.evidence_path(self.record, ledger['checks']['distribution']['evidence_sha256'])
        original = path.read_bytes(); path.write_text('Changed after review')
        self.assertFalse(acceptance.readiness(self.archive, self.record)['ready'])
        path.write_bytes(original); path.unlink()
        self.assertFalse(acceptance.readiness(self.archive, self.record)['ready'])

    def test_final_manifest_version_build_and_pin_must_match_the_artifact(self):
        self.complete_fixture()
        for overrides in ({'expected_version': '2.0.0'}, {'expected_build': 11}, {'public_key': base64.b64encode(bytes([1] * 32)).decode()}):
            self.assertFalse(acceptance.readiness(self.archive, self.record, **overrides)['ready'])

    def test_archive_change_and_removed_gate_cannot_reuse_acceptance(self):
        ledger = acceptance.read_json(self.record)
        del ledger['checks']['native-macos-14']; acceptance.write_json(self.record, ledger)
        with self.assertRaises(ValueError): acceptance.readiness(self.archive, self.record)
        self.info['CFBundleVersion'] = '11'; self.write_archive()
        with self.assertRaises(ValueError): acceptance.bound_record(self.archive, self.record)

    def test_placeholder_or_omitted_operations_block_readiness_after_complete_evidence(self):
        self.complete_fixture()
        ledger = acceptance.read_json(self.record)
        ledger['operations']['release_owner'] = 'pending'; acceptance.write_json(self.record, ledger)
        self.assertIn('operations: release_owner required', acceptance.readiness(self.archive, self.record)['issues'])
        del ledger['operations']['previous_installer_sha256']; acceptance.write_json(self.record, ledger)
        with self.assertRaises(ValueError): acceptance.readiness(self.archive, self.record)

    def test_completed_check_needs_tester_environment_notes_and_nonempty_evidence(self):
        with self.assertRaises(ValueError): acceptance.attest(self.archive, self.record, 'distribution', 'passed')
        self.evidence.write_bytes(b'')
        with self.assertRaises(ValueError):
            acceptance.attest(self.archive, self.record, 'distribution', 'passed', 'Fixture', 'macOS fixture', 'Notes', self.evidence)

    def test_missing_update_pin_and_helper_scope_are_derived_from_archive(self):
        self.info.pop('PuddleUpdatePublicKey'); self.info['PuddleCuaDriverRequirement'] = 'fixture identity'
        self.write_archive()
        record = acceptance.create_record(self.archive, self.root / 'other-evidence', ['synthetic-model'])
        self.assertIn('helper-trust', acceptance.read_json(record)['checks'])
        self.assertIn('archive: pinned Ed25519 public key required', acceptance.readiness(self.archive, record)['issues'])

    def test_symlink_evidence_and_concurrent_operator_are_rejected(self):
        self.complete_fixture()
        ledger = acceptance.read_json(self.record)
        evidence = acceptance.evidence_path(self.record, ledger['checks']['distribution']['evidence_sha256'])
        evidence.unlink(); evidence.symlink_to(self.evidence)
        self.assertFalse(acceptance.readiness(self.archive, self.record)['ready'])
        with (self.record.parent / '.acceptance.lock').open('r') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(ValueError): acceptance.attest(self.archive, self.record, 'distribution', 'pending')

    def test_existing_evidence_directory_is_preserved(self):
        before = self.record.read_bytes()
        with self.assertRaises(FileExistsError): acceptance.create_record(self.archive, self.record.parent, ['synthetic-model'])
        self.assertEqual(self.record.read_bytes(), before)


if __name__ == '__main__':
    unittest.main()
