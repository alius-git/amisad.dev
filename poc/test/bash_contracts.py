#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
"""Bash prerequisites must be usable against the native fixture filesystem."""
import importlib.util
import io
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

import bash_contract_support as support

ROOT = Path(__file__).resolve().parent


def load_suite(name):
    spec = importlib.util.spec_from_file_location('fixture_' + name, ROOT / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class BashPrerequisites(unittest.TestCase):
    def failed_launcher(self, body, timeout=0.25):
        native_run = subprocess.run

        def launch(_command, **options):
            return native_run([sys.executable, '-c', body], **options)

        with mock.patch.object(support, 'bash_candidates', return_value=[sys.executable]), \
                mock.patch.object(support.subprocess, 'run', side_effect=launch):
            return support.find_usable_bash(timeout=timeout)

    def assert_both_suites_skip(self, bash):
        for name in ('cluster_ready_contracts', 'image_import_contracts'):
            with self.subTest(suite=name), mock.patch.object(support, 'find_usable_bash', return_value=bash):
                module = load_suite(name)
            suite = unittest.defaultTestLoader.loadTestsFromModule(module)
            result = unittest.TextTestRunner(stream=io.StringIO()).run(suite)
            self.assertTrue(result.wasSuccessful())
            self.assertEqual(len(result.skipped), result.testsRun)
            self.assertGreater(result.testsRun, 0)

    def test_missing_bash_skips_both_suites(self):
        with mock.patch.object(support, 'bash_candidates', return_value=[]):
            bash = support.find_usable_bash()
        self.assertIsNone(bash)
        self.assert_both_suites_skip(bash)

    def test_exit126_launcher_skips_both_suites(self):
        bash = self.failed_launcher('raise SystemExit(126)')
        self.assertIsNone(bash)
        self.assert_both_suites_skip(bash)

    def test_hanging_launcher_is_bounded_and_skips_both_suites(self):
        started = time.monotonic()
        bash = self.failed_launcher('import time; time.sleep(30)')
        self.assertLess(time.monotonic() - started, 5)
        self.assertIsNone(bash)
        self.assert_both_suites_skip(bash)

    def test_exit_zero_without_fixture_files_is_not_usable(self):
        self.assertIsNone(self.failed_launcher('print("amisad-bash-fixture")'))

    def test_windows_store_and_wsl_launchers_are_not_started(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            launchers = [root / part / 'bash.exe' for part in ('WindowsApps', 'System32', 'Sysnative', 'Git/bin')]
            with mock.patch.object(support.os, 'get_exec_path', return_value=[str(i) for i in range(4)]), \
                    mock.patch.object(support.shutil, 'which', side_effect=[str(p) for p in launchers]), \
                    mock.patch.object(support.sys, 'platform', 'win32'):
                self.assertEqual(support.bash_candidates(), [str(launchers[-1].resolve())])

    def test_one_deadline_bounds_multiple_hanging_candidates(self):
        native_run = subprocess.run

        def launch(_command, **options):
            return native_run([sys.executable, '-c', 'import time; time.sleep(30)'], **options)

        started = time.monotonic()
        with mock.patch.object(support, 'bash_candidates', return_value=['first', 'second', 'third']), \
                mock.patch.object(support.subprocess, 'run', side_effect=launch) as runner:
            self.assertIsNone(support.find_usable_bash(timeout=0.25))
        self.assertLess(time.monotonic() - started, 5)
        self.assertEqual(runner.call_count, 1)

    def test_descendant_inheriting_output_handles_cannot_delay_launcher_result(self):
        native_run = subprocess.run
        with tempfile.TemporaryDirectory(prefix='amisad descendant ') as directory:
            root = Path(directory)
            pid_file = root / 'child.pid'
            body = ('import subprocess, sys, time\nfrom pathlib import Path\n'
                    'child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(20)"], '
                    f'cwd={str(root)!r})\n'
                    f'Path({str(pid_file)!r}).write_text(str(child.pid))\n'
                    'time.sleep(30)\n')

            def launch(_command, **options):
                return native_run([sys.executable, '-c', body], **options)

            try:
                started = time.monotonic()
                with mock.patch.object(support, 'bash_candidates', return_value=[sys.executable]), \
                        mock.patch.object(support.subprocess, 'run', side_effect=launch):
                    self.assertIsNone(support.find_usable_bash(timeout=2))
                self.assertLess(time.monotonic() - started, 6)
                self.assertTrue(pid_file.is_file(), 'the launcher must start its inheriting descendant')
            finally:
                if pid_file.is_file():
                    try:
                        os.kill(int(pid_file.read_text()), signal.SIGTERM)
                    except ProcessLookupError:
                        pass

    def test_bad_candidate_does_not_hide_a_later_usable_bash(self):
        bash = support.find_usable_bash()
        if bash is None:
            self.skipTest('No usable native-filesystem Bash is available')
        native_run = subprocess.run

        def launch(command, **options):
            if command[0] == 'unusable':
                return native_run([sys.executable, '-c', 'raise SystemExit(126)'], **options)
            return native_run(command, **options)

        with mock.patch.object(support, 'bash_candidates', return_value=['unusable', bash]), \
                mock.patch.object(support.subprocess, 'run', side_effect=launch):
            self.assertEqual(support.find_usable_bash(), bash)

    def test_launch_error_is_not_usable(self):
        with mock.patch.object(support, 'bash_candidates', return_value=['missing-bash']), \
                mock.patch.object(support.subprocess, 'run', side_effect=OSError('fixture missing')):
            self.assertIsNone(support.find_usable_bash())

    def test_native_bash_proves_paths_shims_and_posix_tools(self):
        bash = support.find_usable_bash()
        if bash is None:
            self.skipTest('No usable native-filesystem Bash is available')
        self.assertTrue(Path(bash).is_absolute())

    def test_suites_keep_selected_bash_when_path_has_an_unusable_launcher(self):
        bash = support.find_usable_bash()
        if bash is None:
            self.skipTest('No usable native-filesystem Bash is available')
        with tempfile.TemporaryDirectory(prefix='amisad launcher ') as directory:
            root = Path(directory)
            launcher = root / 'bash'
            launcher.write_bytes(b'#!/bin/bash\nexit 126\n')
            launcher.chmod(0o755)
            for name, case, test in (
                    ('cluster_ready_contracts', 'ClusterGates', 'test_every_restart_rollout_and_nodeport_still_required'),
                    ('image_import_contracts', 'ImageImport', 'test_all_exact_tags_in_one_archive_before_any_helm')):
                with self.subTest(suite=name), mock.patch.object(support, 'find_usable_bash', return_value=bash):
                    module = load_suite(name)
                with mock.patch.dict(os.environ, {'PATH': str(root) + os.pathsep + os.environ['PATH']}):
                    result = unittest.TextTestRunner(stream=io.StringIO()).run(
                        unittest.TestSuite([getattr(module, case)(test)]))
                self.assertTrue(result.wasSuccessful(), result.failures + result.errors)
                self.assertEqual(len(result.skipped), 0)


if __name__ == '__main__':
    unittest.main()
