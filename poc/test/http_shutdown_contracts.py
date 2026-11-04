#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# GUID: 42636291-b9b9-4565-b0a4-39ee384ffc56
"""Shared HTTP lifecycle contracts; only rustc and Python's standard library are required.

Normal HTTP contracts run on Windows as well. SIGTERM contracts require Unix;
the Linux PID 1 cases additionally require working unprivileged PID namespaces.
Set RUSTC or AMISAD_LIFECYCLE_BINARY to use a particular compiler or built fixture.
"""
import contextlib
import http.client
import http.server
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


def wait_for(predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.01)
    raise TimeoutError('condition did not become true')


def read_reply(connection):
    """Everything the server writes before it closes the connection.

    A server that refuses a request before reading all of it closes with input
    unread, which resets the connection after the answer was already sent.
    """
    reply = b''
    try:
        while chunk := connection.recv(4096):
            reply += chunk
    except ConnectionResetError:
        if not reply:
            raise
    return reply


class RunningService:
    def __init__(self, binary, directory, pid1=False, port=None):
        self.directory = directory
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            self.port = port or reservation.getsockname()[1]
        self.log = tempfile.TemporaryFile()
        command = [str(binary)]
        if pid1:
            command = ['unshare', '--user', '--map-root-user', '--pid', '--fork', '--kill-child', *command]
        self.process = subprocess.Popen(command, stdout=self.log, stderr=self.log,
                                        env={**os.environ, 'PORT': str(self.port),
                                             'JOURNAL_DIRECTORY': str(directory)})
        self.pid1 = pid1
        self.signal_pid = self.process.pid
        self.binary = binary

    def start(self):
        def ready():
            if self.process.poll() is not None:
                self.log.seek(0)
                raise RuntimeError(self.log.read().decode(errors='replace'))
            try:
                return self.call('/health')[0] == 200
            except (OSError, http.client.HTTPException):
                return False
        wait_for(ready)
        if self.pid1:
            if self.directory.joinpath('pid').read_text() != '1':
                raise AssertionError('fixture is not PID 1 in its namespace')
            children = Path(f'/proc/{self.process.pid}/task/{self.process.pid}/children').read_text().split()
            if len(children) != 1:
                raise AssertionError('expected exactly one owned unshare child')
            child = int(children[0])
            if Path(f'/proc/{child}/exe').resolve() != self.binary.resolve():
                raise AssertionError('unshare child is not the fixture executable')
            self.signal_pid = child
        return self

    def call(self, path, body=None, timeout=5):
        status, _, payload = self.exchange(path, body, timeout=timeout)
        return status, payload

    def exchange(self, path, body=None, headers=None, timeout=5):
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=timeout)
        try:
            connection.request('GET' if body is None else 'POST', path, body=body, headers=headers or {})
            response = connection.getresponse()
            return response.status, response.headers, json.loads(response.read())
        finally:
            connection.close()

    def output(self):
        self.log.seek(0)
        return self.log.read().decode(errors='replace')

    def terminate(self):
        os.kill(self.signal_pid, signal.SIGTERM)

    def close(self):
        # Only the process created above is killed; unshare's --kill-child also
        # tears down its private PID namespace when a baseline test times out.
        if self.process.poll() is None:
            self.process.kill()
        self.process.wait(timeout=5)
        self.log.close()


class LifecycleFixture(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='amisad-http-lifecycle-')
        cls.addClassCleanup(cls.build.cleanup)
        supplied = os.environ.get('AMISAD_LIFECYCLE_BINARY')
        if supplied:
            cls.binary = Path(supplied).resolve()
        else:
            compiler = os.environ.get('RUSTC') or shutil.which('rustc')
            if not compiler:
                raise unittest.SkipTest('rustc is required; set RUSTC or AMISAD_LIFECYCLE_BINARY')
            output = Path(cls.build.name)
            library = output / 'libamisad_common.rlib'
            cls.binary = output / ('http-lifecycle.exe' if os.name == 'nt' else 'http-lifecycle')
            subprocess.run([compiler, '--edition=2021', '--crate-name', 'amisad_common',
                            '--crate-type', 'rlib', str(ROOT / 'components/lib/amisad-common/src/lib.rs'),
                            '-o', str(library)], check=True, timeout=60)
            subprocess.run([compiler, '--edition=2021', str(ROOT / 'test/fixtures/http_lifecycle.rs'),
                            '--extern', f'amisad_common={library}', '-o', str(cls.binary)], check=True, timeout=60)

    @contextlib.contextmanager
    def service(self, directory=None, pid1=False, port=None):
        with contextlib.ExitStack() as stack:
            if directory is None:
                directory = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix='amisad-journal-')))
            running = RunningService(self.binary, directory, pid1, port)
            stack.callback(running.close)
            yield running.start()

    def assert_graceful_exit(self, service):
        self.assertEqual(service.process.wait(timeout=3), 0)
        self.assertTrue(service.directory.joinpath('dropped').exists(), 'service state was not dropped')
        with self.assertRaises(OSError):
            socket.create_connection(('127.0.0.1', service.port), timeout=.2)


class HttpLifecycle(LifecycleFixture):
    def test_health_and_version_keep_their_contract(self):
        with self.service() as service:
            self.assertEqual(service.call('/health'), (200, {'status': 'ok', 'service': 'lifecycle-fixture'}))
            self.assertEqual(service.call('/version'), (200, {'service': 'lifecycle-fixture', 'version': 'test'}))
            self.assertEqual(service.call('/missing')[0], 404)

    def test_requests_remain_blocking_and_preserve_unicode(self):
        with self.service() as service:
            body = 'persisted café 😀'.encode()
            with socket.create_connection(('127.0.0.1', service.port), timeout=5) as connection:
                connection.sendall(f'POST /append HTTP/1.1\r\nContent-Length: {len(body)}\r\n\r\n'.encode())
                connection.sendall(body[:3])
                time.sleep(.05)
                connection.sendall(body[3:])
                self.assertTrue(connection.recv(4096).startswith(b'HTTP/1.1 201'))
            self.assertEqual(service.call('/journal'), (200, body.decode() + '\n'))

    def test_invalid_request_does_not_stop_the_server(self):
        with self.service() as service:
            for wire in [b'GET /health HTTP/2\r\n\r\n',
                         b'POST /append HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx',
                         b'POST /append HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n']:
                with self.subTest(wire=wire), socket.create_connection(('127.0.0.1', service.port), timeout=5) as connection:
                    connection.sendall(wire)
                    self.assertTrue(connection.recv(4096).startswith(b'HTTP/1.1 4'))
                self.assertEqual(service.call('/health')[0], 200)

    def test_bind_failure_leaves_the_existing_server_healthy(self):
        with self.service() as first, tempfile.TemporaryDirectory(prefix='amisad-bind-failure-') as name:
            second = RunningService(self.binary, Path(name), port=first.port)
            try:
                self.assertNotEqual(second.process.wait(timeout=3), 0)
                self.assertTrue(Path(name, 'dropped').exists())
                self.assertEqual(first.call('/health')[0], 200)
            finally:
                second.close()

    def test_health_and_version_answer_while_a_handler_runs(self):
        with self.service() as service:
            result = []
            thread = threading.Thread(target=lambda: result.append(service.call('/commit-after-release', 'slow-write')))
            thread.start()
            try:
                wait_for(service.directory.joinpath('started').exists)
                self.assertEqual(service.call('/health', timeout=2), (200, {'status': 'ok', 'service': 'lifecycle-fixture'}))
                self.assertEqual(service.call('/version', timeout=2), (200, {'service': 'lifecycle-fixture', 'version': 'test'}))
            finally:
                service.directory.joinpath('release').touch()
                thread.join(timeout=5)
            self.assertEqual(result, [(201, {'committed': True})])

    def test_a_stalled_client_does_not_delay_other_requests(self):
        with self.service() as service:
            with socket.create_connection(('127.0.0.1', service.port), timeout=5) as stalled:
                stalled.sendall(b'POST /append HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc')
                self.assertEqual(service.call('/append', 'not-delayed', timeout=2)[0], 201)
            self.assertEqual(service.call('/journal'), (200, 'not-delayed\n'))

    def test_a_handler_panic_ends_the_process_for_its_supervisor(self):
        with self.service() as service:
            with self.assertRaises((OSError, http.client.HTTPException)):
                service.call('/panic', 'boom')
            self.assertEqual(service.process.wait(timeout=5), 101)

    def test_request_ids_are_returned_and_name_error_bodies(self):
        with self.service() as service:
            status, headers, body = service.exchange('/missing', headers={'X-Request-Id': 'contract-1'})
            self.assertEqual((status, headers['X-Request-Id'], body.get('correlation_id')), (404, 'contract-1', 'contract-1'))
            status, headers, body = service.exchange('/health', headers={'X-Request-Id': 'probe-1'})
            self.assertEqual((status, headers['X-Request-Id'], body), (200, 'probe-1', {'status': 'ok', 'service': 'lifecycle-fixture'}))
            minted = set()
            for supplied in [None, 'x' * 65, 'two words', 'caf\u00e9'.encode()]:
                with self.subTest(supplied=supplied):
                    status, headers, body = service.exchange('/missing', headers={} if supplied is None else {'X-Request-Id': supplied})
                    self.assertEqual(status, 404)
                    self.assertRegex(headers['X-Request-Id'] or '', '^[0-9a-f]{16}$')
                    self.assertEqual(body.get('correlation_id'), headers['X-Request-Id'])
                    minted.add(headers['X-Request-Id'])
            self.assertEqual(len(minted), 4, 'every minted id is new')
            # A request refused before it is parsed still gets an id.
            with socket.create_connection(('127.0.0.1', service.port), timeout=5) as connection:
                connection.sendall(b'POST /append HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx')
                head, _, payload = read_reply(connection).partition(b'\r\n\r\n')
            self.assertTrue(head.startswith(b'HTTP/1.1 400'), head)
            ids = [line.split(b':', 1)[1].strip().decode() for line in head.split(b'\r\n')[1:]
                   if line.lower().startswith(b'x-request-id:')]
            self.assertEqual(len(ids), 1, head)
            self.assertRegex(ids[0], '^[0-9a-f]{16}$')
            self.assertEqual(json.loads(payload)['correlation_id'], ids[0])

    def test_outbound_calls_forward_the_request_id_and_server_errors_are_logged(self):
        seen = []
        class Peer(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                seen.append(self.headers.get('X-Request-Id'))
                data = b'{"error":"peer unavailable"}'
                self.send_response(503)
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Peer) as peer:
            serving = threading.Thread(target=peer.serve_forever, daemon=True)
            serving.start()
            try:
                with self.service() as service:
                    status, headers, body = service.exchange(
                        '/forward', f'http://127.0.0.1:{peer.server_port}/peer', headers={'X-Request-Id': 'contract-2'})
                    self.assertEqual(seen, ['contract-2'])
                    self.assertEqual((status, headers['X-Request-Id']), (503, 'contract-2'))
                    self.assertEqual(body, {'error': 'peer unavailable', 'correlation_id': 'contract-2'})
                    self.assertRegex(service.output(), r'lifecycle-fixture answered 503 - to POST /forward \(request contract-2\)')
            finally:
                peer.shutdown()
                serving.join(timeout=5)

    @unittest.skipUnless(os.name == 'posix', 'SIGTERM is a Unix lifecycle contract')
    def test_idle_sigterm_returns_success_and_releases_port(self):
        with self.service() as service:
            service.terminate()
            self.assert_graceful_exit(service)

    @unittest.skipUnless(os.name == 'posix', 'SIGTERM is a Unix lifecycle contract')
    def test_committed_state_survives_graceful_restart(self):
        with tempfile.TemporaryDirectory(prefix='amisad-persistence-') as name:
            directory = Path(name)
            with self.service(directory) as first:
                self.assertEqual(first.call('/append', 'before-restart')[0], 201)
                port = first.port
                first.terminate()
                self.assert_graceful_exit(first)
            with self.service(directory, port=port) as second:
                self.assertEqual(second.call('/journal'), (200, 'before-restart\n'))
                self.assertEqual(second.call('/append', 'after-restart')[0], 201)
                second.terminate()
                self.assert_graceful_exit(second)
            self.assertEqual(directory.joinpath('journal').read_text(), 'before-restart\nafter-restart\n')

    def drain_inflight(self, pid1=False):
        with self.service(pid1=pid1) as service:
            result = []
            def commit():
                try:
                    result.append(service.call('/commit-after-release', 'active-write'))
                except Exception as error:
                    result.append(error)
            thread = threading.Thread(target=commit)
            thread.start()
            try:
                wait_for(service.directory.joinpath('started').exists)
                with socket.create_connection(('127.0.0.1', service.port), timeout=5) as queued:
                    queued.sendall(b'POST /append HTTP/1.1\r\nContent-Length: 6\r\n\r\nqueued')
                    # Connections are accepted in arrival order, so an answered
                    # /health shows the server took the queued request in
                    # before the signal arrived.
                    self.assertEqual(service.call('/health')[0], 200)
                    for _ in range(3):
                        service.terminate()
                        time.sleep(.02)
                    self.assertIsNone(service.process.poll(), 'active request was interrupted')
                    service.directory.joinpath('release').touch()
                    thread.join(timeout=5)
                    self.assertFalse(thread.is_alive())
                    self.assertEqual(result, [(201, {'committed': True})])
                    self.assert_graceful_exit(service)
                    head, _, payload = read_reply(queued).partition(b'\r\n\r\n')
                    self.assertTrue(head.startswith(b'HTTP/1.1 503'), head)
                    self.assertEqual(json.loads(payload)['code'], 'service_stopping')
                self.assertEqual(service.directory.joinpath('journal').read_text(), 'active-write\n',
                                 'a queued request was handled after shutdown was requested')
            finally:
                service.directory.joinpath('release').touch()
                thread.join(timeout=5)

    @unittest.skipUnless(os.name == 'posix', 'SIGTERM is a Unix lifecycle contract')
    def test_sigterm_drains_active_request_once_and_rejects_queued_work(self):
        self.drain_inflight()


@unittest.skipUnless(sys.platform.startswith('linux') and shutil.which('unshare'), 'Linux unshare is required')
class PidOneLifecycle(LifecycleFixture):
    drain_inflight = HttpLifecycle.drain_inflight
    @classmethod
    def setUpClass(cls):
        probe = subprocess.run(['unshare', '--user', '--map-root-user', '--pid', '--fork', '--kill-child',
                                'sh', '-c', 'test "$$" = 1'], capture_output=True, timeout=5)
        if probe.returncode:
            raise unittest.SkipTest('unprivileged PID namespaces are unavailable')
        super().setUpClass()

    def test_pid_one_idle_sigterm_returns_success(self):
        with self.service(pid1=True) as service:
            service.terminate()
            self.assert_graceful_exit(service)

    def test_pid_one_sigterm_drains_active_request_once(self):
        self.drain_inflight(pid1=True)


if __name__ == '__main__':
    unittest.main()
