#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
"""Shared HTTP lifecycle contracts; only rustc and Python's standard library are required.

Normal HTTP contracts run on Windows as well. SIGTERM contracts require Unix;
the Linux PID 1 cases additionally require working unprivileged PID namespaces.
Set RUSTC or AMISAD_LIFECYCLE_BINARY to use a particular compiler or built fixture.
"""
import contextlib
import http.client
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

    def call(self, path, body=None):
        connection = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
        try:
            connection.request('GET' if body is None else 'POST', path, body=body)
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

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
                    for _ in range(3):
                        service.terminate()
                        time.sleep(.02)
                    self.assertIsNone(service.process.poll(), 'active request was interrupted')
                    service.directory.joinpath('release').touch()
                    thread.join(timeout=5)
                    self.assertFalse(thread.is_alive())
                    self.assertEqual(result, [(201, {'committed': True})])
                    self.assert_graceful_exit(service)
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
