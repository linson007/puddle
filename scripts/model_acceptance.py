"""Run synthetic live-model acceptance independently of browser/audio/account setup."""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import tempfile
import time
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent.parent
FILTER = 'LiveEvaluationTests|LiveWorkflowAcceptanceTests|LocalInferenceTests.testLiveConfiguredLocalServer'


def validate_address(address):
    url = urlparse(address)
    if (url.scheme not in ('http', 'https') or url.hostname not in ('127.0.0.1', 'localhost', '::1')
            or url.username is not None or url.password is not None or url.query or url.fragment
            or url.path not in ('', '/', '/v1', '/v1/')):
        raise ValueError('Model addresses must be loopback HTTP(S), optionally ending in /v1.')
    if url.port is not None and not 1 <= url.port <= 65535:
        raise ValueError('Invalid model server port.')
    return url


def load_matrix(path):
    if path.stat().st_size > 65536:
        raise ValueError('Use a matrix under 64 KiB.')
    matrix = json.loads(path.read_text())
    if not isinstance(matrix, dict) or set(matrix) != {'configurations'}:
        raise ValueError('The matrix must contain configurations only.')
    cases = matrix['configurations']
    if not isinstance(cases, list) or not 1 <= len(cases) <= 20:
        raise ValueError('Choose between one and twenty configurations.')
    names = set()
    required = {'name', 'address', 'model', 'runtime_version', 'model_revision'}
    for case in cases:
        if not isinstance(case, dict) or not required <= set(case) or set(case) - required - {'key_env'}:
            raise ValueError('Each case needs name/address/model/runtime_version/model_revision; keys belong in key_env.')
        if any(not isinstance(value, str) or not value.strip() or len(value) > 2000 or '\n' in value or '\r' in value for value in case.values()):
            raise ValueError('Configuration values must be bounded nonempty strings.')
        if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}', case['name']) or case['name'] in names:
            raise ValueError('Use unique configuration names containing letters, digits, underscores or hyphens.')
        names.add(case['name']); validate_address(case['address'])
        if 'key_env' in case and not re.fullmatch(r'PUDDLE_MODEL_KEY_[A-Z0-9_]+', case['key_env']):
            raise ValueError('key_env must name a dedicated PUDDLE_MODEL_KEY_* variable, never contain a key.')
    return cases


def discover(address, key):
    url = validate_address(address)
    connection_type = http.client.HTTPSConnection if url.scheme == 'https' else http.client.HTTPConnection
    connection = connection_type('127.0.0.1' if url.hostname == 'localhost' else url.hostname, url.port, timeout=10)
    try:
        connection.request('GET', '/v1/models', headers={'Authorization': f'Bearer {key}'} if key else {})
        response = connection.getresponse()
        if response.status != 200:
            raise RuntimeError(f'Model discovery returned HTTP {response.status}. Redirects are not followed.')
        data = response.read(2 * 1024 * 1024 + 1)
        if len(data) > 2 * 1024 * 1024:
            raise ValueError('Model discovery exceeded its size limit.')
        payload = json.loads(data)
        if not isinstance(payload, dict) or not isinstance(payload.get('data'), list) or any(not isinstance(value, dict) for value in payload['data']):
            raise ValueError('The model list is malformed.')
        return [value['id'] for value in payload['data'] if isinstance(value.get('id'), str)]
    finally:
        connection.close()


def child_environment(environment, case, key, output):
    # Inherited opt-ins must never activate accounts, audio, helpers or load tests.
    result = {name: value for name, value in environment.items() if not name.startswith('PUDDLE_')}
    # Only pass the chosen key to the test's dedicated variable.
    result.update(PUDDLE_LIVE_INFERENCE_ADDRESS=case['address'], PUDDLE_LIVE_INFERENCE_MODEL=case['model'],
                  PUDDLE_LIVE_INFERENCE_KEY=key, PUDDLE_ACCEPTANCE_OUTPUT_DIRECTORY=str(output))
    return result


def atomic_json(path, value):
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, prefix='.acceptance-', delete=False) as temporary:
        name = Path(temporary.name)
        try:
            json.dump(value, temporary, indent=2, sort_keys=True); temporary.write('\n')
            temporary.flush(); os.fsync(temporary.fileno())
        except BaseException:
            name.unlink(missing_ok=True); raise
    try:
        os.replace(name, path)
    finally:
        name.unlink(missing_ok=True)


def source_state():
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    dirty = bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT))
    files = subprocess.check_output(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z', '--',
        'Sources', 'Tests', 'scripts', 'app', 'Package.swift'], cwd=ROOT).split(b'\0')
    digest = hashlib.sha256()
    for item in sorted(set(files)):
        if item and (ROOT / os.fsdecode(item)).is_file():
            digest.update(item + b'\0')
            with (ROOT / os.fsdecode(item)).open('rb') as contents:
                for chunk in iter(lambda: contents.read(1024 * 1024), b''):
                    digest.update(chunk)
    return {'commit': commit, 'dirty': dirty, 'source_sha256': digest.hexdigest()}


def executed_without_skips(log):
    totals = re.findall(r'Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?', log)
    return bool(totals) and int(totals[-1][0]) > 0 and int(totals[-1][1] or 0) == 0 and int(totals[-1][2]) == 0


def execute_suite(command, *, cwd, env, capture_output, timeout):
    # Isolate the subprocess group so timing out SwiftPM also stops XCTest and
    # its synthetic local-model requests, rather than leaving an orphan runner.
    process = subprocess.Popen(command, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try: os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError: pass
        try:
            stdout, stderr = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            try: os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError: pass
            stdout, stderr = process.communicate()
        raise subprocess.TimeoutExpired(command, timeout, output=stdout, stderr=stderr) from None
    return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


def run_matrix(cases, output, configuration='release', timeout=1200, environment=None, execute=execute_suite, probe=discover):
    environment = dict(os.environ if environment is None else environment)
    # Check missing credentials before doing any work; never persist them.
    keys = {}
    for case in cases:
        keys[case['name']] = environment.get(case.get('key_env', ''), '')
        if case.get('key_env') and not keys[case['name']]:
            raise ValueError('A configured key_env is missing or empty.')
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    report = {'format': 'puddle-model-acceptance-1', 'source': source_state(),
              'host': {'platform': platform.platform(), 'machine': platform.machine(), 'macos': platform.mac_ver()[0]},
              'configuration': configuration, 'results': []}
    atomic_json(output / 'results.json', report)
    all_keys = [key for key in keys.values() if key]
    for case in cases:
        print(f"Checking {case['name']}…", flush=True)
        folder = output / case['name']; folder.mkdir(mode=0o700)
        result = {name: value for name, value in case.items() if name != 'key_env'}
        result.update(status='failed', elapsed_seconds=0)
        started = time.monotonic(); log = ''
        try:
            models = probe(case['address'], keys[case['name']])
            if case['model'] not in models:
                raise ValueError('The exact selected model is not listed by the running server.')
            command = ['sh', 'scripts/swift.sh', 'test', '-c', configuration, '--filter', FILTER]
            child = child_environment(environment, case, keys[case['name']], folder / 'workflows')
            completed = execute(command, cwd=ROOT, env=child, capture_output=True, timeout=timeout)
            log = (completed.stdout or b'').decode('utf-8', errors='replace') + (completed.stderr or b'').decode('utf-8', errors='replace')
            result['exit_code'] = completed.returncode
            result['status'] = 'passed' if completed.returncode == 0 and executed_without_skips(log) else 'failed'
        except subprocess.TimeoutExpired as error:
            log = 'Acceptance timed out.\n' + (error.stdout or b'').decode('utf-8', errors='replace')
            result['error'] = 'timeout'
        except (OSError, ValueError, RuntimeError, http.client.HTTPException) as error:
            result['error'] = type(error).__name__
            log = 'Acceptance could not finish; check server configuration and the selected model.\n'
        result['elapsed_seconds'] = time.monotonic() - started
        for key in all_keys:
            log = log.replace(key, '[redacted]')
        path = folder / 'tests.log'
        with path.open('x') as handle:
            os.chmod(path, 0o600); handle.write(log)
        report['results'].append(result); atomic_json(output / 'results.json', report)
        print(f"{result['status'].upper()} {case['name']}", flush=True)
    return all(result['status'] == 'passed' for result in report['results'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--matrix', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--configuration', choices=['debug', 'release'], default='release')
    parser.add_argument('--timeout', type=int, default=1200)
    args = parser.parse_args()
    if not 1 <= args.timeout <= 7200:
        parser.error('Choose a timeout from 1 to 7200 seconds per configuration.')
    try:
        return 0 if run_matrix(load_matrix(args.matrix), args.output, args.configuration, args.timeout) else 1
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f'Model acceptance failed: {type(error).__name__}. Check the matrix and output destination.\n')
