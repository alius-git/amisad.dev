#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# GUID: 421a78ee-587e-449a-bae7-27c0919bc99a
"""The scenarios' slice-runtime start: the shared helper stops the previous
instance and waits for its exit before delivering the binary, starts the new one
on the edge (or, only when allowed, on this VM) with the ledger write token on
standard input, and fails the scenario when the runtime never answers."""
import base64
import errno
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import unittest

from bash_contract_support import find_usable_bash

ROOT = Path(__file__).resolve().parents[1]
HELPERS = ROOT / 'test/amisad-scenario.sh'
FAILOVER = ROOT / 'test/ubuntu.server.24/ubuntu.server.24.amisad-core.s004.failover.sh'
BASH = find_usable_bash()


def write_command(root, name, body):
    path = root / 'bin' / name
    path.write_bytes(('#!/bin/bash\n' + body + '\n').encode())
    path.chmod(0o755)
    return path


def function_text(path, name):
    """One top-level shell function, from its name to the closing brace in column 0."""
    match = re.search(r'(?ms)^' + re.escape(name) + r'\(\) \{.*?^\}', path.read_text())
    if not match:
        raise AssertionError(f'{name} is not defined in {path.name}')
    return match.group(0)


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
        starting = 0
        for scenario in scenarios:
            text = scenario.read_text()
            # The stop, the copy, the start, the edge login and the single-VM
            # gate exist once, in the helper, so no scenario can deliver
            # without the stop.
            for plumbing in ('pkill', 'scp', 'nohup', 'AMISAD_ALLOW_SINGLE_VM', 'amisad-demo-key'):
                self.assertIsNone(re.search(r'\b' + re.escape(plumbing) + r'\b', text),
                                  f'{scenario.name} must leave {plumbing} to the helper')
            if re.search(r'^\s*amisad_(start|deliver)_slice_runtime ', text, re.M):
                starting += 1
        self.assertGreaterEqual(starting, 9)
        lines = HELPERS.read_text().splitlines()
        copies = [index for index, line in enumerate(lines) if re.match(r'\s*scp\b', line)]
        self.assertTrue(copies, 'the helper must deliver the binary')
        for index in copies:
            # The stop's own error line may sit between the two.
            self.assertIn('amisad_stop_slice_runtime', ' '.join(lines[max(0, index - 2):index]),
                          'scp of slice-runtime without a completed stop before it')
        self.assertIn("amisad_stop_slice_runtime ''", function_text(HELPERS, 'amisad_start_slice_runtime'),
                      'the single-VM fallback must also wait for the previous instance')


# Every stub appends one record (its name and arguments, NUL-separated) in a
# single write, so a runtime started in the background cannot interleave with it.
RECORD = 'printf \'%s\\0\' "${0##*/}" "$@" $\'\\036\' >> "$AMISAD_FIXTURE_DIR/calls"'
# The ledger write token the kubectl stub serves from Secret amisad-ledger-write.
TOKEN = '5e' * 32
STUBS = {
    # Each ssh session's standard input lands in ssh.stdin, one record per call.
    'ssh': RECORD + '\nprintf \'%s\\036\' "$(cat)" >> "$AMISAD_FIXTURE_DIR/ssh.stdin"\n'
                    'case "${!#}" in *"hostname -I"*) echo "${FIXTURE_SELF_IP:-198.51.100.7}" ;; esac\n'
                    'exit "${FIXTURE_SSH_RC:-0}"',
    'scp': RECORD + '\nexit "${FIXTURE_SCP_RC:-0}"',
    'curl': RECORD + '\ncount="$AMISAD_FIXTURE_DIR/curl.count"\n'
                     'n=$(( $(cat "$count" 2>/dev/null || echo 0) + 1 ))\necho "$n" > "$count"\n'
                     '[ "${FIXTURE_CURL_FAILS:-0}" != always ] || exit 7\n'
                     '[ "$n" -gt "${FIXTURE_CURL_FAILS:-0}" ] || exit 7',
    'sleep': RECORD,
    'hostname': RECORD + '\necho "203.0.113.5 10.0.0.9"',
    'getent': RECORD + '\n[ -n "${FIXTURE_GETENT:-}" ] || exit 2\necho "$FIXTURE_GETENT"',
    'wget': RECORD + '\nexit 8',
    # One previous local instance that is gone once pkill has signaled it.
    'pgrep': RECORD + '\nseen="$AMISAD_FIXTURE_DIR/pgrep.seen"\n'
                      'if [ -n "${FIXTURE_LOCAL_INSTANCE:-}" ] && [ ! -e "$seen" ]; then : > "$seen"; echo 4242; exit 0; fi\n'
                      'exit 1',
    'pkill': RECORD,
    'kubectl': RECORD + '\nif [ -n "${FIXTURE_NO_SECRET:-}" ]; then\n'
                        '    echo \'Error from server (NotFound): secrets "amisad-ledger-write" not found\' >&2; exit 1\nfi\n'
                        f"printf %s '{base64.b64encode(TOKEN.encode()).decode()}'",
}
RUNTIME = ('#!/bin/bash\nprintf \'%s\\0\' slice-runtime "PORT=${PORT-<unset>}" "REGION=${REGION-<unset>}" '
           '"LEDGER_URL=${LEDGER_URL-<unset>}" "RESOURCE_URL=${RESOURCE_URL-<unset>}" '
           '"LEDGER_WRITE_TOKEN=${LEDGER_WRITE_TOKEN-<unset>}" $\'\\036\' '
           '>> "$AMISAD_FIXTURE_DIR/calls"\n')
STOP_MARK = 'pgrep -x slice-runtime'


@unittest.skipUnless(BASH, 'A usable native-filesystem Bash is required for guest shell contracts')
class StartSliceRuntime(unittest.TestCase):
    """The helper the scenarios start slice-runtime with, against PATH stubs in a
    private directory; nothing here reaches a network, an edge or a process
    of this machine."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='amisad slice-runtime start ')
        self.root = Path(self.directory.name)
        (self.root / 'bin').mkdir()
        for name, body in STUBS.items():
            write_command(self.root, name, body)
        (self.root / 'target/release').mkdir(parents=True)
        runtime = self.root / 'target/release/slice-runtime'
        runtime.write_text(RUNTIME)
        runtime.chmod(0o755)
        self.key = (self.root / 'admin home/.ssh/amisad-demo-key').as_posix()
        self.login = ['-i', self.key, '-o', 'StrictHostKeyChecking=accept-new']

    def tearDown(self):
        self.directory.cleanup()

    def host_env(self):
        (self.root / 'host.env').write_text('YURUNA_STATUS_SERVICE_IP=192.0.2.1\nYURUNA_STATUS_SERVICE_PORT=8080\n')

    def run_case(self, script, **env):
        text = HELPERS.read_text()
        for real, fixture in [('/etc/yuruna/host.env', './host.env'),
                              ('/usr/local/lib/yuruna/yuruna-host-locate.sh', './no-locator.sh')]:
            self.assertIn(real, text)
            text = text.replace(real, fixture)
        # The local start's log; the single-VM case proves it landed here.
        text = text.replace('nohup target/release/slice-runtime >/tmp/slice-runtime.log',
                            'nohup target/release/slice-runtime >runtime.log')
        (self.root / 'amisad-scenario.sh').write_text(text)
        environment = {key: value for key, value in os.environ.items()
                       if key not in ('EDGE_HOST', 'AMISAD_ALLOW_SINGLE_VM') and not key.startswith('YURUNA_')}
        environment.update(REAL_HOME=(self.root / 'admin home').as_posix(), AMISAD_FIXTURE_DIR=self.root.as_posix(), **env)
        return subprocess.run([BASH, '-c', 'set -euo pipefail\nexport PATH="$PWD/bin:$PATH"\n. ./amisad-scenario.sh\n' + script],
                              cwd=self.root, env=environment, stdin=subprocess.DEVNULL, capture_output=True, text=True,
                              timeout=30)

    def calls(self, *names):
        path = self.root / 'calls'
        records = [record.split('\0')[:-1] for record in path.read_text().split('\x1e\0') if record] if path.exists() else []
        return [record for record in records if not names or record[0] in names]

    def test_edge_start_stops_delivers_and_starts_on_the_edge(self):
        self.host_env()
        result = self.run_case('amisad_start_slice_runtime http://L http://R region-a\necho "SLICE_EP=$SLICE_EP"',
                               FIXTURE_GETENT='192.168.122.50 amisad-edge-a')
        self.assertEqual(result.returncode, 0, result.stderr)
        target = 'amisad-edge-a-admin@192.168.122.50'
        self.assertIn(f'edge: {target}\n', result.stdout)
        delivery = self.calls('ssh', 'scp')
        self.assertEqual(len(delivery), 4, delivery)
        self.assertEqual(delivery[0][:-1], ['ssh', *self.login, target])
        self.assertIn(STOP_MARK, delivery[0][-1], 'the previous instance is stopped first, in one session')
        self.assertEqual(delivery[1], ['scp', *self.login, 'target/release/slice-runtime', f'{target}:/tmp/slice-runtime'])
        self.assertEqual(delivery[2], ['ssh', *self.login, target,
                                       'IFS= read -r LEDGER_WRITE_TOKEN; export LEDGER_WRITE_TOKEN; '
                                       'PORT=8080 REGION=region-a LEDGER_URL=http://L RESOURCE_URL=http://R '
                                       'nohup /tmp/slice-runtime >/tmp/slice-runtime.log 2>&1 & sleep 1; echo edge-started'])
        self.assertEqual(delivery[3], ['ssh', *self.login, target, "hostname -I | awk '{print $1}'"])
        # The endpoint is the address the edge reports for itself.
        self.assertEqual(self.calls('curl'), [['curl', '-sf', 'http://198.51.100.7:8080/health']] * 2)
        self.assertIn('slice-runtime at http://198.51.100.7:8080\nSLICE_EP=http://198.51.100.7:8080\n', result.stdout)
        self.assertEqual(self.calls('pgrep', 'pkill', 'slice-runtime'), [], 'nothing runs on this VM')

    def test_explicit_edge_host_wins_over_the_status_service(self):
        self.host_env()
        target = 'amisad-edge-a-admin@192.0.2.10'
        result = self.run_case('amisad_start_slice_runtime http://L http://R',
                               EDGE_HOST=target, FIXTURE_GETENT='192.168.122.50 amisad-edge-a')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f'edge: {target}\n', result.stdout)
        self.assertEqual(self.calls('getent', 'wget'), [], 'an explicit EDGE_HOST is not looked up')
        delivery = self.calls('ssh', 'scp')
        self.assertEqual([record[-2] for record in delivery if record[0] == 'ssh'], [target] * 3)
        # No region given: slice-runtime reads an empty REGION as no identity.
        self.assertIn('; PORT=8080 REGION= LEDGER_URL=http://L RESOURCE_URL=http://R nohup ', delivery[2][-1])

    def test_unresolved_edge_refuses_without_the_single_vm_opt_in(self):
        self.host_env()
        result = self.run_case('amisad_start_slice_runtime http://L http://R\necho after')
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn('AMISAD_ALLOW_SINGLE_VM is not set: refusing to assert a distributed scenario', result.stderr)
        self.assertNotIn('after', result.stdout)
        self.assertNotIn('slice-runtime at', result.stdout)
        self.assertTrue(self.calls('getent'), 'the edge was looked up before refusing')
        self.assertEqual(self.calls('ssh', 'scp', 'pgrep', 'pkill', 'curl', 'slice-runtime'), [])

    def test_single_vm_opt_in_starts_here_on_8090_after_the_stop(self):
        result = self.run_case('amisad_start_slice_runtime http://L http://R region-a\necho "SLICE_EP=$SLICE_EP"',
                               AMISAD_ALLOW_SINGLE_VM='1', FIXTURE_LOCAL_INSTANCE='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('edge unresolved - slice-runtime on this VM (single-VM degraded fallback)\n'
                      'stopped slice-runtime (pid 4242)\n', result.stdout)
        self.assertTrue(wait_until(lambda: self.calls('slice-runtime')), 'the local runtime never started')
        names = [record[0] for record in self.calls()]
        self.assertLess(names.index('pkill'), names.index('slice-runtime'), 'started before the previous instance was gone')
        self.assertEqual(self.calls('slice-runtime'), [['slice-runtime', 'PORT=8090', 'REGION=region-a',
                                                        'LEDGER_URL=http://L', 'RESOURCE_URL=http://R',
                                                        f'LEDGER_WRITE_TOKEN={TOKEN}']])
        self.assertIn('slice-runtime at http://203.0.113.5:8090\nSLICE_EP=http://203.0.113.5:8090\n', result.stdout)
        self.assertEqual(self.calls('ssh', 'scp'), [])
        self.assertTrue((self.root / 'runtime.log').exists(), 'the fixture must keep the local start out of /tmp')

    def test_a_slice_that_never_answers_ends_the_scenario(self):
        result = self.run_case('amisad_start_slice_runtime http://L http://R\necho after',
                               EDGE_HOST='amisad-edge-a-admin@192.0.2.10', FIXTURE_CURL_FAILS='always')
        self.assertEqual(result.returncode, 7, 'the scenario must end with the last probe\'s status')
        self.assertNotIn('slice-runtime at', result.stdout)
        self.assertNotIn('after', result.stdout)
        self.assertEqual(self.calls('curl'), [['curl', '-sf', 'http://198.51.100.7:8080/health']] * 16)
        self.assertEqual(self.calls('sleep'), [['sleep', '2']] * 15)

    def test_health_wait_returns_once_the_slice_answers(self):
        result = self.run_case('amisad_wait_slice_runtime http://192.0.2.20:8080\necho waited', FIXTURE_CURL_FAILS='2')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('waited', result.stdout)
        self.assertEqual(len(self.calls('curl')), 4)
        self.assertEqual(self.calls('sleep'), [['sleep', '2']] * 2)

    def ssh_stdin(self):
        path = self.root / 'ssh.stdin'
        return path.read_text().split('\x1e')[:-1] if path.exists() else []

    def test_the_ledger_write_token_reaches_the_edge_on_standard_input_only(self):
        self.host_env()
        result = self.run_case('set -x\namisad_start_slice_runtime http://L http://R region-a',
                               FIXTURE_GETENT='192.168.122.50 amisad-edge-a')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls('kubectl'), [['kubectl', '-n', 'amisad', 'get', 'secret', 'amisad-ledger-write',
                                                  '-o', 'jsonpath={.data.token}']])
        # Stop, start and address sessions, in order; only the start reads the token.
        self.assertEqual(self.ssh_stdin(), ['', TOKEN, ''])
        for record in self.calls():
            self.assertNotIn(TOKEN, ' '.join(record), 'the token is in an argument list')
        self.assertNotIn(TOKEN, result.stdout + result.stderr, 'the token is in the output or the trace')
        self.assertIn('+ amisad_start_slice_runtime', result.stderr, 'the trace was on')
        leftovers = [path.name for path in self.root.rglob('*') if path.is_file() and path.name != 'ssh.stdin'
                     and TOKEN.encode() in path.read_bytes()]
        self.assertEqual(leftovers, [], 'the token is in a file')
        # The edge side of the start: its shell reads the line into the runtime's environment.
        start = self.calls('ssh')[1][-1].replace('/tmp/slice-runtime >/tmp/slice-runtime.log', 'target/release/slice-runtime >edge.log')
        edge = subprocess.run([BASH, '-c', start], cwd=self.root, input=TOKEN + '\n', capture_output=True, text=True,
                              env={**os.environ, 'AMISAD_FIXTURE_DIR': self.root.as_posix()}, timeout=30)
        self.assertEqual(edge.returncode, 0, edge.stderr)
        self.assertTrue(wait_until(lambda: self.calls('slice-runtime')), 'the edge runtime never started')
        self.assertEqual(self.calls('slice-runtime'), [['slice-runtime', 'PORT=8080', 'REGION=region-a', 'LEDGER_URL=http://L',
                                                        'RESOURCE_URL=http://R', f'LEDGER_WRITE_TOKEN={TOKEN}']])

    def test_a_missing_token_secret_starts_the_edge_without_one_and_says_so(self):
        result = self.run_case('amisad_start_slice_runtime http://L http://R',
                               EDGE_HOST='amisad-edge-a-admin@192.0.2.10', FIXTURE_NO_SECRET='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('no ledger write token from Secret amisad/amisad-ledger-write; slice-runtime starts without one',
                      result.stderr)
        self.assertEqual(self.ssh_stdin(), ['', '', ''])
        self.assertIn('slice-runtime at http://198.51.100.7:8080', result.stdout)

    def test_the_single_vm_start_sets_the_token_without_showing_it(self):
        result = self.run_case('set -x\namisad_start_slice_runtime http://L http://R\necho "after: ${LEDGER_WRITE_TOKEN-<unset>}"',
                               AMISAD_ALLOW_SINGLE_VM='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(wait_until(lambda: self.calls('slice-runtime')), 'the local runtime never started')
        self.assertEqual(self.calls('slice-runtime')[0][-1], f'LEDGER_WRITE_TOKEN={TOKEN}')
        self.assertIn('after: <unset>', result.stdout, 'the token stays out of the scenario shell')
        self.assertNotIn(TOKEN, result.stdout + result.stderr)
        for record in self.calls('kubectl', 'pgrep', 'pkill', 'curl'):
            self.assertNotIn(TOKEN, ' '.join(record))

    def test_failover_delivery_fails_loudly_inside_command_substitution(self):
        # s004 starts both edges inside $( ), where errexit does not reach.
        script = ('LEDGER=http://L\nRESOURCE=http://R\n' + function_text(FAILOVER, 'start_slice') +
                  '\nEDGE_B_IP=$(start_slice amisad-edge-b region-b | tail -n 1)\necho "after ${EDGE_B_IP}"')
        result = self.run_case(script, FIXTURE_GETENT='192.168.122.51 amisad-edge-b', FIXTURE_SCP_RC='1')
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertIn('copying slice-runtime to amisad-edge-b-admin@192.168.122.51 failed', result.stderr)
        self.assertIn('slice-runtime delivery to amisad-edge-b (192.168.122.51) failed', result.stderr)
        self.assertNotIn('after', result.stdout)
        delivery = self.calls('ssh', 'scp')
        self.assertEqual([record[0] for record in delivery], ['ssh', 'scp'], 'nothing is started after a failed copy')
        self.assertIn(STOP_MARK, delivery[0][-1])


if __name__ == '__main__':
    unittest.main()
