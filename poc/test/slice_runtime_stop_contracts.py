#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
"""Stopping slice-runtime before a scenario delivers its binary waits for the exit."""
import errno
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest

from bash_contract_support import find_usable_bash

ROOT = Path(__file__).resolve().parents[1]
HELPERS = ROOT / 'test/amisad-scenario.sh'
BASH = find_usable_bash()


def write_command(root, name, body):
    path = root / 'bin' / name
    path.write_bytes(('#!/bin/bash\n' + body + '\n').encode())
    path.chmod(0o755)
    return path


def wait_until(predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return predicate()


def named_instances():
    probe = subprocess.run(['pgrep', '-x', 'slice-runtime'], capture_output=True, text=True)
    return probe.stdout.split()


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


@unittest.skipUnless(BASH, 'A usable native-filesystem Bash is required for guest shell contracts')
@unittest.skipUnless(shutil.which('pgrep') and shutil.which('pkill'), 'procps pgrep/pkill are required')
class StopSliceRuntime(unittest.TestCase):
    def setUp(self):
        if named_instances():
            self.skipTest('a slice-runtime process already runs on this machine; the helper would stop it')
        self.directory = tempfile.TemporaryDirectory(prefix='amisad slice-runtime stop ')
        self.root = Path(self.directory.name)
        (self.root / 'bin').mkdir()
        self.started = []

    def tearDown(self):
        for pid in self.started:
            if alive(pid):
                os.kill(pid, 9)
                wait_until(lambda: not alive(pid))
        self.directory.cleanup()

    def helpers(self, term_ticks=None, kill_ticks=None):
        text = HELPERS.read_text()
        self.assertIn('\nterm_ticks=100\n', text)
        self.assertIn('\nkill_ticks=50\n', text)
        if term_ticks is not None:
            text = text.replace('\nterm_ticks=100\n', f'\nterm_ticks={term_ticks}\n')
        if kill_ticks is not None:
            text = text.replace('\nkill_ticks=50\n', f'\nkill_ticks={kill_ticks}\n')
        path = self.root / 'amisad-scenario.sh'
        path.write_text(text)
        return path

    def start(self, path, *arguments):
        # The lab starts the instance with `nohup ... &` from an SSH session that
        # then exits, so the process is reparented and reaped by init. A direct
        # child of this test would linger as a zombie that pgrep still lists.
        launched = subprocess.run([BASH, '-c', 'nohup "$0" "$@" >/dev/null 2>&1 & echo $!', path.as_posix(), *arguments],
                                  cwd=self.root, capture_output=True, text=True, timeout=10, check=True)
        pid = int(launched.stdout.strip())
        self.started.append(pid)
        self.assertTrue(wait_until(lambda: str(pid) in named_instances()),
                        'the fixture instance must be visible to pgrep -x slice-runtime')
        return pid

    def stop(self, helpers, target='', *ssh_options, timeout=20):
        call = ' '.join(['amisad_stop_slice_runtime', repr(target) if target else "''", *ssh_options])
        return subprocess.run([BASH, '-c', f'export PATH="$PWD/bin:$PATH"; . {helpers.as_posix()!r}; {call}'],
                              cwd=self.root, capture_output=True, text=True, timeout=timeout)

    def test_binary_is_writable_again_when_the_helper_returns(self):
        binary = self.root / 'bin' / 'slice-runtime'
        shutil.copy2(shutil.which('sleep'), binary)
        pid = self.start(binary, '300')
        try:
            with open(binary, 'ab'):
                pass
        except OSError as error:
            self.assertEqual(error.errno, errno.ETXTBSY)
        else:
            self.skipTest('this kernel allows writing to an executing binary; ETXTBSY cannot be shown here')
        result = self.stop(self.helpers())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f'stopped slice-runtime (pid {pid})', result.stdout)
        self.assertFalse(alive(pid), 'the previous instance must have exited, not merely been signaled')
        with open(binary, 'ab'):
            pass
        self.assertEqual(named_instances(), [])

    def test_slow_exit_is_waited_for_rather_than_raced(self):
        script = write_command(self.root, 'slice-runtime',
                               'trap "sleep 1; exit 0" TERM\nwhile :; do sleep 0.1; done')
        pid = self.start(script)
        started = time.monotonic()
        result = self.stop(self.helpers())
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(alive(pid))
        self.assertGreaterEqual(elapsed, 0.9, 'the helper returned before the instance had exited')
        self.assertNotIn('SIGKILL', result.stdout)

    def test_instance_ignoring_sigterm_is_killed_and_reported(self):
        script = write_command(self.root, 'slice-runtime', "trap '' TERM\nwhile :; do sleep 0.1; done")
        pid = self.start(script)
        result = self.stop(self.helpers(term_ticks=3))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(alive(pid))
        self.assertIn('SIGKILL', result.stdout)
        self.assertEqual(named_instances(), [])

    def test_no_instance_is_a_silent_success(self):
        result = self.stop(self.helpers())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, '')

    def test_survivor_fails_loudly_instead_of_handing_scp_a_busy_binary(self):
        write_command(self.root, 'pgrep', 'echo 4242')
        write_command(self.root, 'pkill', 'exit 0')
        result = self.stop(self.helpers(term_ticks=2, kill_ticks=2))
        self.assertEqual(result.returncode, 1)
        self.assertIn('slice-runtime (pid 4242) survived SIGTERM and SIGKILL', result.stderr)

    def test_edge_target_runs_the_whole_wait_in_one_ssh_session(self):
        recorded = self.root / 'ssh.args'
        write_command(self.root, 'ssh',
                      'n=$#; i=0\nfor a in "$@"; do i=$((i+1)); [ "$i" -lt "$n" ] && printf "%s\\n" "$a"; done '
                      f'> {recorded.as_posix()!r}\n'
                      'exec bash -c "${!#}"')
        script = write_command(self.root, 'slice-runtime', 'while :; do sleep 0.1; done')
        pid = self.start(script)
        result = self.stop(self.helpers(), 'amisad-edge-a-admin@192.0.2.10',
                           '-i', '"$HOME/.ssh/amisad-demo-key"', '-o', 'StrictHostKeyChecking=accept-new')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(alive(pid))
        self.assertEqual(recorded.read_text().splitlines(),
                         ['-i', os.path.expandvars('$HOME/.ssh/amisad-demo-key'), '-o',
                          'StrictHostKeyChecking=accept-new', 'amisad-edge-a-admin@192.0.2.10'])
        self.assertIn(f'stopped slice-runtime (pid {pid})', result.stdout)

    def test_every_edge_scenario_stops_through_the_helper_before_delivering(self):
        scenarios = sorted((ROOT / 'test/ubuntu.server.24').glob('ubuntu.server.24.amisad-core.s*.sh'))
        self.assertGreaterEqual(len(scenarios), 10)
        delivering = 0
        for scenario in scenarios:
            text = scenario.read_text()
            self.assertNotIn('pkill', text, f'{scenario.name} must stop slice-runtime through the helper')
            if 'slice-runtime "${' not in text and 'slice-runtime "${host}' not in text:
                continue
            delivering += 1
            # Every scp of the binary follows the stop directly (s004 keeps its
            # own error line between the two).
            for index in [i for i in range(len(text)) if text.startswith('    scp ', i)]:
                preceding = ' '.join(text[:index].rstrip().splitlines()[-2:])
                self.assertIn('amisad_stop_slice_runtime', preceding,
                              f'{scenario.name}: scp of slice-runtime without a completed stop before it')
            if 'single-VM degraded fallback' in text:
                self.assertIn("amisad_stop_slice_runtime ''", text,
                              f'{scenario.name}: the single-VM fallback must also wait for the previous instance')
        self.assertGreaterEqual(delivering, 9)


if __name__ == '__main__':
    unittest.main()
