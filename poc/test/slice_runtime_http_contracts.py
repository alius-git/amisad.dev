#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
"""Real slice-runtime HTTP delivery contracts; build workspace binaries first."""
import unittest

from service_contracts import call, peer, service


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


if __name__ == '__main__':
    unittest.main()
