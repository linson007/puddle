import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import model_acceptance as acceptance


def case(name='server-a'):
    return {'name': name, 'address': 'http://127.0.0.1:1234/v1', 'model': 'synthetic-model',
            'runtime_version': 'synthetic-runtime-1', 'model_revision': 'synthetic-revision-1'}


class ModelAcceptanceTests(unittest.TestCase):
    def test_timeout_terminates_the_isolated_process_group(self):
        with patch.object(acceptance.os, 'killpg', wraps=os.killpg) as stop:
            with self.assertRaises(subprocess.TimeoutExpired):
                acceptance.execute_suite([sys.executable, '-c', 'import time; time.sleep(60)'], cwd=acceptance.ROOT,
                                         env=os.environ.copy(), capture_output=True, timeout=0.1)
            self.assertTrue(stop.called)
    def test_matrix_rejects_remote_credentials_duplicate_names_and_unpinned_models(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'matrix.json'
            invalid = [dict(case(), address='https://remote.example/v1'), dict(case(), address='http://user:key@localhost:1234'),
                       dict(case(), model=''), dict(case(), key_env='HOME'), dict(case(), api_key='must-not-be-stored')]
            for value in invalid:
                path.write_text(json.dumps({'configurations': [value]}))
                with self.assertRaises(ValueError): acceptance.load_matrix(path)
            path.write_text(json.dumps({'configurations': [case(), case()]}))
            with self.assertRaises(ValueError): acceptance.load_matrix(path)
            path.write_text(json.dumps({'configurations': [case()]}))
            self.assertEqual(acceptance.load_matrix(path), [case()])

    def test_selected_key_and_model_are_isolated_from_other_opt_ins(self):
        environment = {'PATH': '/usr/bin', 'PUDDLE_CUA_DRIVER': '/must-not-start', 'PUDDLE_CUA_LIVE': '1',
                       'PUDDLE_LIVE_AUDIO_FILE': '/private/audio', 'PUDDLE_FILESYSTEM_TESTS': '1',
                       'PUDDLE_RUN_CAPACITY_TESTS': '1', 'PUDDLE_MODEL_KEY_OTHER': 'other-secret'}
        result = acceptance.child_environment(environment, case(), 'chosen-secret', Path('/tmp/evidence'))
        self.assertEqual(result['PUDDLE_LIVE_INFERENCE_KEY'], 'chosen-secret')
        self.assertEqual(result['PUDDLE_LIVE_INFERENCE_MODEL'], 'synthetic-model')
        self.assertFalse(set(environment).difference({'PATH'}) & set(result))

    def test_nonempty_execution_without_skips_is_required(self):
        self.assertTrue(acceptance.executed_without_skips('Executed 7 tests, with 0 failures'))
        for value in ['Executed 0 tests, with 0 failures', 'Executed 7 tests, with 7 tests skipped and 0 failures',
                      'Executed 7 tests, with 1 failure', 'Test run with 0 tests passed']:
            self.assertFalse(acceptance.executed_without_skips(value))

    def test_run_retains_results_and_redacts_all_matrix_keys(self):
        secret = 'fixture-private-key'
        selected = dict(case(), key_env='PUDDLE_MODEL_KEY_TEST')
        with tempfile.TemporaryDirectory() as folder, patch.object(acceptance, 'source_state', return_value={'commit': 'fixture'}):
            output = Path(folder) / 'run'
            def execute(command, **kwargs):
                self.assertIn(acceptance.FILTER, command)
                self.assertEqual(kwargs['env']['PUDDLE_LIVE_INFERENCE_KEY'], secret)
                self.assertNotIn('PUDDLE_MODEL_KEY_TEST', kwargs['env'])
                return subprocess.CompletedProcess(command, 0, f'Executed 7 tests, with 0 failures\n{secret}'.encode(), b'')
            self.assertTrue(acceptance.run_matrix([selected], output, environment={'PUDDLE_MODEL_KEY_TEST': secret},
                                                  execute=execute, probe=lambda *_: ['synthetic-model']))
            combined = ''.join(path.read_text() for path in output.rglob('*') if path.is_file())
            self.assertNotIn(secret, combined)
            self.assertIn('[redacted]', combined)
            self.assertEqual(json.loads((output / 'results.json').read_text())['results'][0]['status'], 'passed')
            self.assertEqual((output / 'results.json').stat().st_mode & 0o777, 0o600)

    def test_skipped_failure_does_not_hide_later_configuration(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(acceptance, 'source_state', return_value={'commit': 'fixture'}):
            output = Path(folder) / 'run'; count = 0
            def execute(command, **kwargs):
                nonlocal count
                count += 1
                summary = 'Executed 1 test, with 1 test skipped and 0 failures' if count == 1 else 'Executed 1 test, with 0 failures'
                return subprocess.CompletedProcess(command, 0, summary.encode(), b'')
            passed = acceptance.run_matrix([case(), case('server-b')], output, environment={}, execute=execute,
                                            probe=lambda *_: ['synthetic-model'])
            self.assertFalse(passed)
            self.assertEqual([value['status'] for value in json.loads((output / 'results.json').read_text())['results']], ['failed', 'passed'])

    def test_unlisted_model_does_not_run_tests_and_existing_evidence_is_preserved(self):
        with tempfile.TemporaryDirectory() as folder, patch.object(acceptance, 'source_state', return_value={'commit': 'fixture'}):
            output = Path(folder) / 'run'
            self.assertFalse(acceptance.run_matrix([case()], output, environment={}, probe=lambda *_: [],
                                                   execute=lambda *_args, **_kwargs: self.fail('Unlisted model ran')))
            before = (output / 'results.json').read_bytes()
            with self.assertRaises(FileExistsError): acceptance.run_matrix([case()], output)
            self.assertEqual((output / 'results.json').read_bytes(), before)

    def test_helper_preflight_requires_and_checks_the_explicit_identity(self):
        spec = importlib.util.spec_from_file_location('verify_local_test', acceptance.ROOT / 'scripts/verify-local.py')
        local = importlib.util.module_from_spec(spec); spec.loader.exec_module(local)
        with tempfile.TemporaryDirectory() as folder:
            driver = Path(folder) / 'driver'; driver.write_text('fixture'); driver.chmod(0o700)
            with self.assertRaises(ValueError): local.validate_driver(driver, '')
            with patch.object(local.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1)):
                with self.assertRaises(ValueError): local.validate_driver(driver, 'accepted identity')
            with patch.object(local.subprocess, 'run', return_value=subprocess.CompletedProcess([], 0)) as verify:
                self.assertEqual(local.validate_driver(driver, 'accepted identity'), driver.resolve())
                self.assertEqual(verify.call_args.args[0][-2:], ['accepted identity', str(driver.resolve())])
