#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# GUID: 42caa23b-3f0a-4068-85e7-f494511c81a9
"""Real slice-runtime HTTP delivery contracts; build workspace binaries first."""
import http.client
import json
import os
import socket
import subprocess
import time
import unittest

from service_contracts import BEARER, BIN, WRITE_TOKEN, call, peer, service


def startup_stderr(**env):
    """What slice-runtime writes to stderr from its start until it answers /health,
    started with `env` and no LEDGER_WRITE_TOKEN from this process."""
    with socket.socket() as port_socket:
        port_socket.bind(('127.0.0.1', 0))
        port = port_socket.getsockname()[1]
    process = subprocess.Popen([str(BIN / 'slice-runtime')], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                               env={**{k: v for k, v in os.environ.items() if k != 'LEDGER_WRITE_TOKEN'},
                                    'PORT': str(port), **env})
    try:
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline and process.poll() is None:
            try:
                if call(f'http://127.0.0.1:{port}', '/health')[0] == 200:
                    break
            except (OSError, http.client.HTTPException):
                time.sleep(.02)
        else:
            raise TimeoutError('slice-runtime did not answer /health')
    finally:
        process.terminate()
        stderr = process.communicate(timeout=5)[1].decode()
    return stderr


class SliceRuntimeHttp(unittest.TestCase):
    def assert_abort_delivers_lifecycle(self, peer_status):
        ledger, telemetry = [], []

        def receive(target):
            def handle(path, body):
                target.append((path, body))
                return peer_status, {'accepted': peer_status < 300}
            return handle

        with peer(receive(ledger)) as ledger_url, peer(receive(telemetry)) as resource_url:
            with service('slice-runtime', LEDGER_URL=ledger_url, RESOURCE_URL=resource_url,
                         REGION='contract-region') as runtime:
                self.assertEqual(call(runtime, '/v1/faults', {'mode': 'isolation', 'count': 1}), (200, {'armed': 1}))
                sealed = 'private-envelope-must-never-be-opened-or-sent'
                status, result = call(runtime, '/v1/environments',
                                      {'jurisdiction': 'contract-region', 'envelope': sealed, 'offers': []})
                self.assertEqual(status, 503)
                self.assertEqual(result['status'], 'aborted')
                self.assertEqual(result['fault'], 'isolation')
                self.assertEqual(len(result['environment_id']), 64)
                for messages, path, field in [(ledger, '/v1/attestations', 'lifecycle'),
                                              (telemetry, '/v1/telemetry', 'event')]:
                    self.assertEqual([body[field] for _, body in messages],
                                     ['created', 'attested', 'aborted', 'destroyed'])
                    for actual_path, body in messages:
                        self.assertEqual(actual_path, path)
                        self.assertEqual(body['environment_id'], result['environment_id'])
                        self.assertEqual(body['region'], 'contract-region')
                        self.assertEqual(body.get('fault'), 'isolation' if body[field] == 'aborted' else None)
                        self.assertNotIn(sealed, str(body))
                status, egress = call(runtime, '/v1/egress')
                self.assertEqual(status, 200)
                self.assertEqual(len(egress['entries']), 8)
                self.assertNotIn(sealed, str(egress))
                self.assertNotIn('match-record', str(egress))
                self.assertNotIn('shortlist-record', str(egress))
                self.assertEqual(call(runtime, '/health')[0], 200)

    def test_production_http_sender_delivers_every_abort_lifecycle(self):
        self.assert_abort_delivers_lifecycle(201)

    def test_production_http_sender_attempts_remaining_events_after_peer_failure(self):
        self.assert_abort_delivers_lifecycle(503)

    def test_runtime_registers_its_lease_when_advertised_and_renews_it(self):
        # Only a runtime started with ADVERTISE_URL registers itself; the
        # lifecycle cases above set none and see telemetry posts alone. The
        # renewal comes 10 s after the first registration, so the case waits
        # for a second one: a runtime that registered once would lapse 30 s
        # after it started.
        registrations = []

        def resource(path, body):
            registrations.append((path, body))
            return 201, body

        expected = ('/v1/edges', {'region': 'contract-region', 'endpoint': 'http://edge.contract:8080',
                                  'capacity': 3, 'lease_secs': 30})
        with peer(resource) as resource_url, peer(lambda *_: (201, {})) as ledger_url:
            with service('slice-runtime', LEDGER_URL=ledger_url, RESOURCE_URL=resource_url, REGION='contract-region',
                         ADVERTISE_URL='http://edge.contract:8080', CAPACITY='3') as runtime:
                deadline = time.monotonic() + 3
                while not registrations and time.monotonic() < deadline:
                    time.sleep(.05)
                self.assertEqual(registrations[:1], [expected])
                deadline = time.monotonic() + 15
                while len(registrations) < 2 and time.monotonic() < deadline:
                    time.sleep(.1)
                self.assertEqual(registrations[:2], [expected, expected], 'the lease was not renewed')
                self.assertEqual(call(runtime, '/health')[0], 200)

    def test_ledger_appends_carry_the_write_token_and_telemetry_does_not(self):
        ledger_seen, telemetry_seen = [], []
        offer = dict(offer_id='o1', tenant='t', title='set', category='housewares', region='contract-region',
                     price_cents=100, deliver_by_days=1, auto_close=True)
        need = dict(category='housewares', budget_cents=100, region='contract-region', deadline_days=1, auto_close=True)
        with peer(lambda *_: (201, {}), ledger_seen) as ledger_url, peer(lambda *_: (201, {}), telemetry_seen) as resource_url:
            with service('slice-runtime', LEDGER_URL=ledger_url, RESOURCE_URL=resource_url, REGION='contract-region',
                         LEDGER_WRITE_TOKEN=WRITE_TOKEN) as runtime:
                status, record = call(runtime, '/v1/environments', {'jurisdiction': 'contract-region',
                                                                    'envelope': json.dumps(need), 'offers': [offer]})
                self.assertEqual(status, 201, record)
                self.assertIn('match_id', record)
        self.assertEqual([path for path, _ in ledger_seen],
                         ['/v1/attestations'] * 2 + ['/v1/settlements/instructions'] + ['/v1/attestations'] * 2)
        for path, headers in ledger_seen:
            self.assertEqual(headers.get('Authorization'), BEARER['Authorization'], path)
        self.assertEqual(len(telemetry_seen), 4)
        for path, headers in telemetry_seen:
            self.assertIsNone(headers.get('Authorization'), path)

    def test_runtime_says_once_on_stderr_when_it_has_no_write_token(self):
        # Without the token the runtime still serves, and a ledger that has one
        # refuses its appends with 401, so its start names the missing token.
        for token in ({}, {'LEDGER_WRITE_TOKEN': ''}):
            stderr = startup_stderr(**token)
            lines = [line for line in stderr.splitlines() if 'LEDGER_WRITE_TOKEN' in line]
            self.assertEqual(lines, ['slice-runtime: LEDGER_WRITE_TOKEN is not set; ledger appends go without a write token'], stderr)
        stderr = startup_stderr(LEDGER_WRITE_TOKEN=WRITE_TOKEN)
        self.assertNotIn('LEDGER_WRITE_TOKEN', stderr)
        self.assertNotIn(WRITE_TOKEN, stderr)


if __name__ == '__main__':
    unittest.main()
