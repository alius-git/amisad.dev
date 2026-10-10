#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
"""Restored-cluster gates in private paths, with real loopback HTTP probes."""
import contextlib
import http.server
import json
import os
from pathlib import Path
import shutil
import shlex
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import unittest

from bash_contract_support import find_usable_bash

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'test/ubuntu.server.24/ubuntu.server.24.amisad-core.ready.sh'
BASH = find_usable_bash()
SERVICES = ['seller-svc', 'resource-svc', 'ads-svc', 'insights-svc', 'platform-svc',
            'audit-svc', 'connect-svc', 'fabric-coordinator', 'identity-mock', 'ledger-svc']


def write_command(root, name, body):
    path = root / 'bin' / name
    path.write_bytes(('#!/bin/bash\n' + body + '\n').encode())
    path.chmod(0o755)


def run_case(root, env=None, timeout=8):
    return subprocess.run([BASH, '-c', 'export PATH="$PWD/bin:$PATH"; exec "$BASH" case.sh'],
                          cwd=root, env={**os.environ, 'USER': 'amisad-fixture', 'SUDO_USER': '',
                                         'HOME': (root / 'home').as_posix(), **(env or {})}, capture_output=True,
                          text=True, timeout=timeout)


@contextlib.contextmanager
def peer(responses=None, stall=0, observed_auth=None, tls_context=None):
    requests = []
    responses = responses or [200]

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            if observed_auth is not None:
                observed_auth.append(self.headers.get('Authorization'))
            index = len(requests) - 1
            if stall:
                time.sleep(stall)
            self.send_response(responses[min(index, len(responses) - 1)])
            self.end_headers()
            try:
                self.wfile.write(b'healthy\n')
            except (BrokenPipeError, ConnectionResetError):
                pass

        def log_message(self, *_):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    if tls_context is not None:
        server.socket = tls_context.wrap_socket(server.socket, server_side=True)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server.server_port, requests
    finally:
        server.shutdown()
        server.server_close()


@unittest.skipUnless(BASH, 'A usable native-filesystem Bash is required for guest shell contracts')
class ClusterGates(unittest.TestCase):
    def fixture(self, directory, subnet=True, short_budget=False):
        root = Path(directory)
        (root / 'bin').mkdir()
        text = SCRIPT.read_text()
        self.assertIn('amisad_wait_apiserver 300 ||', text)
        self.assertIn('amisad_wait_flannel 300 ||', text)
        text = text.replace('amisad_wait_apiserver 300 ||', 'amisad_wait_apiserver 3 ||')
        text = text.replace('amisad_wait_flannel 300 ||', 'amisad_wait_flannel 3 ||')
        text = text.replace('/run/flannel/subnet.env', shlex.quote((root / 'subnet.env').as_posix()))
        if short_budget:
            text = text.replace('amisad_wait_nodeport "$NODE_IP" "$port" ||',
                                'amisad_wait_nodeport "$NODE_IP" "$port" 0 ||')
        text = 'sleep() { SECONDS=$((SECONDS + $1)); }\n' + text
        (root / 'case.sh').write_bytes(text.encode())
        if subnet:
            (root / 'subnet.env').write_text('FLANNEL_SUBNET=fixture\n')
        write_command(root, 'sudo', 'echo "sudo $*" >> actions')
        write_command(root, 'hostname', 'echo 127.0.0.1')
        write_command(root, 'sleep', ':')
        write_command(root, 'kubectl', 'echo "kubectl $*" >> actions\n'
                      'if [ -n "${FAIL_KUBECTL:-}" ] && [[ "$*" == *"$FAIL_KUBECTL"* ]]; '
                      'then exit 17; fi')
        write_command(root, 'curl', 'echo "curl $*" >> actions\nexit "${CURL_RC:-0}"')
        return root

    def test_every_restart_rollout_and_nodeport_still_required(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(directory)
            result = run_case(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            actions = (root / 'actions').read_text().splitlines()
            api = [a for a in actions if 'get --raw=/readyz' in a]
            self.assertEqual(api, ['kubectl --request-timeout=2s get --raw=/readyz'])
            restarts = [a for a in actions if 'rollout restart' in a]
            self.assertEqual(restarts, ['kubectl -n kube-system rollout restart deployment/coredns',
                                       'kubectl -n amisad rollout restart deployment'])
            rollouts = [a for a in actions if 'rollout status' in a]
            self.assertEqual(len(rollouts), 11)
            self.assertTrue(all(f'deployment/{service} --timeout=600s' in '\n'.join(rollouts)
                                for service in SERVICES))
            checks = [a for a in actions if a.startswith('curl ')]
            self.assertEqual(len(checks), 10, 'a successful health check must not be repeated')
            for port, check in zip(range(30080, 30090), checks):
                self.assertIn(f'http://127.0.0.1:{port}/health', check)
                self.assertIn('--noproxy * --connect-timeout 1 --max-time 2 -sf', check)
            self.assertGreater(actions.index(checks[0]), actions.index(rollouts[-1]))
            self.assertIn('every NodePort answering', result.stdout)

    def test_api_failure_prevents_restarts_and_http(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(directory)
            result = run_case(root, {'FAIL_KUBECTL': 'get --raw=/readyz'})
            self.assertEqual(result.returncode, 9)
            actions = (root / 'actions').read_text()
            self.assertNotIn('rollout', actions)
            self.assertNotIn('curl ', actions)
            self.assertIn('apiserver never answered', result.stderr)

    def test_this_boot_flannel_file_still_required(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(directory, subnet=False)
            result = run_case(root)
            self.assertEqual(result.returncode, 9)
            actions = (root / 'actions').read_text()
            self.assertNotIn('rollout', actions)
            self.assertNotIn('curl ', actions)
            self.assertIn('flannel never wrote', result.stderr)

    def test_empty_flannel_file_is_not_ready(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(directory)
            (root / 'subnet.env').write_text('')
            result = run_case(root)
            self.assertEqual(result.returncode, 9)
            self.assertNotIn('rollout', (root / 'actions').read_text())

    def test_restart_and_each_rollout_failure_prevent_http(self):
        failures = ['rollout restart deployment/coredns', 'rollout restart deployment',
                    'rollout status deployment/coredns']
        failures += [f'rollout status deployment/{service}' for service in SERVICES]
        for failure in failures:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as directory:
                root = self.fixture(directory)
                result = run_case(root, {'FAIL_KUBECTL': failure})
                self.assertEqual(result.returncode, 17, result.stderr)
                self.assertNotIn('curl ', (root / 'actions').read_text())

    def test_health_budget_failure_stops_before_scenario_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(directory, short_budget=True)
            result = run_case(root)
            self.assertEqual(result.returncode, 8)
            self.assertIn('NodePort 30080 never answered', result.stderr)
            self.assertIn('budget (0s) expired', result.stderr)
            self.assertNotIn('is in position:', result.stdout)


@unittest.skipUnless(BASH, 'A usable native-filesystem Bash is required for guest shell contracts')
class RestoredGateInputs(unittest.TestCase):
    def run_gate(self, name, budget, ready_after=None, file_after=None, api_error=''):
        source = SCRIPT.read_text()
        self.assertIn(name + '() {', source)
        function = name + '() {' + source.split(name + '() {', 1)[1].split('\n}', 1)[0] + '\n}\n'
        with tempfile.TemporaryDirectory(prefix='amisad gates ') as directory:
            root = Path(directory)
            (root / 'bin').mkdir()
            function = function.replace('/run/flannel/subnet.env', shlex.quote((root / 'subnet.env').as_posix()))
            write_command(root, 'kubectl', 'echo "$*" >> calls\n'
                          'count=0; if [ -f count ]; then read -r count < count; fi\n'
                          'count=$((count + 1)); echo "$count" > count\n'
                          'printf "%s" "${API_ERROR:-}" >&2\n'
                          '[ -n "${READY_AFTER:-}" ] && [ "$count" -ge "$READY_AFTER" ]')
            prefix = '''set -euo pipefail
sleep() {
    echo "$1" >> sleeps
    SECONDS=$((SECONDS + $1))
    if [ -n "${FILE_AFTER:-}" ] && [ "$SECONDS" -ge "$FILE_AFTER" ]; then
        printf 'FLANNEL_SUBNET=fixture\\n' > subnet.env
    fi
}
'''
            (root / 'case.sh').write_bytes((prefix + function + f'{name} {budget}\n').encode())
            result = run_case(root, {'READY_AFTER': '' if ready_after is None else str(ready_after),
                                     'FILE_AFTER': '' if file_after is None else str(file_after),
                                     'API_ERROR': api_error})
            calls = (root / 'calls').read_text().splitlines() if (root / 'calls').exists() else []
            sleeps = (root / 'sleeps').read_text().splitlines() if (root / 'sleeps').exists() else []
            return result, calls, sleeps

    def test_healthy_api_uses_one_authenticated_kubectl_request(self):
        result, calls, sleeps = self.run_gate('amisad_wait_apiserver', 300, ready_after=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ['--request-timeout=2s get --raw=/readyz'])
        self.assertEqual(sleeps, [])
        self.assertNotIn('--server', calls[0])
        self.assertNotIn('--kubeconfig', calls[0])
        self.assertNotIn('--insecure-skip-tls-verify', calls[0])

    def test_api_recovers_after_one_second_retry(self):
        result, calls, sleeps = self.run_gate('amisad_wait_apiserver', 300, ready_after=2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, ['--request-timeout=2s get --raw=/readyz'] * 2)
        self.assertEqual(sleeps, ['1'])

    def test_api_failure_deadline_bounds_final_request_and_sleep(self):
        result, calls, sleeps = self.run_gate('amisad_wait_apiserver', 3)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, ['--request-timeout=2s get --raw=/readyz'] * 2 +
                                ['--request-timeout=1s get --raw=/readyz'])
        self.assertEqual(sleeps, ['1'] * 3)

    def test_expired_api_budget_does_not_start_another_request(self):
        result, calls, sleeps = self.run_gate('amisad_wait_apiserver', 0, ready_after=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])
        self.assertEqual(sleeps, [])

    def test_api_permission_and_tls_failure_detail_survives_budget_expiry(self):
        for detail in ('Error from server (Forbidden): fixture access refused',
                       'Unable to connect to the server: x509: certificate signed by unknown authority'):
            with self.subTest(detail=detail):
                result, calls, _ = self.run_gate('amisad_wait_apiserver', 2, api_error=detail)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(len(calls), 2)
                self.assertIn(detail, result.stderr)

    def test_api_failure_detail_is_bounded_without_an_extra_request(self):
        result, calls, _ = self.run_gate('amisad_wait_apiserver', 1, api_error='x' * 5000 + 'omitted-tail')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 1)
        self.assertIn('x' * 4096, result.stderr)
        self.assertNotIn('x' * 4097, result.stderr)
        self.assertNotIn('omitted-tail', result.stderr)

    def test_current_boot_file_is_observed_with_one_second_cadence(self):
        result, calls, sleeps = self.run_gate('amisad_wait_flannel', 300, file_after=2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [])
        self.assertEqual(sleeps, ['1', '1'])

    def test_missing_current_boot_file_stops_at_budget(self):
        result, calls, sleeps = self.run_gate('amisad_wait_flannel', 3)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])
        self.assertEqual(sleeps, ['1'] * 3)

    def test_expired_file_budget_does_not_sleep(self):
        result, calls, sleeps = self.run_gate('amisad_wait_flannel', 0, file_after=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])
        self.assertEqual(sleeps, [])


@unittest.skipUnless(BASH and shutil.which('curl'), 'Usable Bash and curl are required')
class RealNodePortHttp(unittest.TestCase):
    def probe(self, port, budget=2, env=None):
        source = SCRIPT.read_text()
        function = 'amisad_wait_nodeport() {' + source.split('amisad_wait_nodeport() {', 1)[1].split('\n}', 1)[0] + '\n}\n'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'bin').mkdir()
            (root / 'case.sh').write_bytes(('set -euo pipefail\n' + function +
                                            f'amisad_wait_nodeport 127.0.0.1 {port} {budget}\n').encode())
            started = time.monotonic()
            result = run_case(root, env)
            return result, time.monotonic() - started

    def test_success_uses_one_real_health_get(self):
        with peer() as (port, requests):
            result, elapsed = self.probe(port)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(requests, ['/health'])
        self.assertLess(elapsed, 2)

    def test_http_failure_can_recover_on_next_probe(self):
        with peer([503, 200]) as (port, requests):
            result, elapsed = self.probe(port, budget=4)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(requests, ['/health', '/health'])
        self.assertGreaterEqual(elapsed, 0.9)
        self.assertLess(elapsed, 3)

    def test_failed_http_statuses_never_count_as_healthy(self):
        for status in (404, 503):
            with self.subTest(status=status), peer([status]) as (port, requests):
                result, elapsed = self.probe(port)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('last curl exit: 22', result.stderr)
                self.assertGreaterEqual(len(requests), 1)
                self.assertLess(elapsed, 3)

    def test_connection_refusal_has_bounded_retries(self):
        with socket.socket() as reserved:
            reserved.bind(('127.0.0.1', 0))
            port = reserved.getsockname()[1]
            result, elapsed = self.probe(port)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('last curl exit: 7', result.stderr)
        self.assertLess(elapsed, 3)

    def test_accepted_connection_that_stalls_is_bounded(self):
        with peer(stall=10) as (port, requests):
            result, elapsed = self.probe(port, budget=2)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('last curl exit: 28', result.stderr)
        self.assertEqual(requests, ['/health'])
        self.assertLess(elapsed, 3)

    def test_last_request_fits_short_remaining_budget(self):
        with peer(stall=10) as (port, requests):
            result, elapsed = self.probe(port, budget=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(requests, ['/health'])
        self.assertLess(elapsed, 2)

    def test_nodeport_bypasses_http_and_all_proxy_environment(self):
        with peer() as (port, requests), peer([502]) as (proxy_port, proxy_requests):
            proxy = f'http://127.0.0.1:{proxy_port}'
            result, _ = self.probe(port, env={'http_proxy': proxy, 'HTTP_PROXY': proxy,
                                             'all_proxy': proxy, 'ALL_PROXY': proxy,
                                             'NO_PROXY': '', 'no_proxy': ''})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(requests, ['/health'])
        self.assertEqual(proxy_requests, [])


@unittest.skipUnless(BASH and shutil.which('kubectl'), 'Usable Bash and kubectl are required')
class RealApiHttp(unittest.TestCase):
    def probe(self, port, budget=2, tls_ca=None):
        source = SCRIPT.read_text()
        function = 'amisad_wait_apiserver() {' + source.split('amisad_wait_apiserver() {', 1)[1].split('\n}', 1)[0] + '\n}\n'
        with tempfile.TemporaryDirectory(prefix='amisad API ') as directory:
            root = Path(directory)
            (root / 'bin').mkdir()
            config = root / 'config'
            scheme = 'https' if tls_ca is not None else 'http'
            ca = '' if tls_ca is None else '\n    certificate-authority: ' + json.dumps(str(tls_ca))
            config.write_text(f'''apiVersion: v1
kind: Config
clusters:
- name: fixture
  cluster:
    server: {scheme}://127.0.0.1:{port}{ca}
users:
- name: fixture
  user:
    token: fixture-contract-token
contexts:
- name: fixture
  context:
    cluster: fixture
    user: fixture
current-context: fixture
''')
            (root / 'case.sh').write_bytes(('set -euo pipefail\n' + function +
                                            f'amisad_wait_apiserver {budget}\n').encode())
            started = time.monotonic()
            result = run_case(root, {'KUBECONFIG': str(config)})
            return result, time.monotonic() - started

    @unittest.skipUnless(shutil.which('openssl'), 'OpenSSL is required for the private TLS peer')
    def test_real_client_preserves_kubeconfig_authentication_and_readyz(self):
        auth = []
        with tempfile.TemporaryDirectory(prefix='amisad TLS ') as directory:
            root = Path(directory)
            cert, key = root / 'cert.pem', root / 'key.pem'
            configuration = root / 'openssl.cnf'
            configuration.write_text('[req]\ndistinguished_name=dn\nx509_extensions=v3\nprompt=no\n'
                                     '[dn]\nCN=localhost\n[v3]\nsubjectAltName=IP:127.0.0.1\n'
                                     'basicConstraints=critical,CA:true\n')
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
                            '-keyout', str(key), '-out', str(cert), '-days', '1',
                            '-config', str(configuration)], check=True, stdout=subprocess.DEVNULL,
                           stderr=subprocess.PIPE, timeout=15)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(cert, key)
            with peer(observed_auth=auth, tls_context=context) as (port, requests):
                result, elapsed = self.probe(port, tls_ca=cert)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(requests, ['/readyz?timeout=2s'])
        self.assertEqual(auth, ['Bearer fixture-contract-token'])
        self.assertLess(elapsed, 2)

    def test_real_client_recovers_after_api_503(self):
        with peer([503, 200]) as (port, requests):
            result, elapsed = self.probe(port, budget=4)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(requests, ['/readyz?timeout=2s', '/readyz?timeout=2s'])
        self.assertLess(elapsed, 3)

    def test_real_api_failure_remains_nonzero_at_deadline(self):
        with peer([503]) as (port, requests):
            result, elapsed = self.probe(port)
        self.assertNotEqual(result.returncode, 0)
        self.assertGreaterEqual(len(requests), 1)
        self.assertIn('last kubectl exit: 1', result.stderr)
        self.assertLess(elapsed, 3)

    def test_real_api_stall_cannot_outlive_remaining_request_budget(self):
        with peer(stall=10) as (port, requests):
            result, elapsed = self.probe(port, budget=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(requests, ['/readyz?timeout=1s'])
        self.assertLess(elapsed, 2)

    def test_expired_real_api_budget_does_not_make_a_request(self):
        with peer() as (port, requests):
            result, _ = self.probe(port, budget=0)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(requests, [])


if __name__ == '__main__':
    unittest.main()
