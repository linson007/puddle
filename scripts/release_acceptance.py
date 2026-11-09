"""Artifact-bound acceptance records. Validation checks evidence, not the truth of human attestations."""
import argparse
import base64
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import fcntl
from functools import wraps
import json
import os
from pathlib import Path
import plistlib
import re
import tempfile
from urllib.parse import urlparse
import zipfile

FORMAT = 'puddle-release-acceptance-1'
OS_FAMILIES = (14, 15, 26, 27)
OPERATIONS = ('release_owner', 'security_owner', 'support_owner', 'key_custody_owner',
              'response_target_hours', 'private_reporting_url', 'support_url', 'incident_runbook_url',
              'previous_installer_sha256')
BASE_CHECKS = {
    'distribution': 'Developer ID, hardened signing, Apple notarization/stapling and Gatekeeper for this artifact',
    'upgrade-rollback': 'Clean-Mac signed install/upgrade/rollback and backup restoration',
    'durability': 'Crash/power-loss and acknowledged-save recovery on supported filesystems/hardware',
    'migration': 'Historical workspace fixtures, failed migration/restart and older-binary restore',
    'minimum-hardware': 'Low-RAM/slow-disk, cold-cache timing, peak memory and practical budgets',
    'first-run-privacy': 'First-time setup, failed-request recovery and retention/disconnect comprehension',
    'incident-rehearsal': 'Monitored reporting/support, staged pilot, update-feed pause and recovery rehearsal',
    'provider-google': 'Disposable-account consent/partial grants, refresh/revoke, pagination/rate limits and reviewed Google writes',
    'provider-microsoft': 'Disposable-account consent/partial grants, refresh/revoke, pagination/rate limits and reviewed mail writes',
    'provider-github': 'Repository/PAT permission boundaries, pagination/rate limits and provider-side token revocation; read only',
    'provider-atlassian': 'Site/read-scope consent, refresh/revoke, MCP pagination/rate limits; read only',
}


def text(value):
    return isinstance(value, str) and 0 < len(value.strip()) <= 4000 and value.strip().lower() not in ('pending', 'tbd', 'todo', 'unknown')


def https(value):
    if not isinstance(value, str): return False
    url = urlparse(value)
    return url.scheme == 'https' and bool(url.hostname) and url.username is None and url.password is None and not url.fragment


def read_json(path, limit=1024 * 1024):
    with path.open('rb') as file:
        data = file.read(limit + 1)
    if len(data) > limit: raise ValueError('Acceptance JSON exceeds its size limit.')
    return json.loads(data)


def write_json(path, value):
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, prefix='.acceptance-', delete=False) as temporary:
        name = Path(temporary.name)
        try:
            json.dump(value, temporary, indent=2, sort_keys=True); temporary.write('\n')
            temporary.flush(); os.fsync(temporary.fileno())
        except BaseException:
            name.unlink(missing_ok=True); raise
    try: os.replace(name, path)
    finally: name.unlink(missing_ok=True)


@contextmanager
def record_lock(path):
    lock = path.parent / '.acceptance.lock'
    try: descriptor = os.open(lock, os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError: descriptor = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try: fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError: raise ValueError('Another operator is updating this record; retry after it finishes.') from None
        yield
    finally:
        os.close(descriptor)


def locked_record(function):
    @wraps(function)
    def run(archive, path, *args, **kwargs):
        with record_lock(path): return function(archive, path, *args, **kwargs)
    return run


def artifact_details(archive):
    with archive.open('rb') as file:
        before = os.fstat(file.fileno())
        if not 0 < before.st_size <= 128 * 1024 * 1024: raise ValueError('Choose a release archive under 128 MiB.')
        digest = hashlib.sha256()
        for chunk in iter(lambda: file.read(1024 * 1024), b''): digest.update(chunk)
        file.seek(0)
        with zipfile.ZipFile(file) as zipped:
            names = [item for item in zipped.infolist() if item.filename == 'Puddle.app/Contents/Info.plist']
            if len(names) != 1 or names[0].file_size > 1024 * 1024: raise ValueError('The archive needs one bounded Puddle Info.plist.')
            info = plistlib.loads(zipped.read(names[0]))
        after = os.fstat(file.fileno())
        if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            raise ValueError('The archive changed while it was inspected.')
    version, build, minimum = info.get('CFBundleShortVersionString'), info.get('CFBundleVersion'), info.get('LSMinimumSystemVersion')
    if not isinstance(version, str) or not re.fullmatch(r'\d+\.\d+\.\d+', version): raise ValueError('Invalid archive version.')
    if not isinstance(build, str) or not build.isascii() or not build.isdigit() or int(build) <= 0: raise ValueError('Invalid archive build.')
    if not isinstance(minimum, str) or not re.fullmatch(r'\d+\.\d+(?:\.\d+)?', minimum): raise ValueError('Invalid minimum OS.')
    return {'sha256': digest.hexdigest(), 'version': version, 'build': int(build), 'minimum_os': minimum,
            'helper_configured': bool(info.get('PuddleCuaDriverRequirement')),
            'update_feed': info.get('PuddleUpdateManifestURL'), 'update_public_key': info.get('PuddleUpdatePublicKey')}


def required_checks(artifact, models):
    if not isinstance(models, list) or not 1 <= len(models) <= 20 or len(set(models)) != len(models):
        raise ValueError('Declare one to twenty distinct model configuration labels.')
    if any(not isinstance(model, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,79}', model) for model in models):
        raise ValueError('Use bounded model configuration labels containing letters, digits, underscores or hyphens.')
    checks = dict(BASE_CHECKS)
    floor = int(artifact['minimum_os'].split('.')[0])
    for major in sorted(set(OS_FAMILIES) | {floor}):
        if major < floor: continue
        checks[f'native-macos-{major}'] = f'macOS {major}: quit/sleep/wake/windows, capture/device loss, permission denial, Keychain/app lock and notifications'
        checks[f'accessibility-macos-{major}'] = f'macOS {major}: human VoiceOver, keyboard, contrast and reduced-motion acceptance'
    for model in models:
        checks[f'model-{model}'] = 'Exact runtime/model revision: streamed reply/tool/result/final reply, cancellation, restart and reviewed synthetic output'
    if artifact['helper_configured']:
        checks['helper-trust'] = 'Accepted signed helper identity/version, install/update, clean-Mac permissions and browser compatibility'
    return checks


def create_record(archive, output, models):
    artifact = artifact_details(archive)
    checks = required_checks(artifact, models)
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    (output / 'evidence').mkdir(mode=0o700)
    record = {'format': FORMAT, 'artifact': artifact, 'models': models,
              'operations': dict.fromkeys(OPERATIONS),
              'checks': {key: {'description': detail, 'status': 'pending'} for key, detail in checks.items()}}
    with record_lock(output / 'acceptance.json'): write_json(output / 'acceptance.json', record)
    return output / 'acceptance.json'


def bound_record(archive, path):
    record = read_json(path)
    if not isinstance(record, dict) or record.get('format') != FORMAT: raise ValueError('Unsupported acceptance record.')
    actual = artifact_details(archive)
    if record.get('artifact') != actual: raise ValueError('The acceptance record belongs to a different archive or build.')
    expected = required_checks(actual, record.get('models'))
    if not isinstance(record.get('checks'), dict) or set(record['checks']) != set(expected):
        raise ValueError('Required acceptance checks are missing or unexpected.')
    if not isinstance(record.get('operations'), dict) or set(record['operations']) != set(OPERATIONS):
        raise ValueError('The acceptance record needs all operations fields.')
    return record


def evidence_path(record_path, digest):
    if not isinstance(digest, str) or not re.fullmatch(r'[0-9a-f]{64}', digest): raise ValueError('Invalid evidence hash.')
    directory = record_path.parent / 'evidence'
    path = directory / (digest + '.evidence')
    if directory.is_symlink() or not directory.is_dir() or path.is_symlink(): raise ValueError('Evidence must stay in its regular private directory.')
    return path


@locked_record
def attest(archive, path, check, status, tester=None, environment=None, notes=None, evidence=None):
    record = bound_record(archive, path)
    if check not in record['checks'] or status not in ('pending', 'passed', 'failed'): raise ValueError('Choose a required check and valid status.')
    entry = {'description': record['checks'][check]['description'], 'status': status}
    if status != 'pending':
        if not all(text(value) for value in (tester, environment, notes)) or evidence is None:
            raise ValueError('A completed check needs tester, exact environment, notes and an evidence file.')
        with evidence.open('rb') as file: data = file.read(16 * 1024 * 1024 + 1)
        if not 0 < len(data) <= 16 * 1024 * 1024: raise ValueError('Choose a nonempty evidence file under 16 MiB.')
        digest = hashlib.sha256(data).hexdigest(); destination = evidence_path(path, digest)
        if destination.exists():
            with destination.open('rb') as file: previous = file.read(16 * 1024 * 1024 + 1)
            if previous != data: raise ValueError('Existing evidence changed; it was preserved.')
        else:
            with destination.open('xb') as file:
                os.chmod(destination, 0o600); file.write(data); file.flush(); os.fsync(file.fileno())
        entry.update(tester=tester, environment=environment, notes=notes, evidence_sha256=digest,
                     recorded_at=datetime.now(timezone.utc).isoformat())
    record['checks'][check] = entry; write_json(path, record)


@locked_record
def configure(archive, path, policy):
    record = bound_record(archive, path)
    values = read_json(policy, 65536)
    if not isinstance(values, dict) or set(values) != set(OPERATIONS): raise ValueError('Use exactly the documented operations fields.')
    record['operations'] = values; write_json(path, record)


@locked_record
def readiness(archive, path, expected_version=None, expected_build=None, public_key=None):
    record = bound_record(archive, path); issues = []
    artifact = record['artifact']; policy = record['operations']
    for field, expected in (('version', expected_version), ('build', expected_build), ('update_public_key', public_key)):
        if expected is not None and artifact[field] != expected: issues.append(f'archive: manifest {field} mismatch')
    if not https(artifact['update_feed']): issues.append('archive: configured HTTPS update feed required')
    try: key_valid = isinstance(artifact['update_public_key'], str) and len(base64.b64decode(artifact['update_public_key'], validate=True)) == 32
    except ValueError: key_valid = False
    if not key_valid: issues.append('archive: pinned Ed25519 public key required')
    for field in ('release_owner', 'security_owner', 'support_owner', 'key_custody_owner'):
        if not text(policy[field]): issues.append(f'operations: {field} required')
    target = policy['response_target_hours']
    if type(target) is not int or target <= 0: issues.append('operations: positive response_target_hours required')
    for field in ('private_reporting_url', 'support_url', 'incident_runbook_url'):
        if not https(policy[field]): issues.append(f'operations: HTTPS {field} required')
    if not isinstance(policy['previous_installer_sha256'], str) or not re.fullmatch(r'[0-9a-f]{64}', policy['previous_installer_sha256']):
        issues.append('operations: previous signed installer checksum required')
    for key, entry in record['checks'].items():
        if not isinstance(entry, dict) or entry.get('status') != 'passed':
            issues.append(f'{key}: pending or failed'); continue
        if not all(text(entry.get(field)) for field in ('tester', 'environment', 'notes', 'recorded_at')):
            issues.append(f'{key}: incomplete attestation'); continue
        try:
            evidence = evidence_path(path, entry.get('evidence_sha256'))
            with evidence.open('rb') as file: data = file.read(16 * 1024 * 1024 + 1)
            if not 0 < len(data) <= 16 * 1024 * 1024 or hashlib.sha256(data).hexdigest() != entry['evidence_sha256']:
                issues.append(f'{key}: evidence changed')
        except (OSError, ValueError): issues.append(f'{key}: evidence missing or invalid')
    return {'ready': not issues, 'artifact_sha256': artifact['sha256'], 'issues': issues}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    create = commands.add_parser('init'); create.add_argument('--output', required=True, type=Path)
    create.add_argument('--model', action='append', required=True, help='Exact model-matrix configuration label; repeat per advertised configuration')
    for name in ('record', 'configure', 'check'):
        command = commands.add_parser(name); command.add_argument('--record', required=True, type=Path)
        if name == 'record':
            command.add_argument('--check', required=True); command.add_argument('--status', required=True, choices=['pending', 'passed', 'failed'])
            command.add_argument('--tester'); command.add_argument('--environment'); command.add_argument('--notes')
            command.add_argument('--evidence', type=Path)
        if name == 'configure': command.add_argument('--policy', required=True, type=Path)
        if name == 'check':
            command.add_argument('--expected-version'); command.add_argument('--expected-build', type=int)
            command.add_argument('--public-key')
    for command in commands.choices.values(): command.add_argument('--archive', required=True, type=Path)
    args = parser.parse_args()
    try:
        if args.command == 'init': print(create_record(args.archive, args.output, args.model))
        elif args.command == 'record': attest(args.archive, args.record, args.check, args.status, args.tester, args.environment, args.notes, args.evidence)
        elif args.command == 'configure': configure(args.archive, args.record, args.policy)
        else:
            result = readiness(args.archive, args.record, args.expected_version, args.expected_build, args.public_key)
            print(json.dumps(result, indent=2)); return 0 if result['ready'] else 1
        return 0
    except (OSError, ValueError, TypeError, KeyError, zipfile.BadZipFile, plistlib.InvalidFileException) as error:
        parser.exit(1, f'Acceptance validation failed: {error}\n')
