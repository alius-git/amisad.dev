#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# GUID: 428f76de-f1df-49e3-8c60-f8ba79aaf13a
"""Native service contracts. Build Rust binaries first; set AMISAD_BIN_DIR if needed."""
import contextlib
import http.client
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import unittest

BIN = Path(os.environ.get('AMISAD_BIN_DIR', Path(__file__).resolve().parents[1] / 'target/debug'))
CATALOG = Path(__file__).resolve().parents[1] / 'components/lib/amisad-common/locales/en-US.json'
OFFER = dict(offer_id='o1', tenant='tenant-b', title='Dress', category='dress', region='eu', price_cents=100)
INSTRUCTION = dict(match_id='m1', value_cents=100, splits=dict(seller_cents=80, network_cents=10, platform_cents=10, ads_cents=0))
# The ledger write token for services started with one, and the header that carries it.
WRITE_TOKEN = 'contract-write-token'
BEARER = {'Authorization': f'Bearer {WRITE_TOKEN}'}


def exchange(url, path, body=None, headers=None, timeout=3):
    """call() that also returns the response headers."""
    conn = http.client.HTTPConnection(url.removeprefix('http://'), timeout=timeout)
    try:
        conn.request('GET' if body is None else 'POST', path, None if body is None else json.dumps(body), headers or {})
        response = conn.getresponse()
        return response.status, json.loads(response.read()), response.headers
    finally:
        conn.close()


def call(url, path, body=None, headers=None):
    return exchange(url, path, body, headers)[:2]


@contextlib.contextmanager
def peer(handler, seen=None):
    """A stub service; when given, `seen` collects (path, headers) per request."""
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if seen is not None:
                seen.append((self.path, self.headers))
            status, result = handler(self.path, None)
            self.reply(status, result)

        def do_POST(self):
            if seen is not None:
                seen.append((self.path, self.headers))
            body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', '0'))) or b'{}')
            status, result = handler(self.path, body)
            self.reply(status, result)

        def reply(self, status, result):
            data = json.dumps(result).encode()
            self.send_response(status)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f'http://127.0.0.1:{server.server_port}'
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


@contextlib.contextmanager
def service(name, **env):
    with socket.socket() as port_socket:
        port_socket.bind(('127.0.0.1', 0))
        port = port_socket.getsockname()[1]
    url = f'http://127.0.0.1:{port}'
    with tempfile.TemporaryFile() as log:
        process = subprocess.Popen([str(BIN / name)], stdout=log, stderr=log,
                                   env={**os.environ, 'PORT': str(port), 'DATABASE_URL': '', **env})
        try:
            for _ in range(100):
                if process.poll() is not None:
                    log.seek(0)
                    raise RuntimeError(log.read().decode())
                try:
                    if call(url, '/health')[0] == 200:
                        break
                except (OSError, http.client.HTTPException):
                    time.sleep(.02)
            else:
                raise TimeoutError(name)
            yield url
        finally:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()


class Contracts(unittest.TestCase):
    def test_http_bounds_and_service_survival(self):
        with service('connect-svc') as url:
            for wire in [
                b'POST /v1/partners HTTP/1.1\r\nContent-Length: 18446744073709551615\r\n\r\n',
                b'POST /v1/partners HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\n{}x',
                b'POST /v1/partners HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n',
                b'GET /health HTTP/1.1\r\nX-Fill: ' + b'a' * 33000 + b'\r\n\r\n',
            ]:
                with self.subTest(wire=wire[:90]), socket.create_connection(('127.0.0.1', int(url.rsplit(':', 1)[1])), timeout=3) as sock:
                    sock.sendall(wire)
                    response = sock.recv(1024)
                    self.assertTrue(response.startswith(b'HTTP/1.1 4'), response)
                    self.assertEqual(call(url, '/health')[0], 200)

    def test_tenant_scope_and_offer_ownership(self):
        with peer(lambda *_: (200, {})) as sink, service('seller-svc', COORDINATOR_URL=sink, CONNECT_URL=sink) as seller, service('connect-svc', SELLER_URL=seller) as connect:
            self.assertEqual(call(seller, '/v1/offers', OFFER)[0], 201)
            partner = call(connect, '/v1/partners', {'name': 'ERP'})[1]['partner_id']
            call(connect, '/v1/partners/certify', {'partner_id': partner})
            credential = call(connect, '/v1/grants', dict(partner_id=partner, tenant='tenant-a', scopes=['catalog', 'inventory']))[1]['credential']
            for offer in [OFFER, {**OFFER, 'tenant': 'tenant-a'}]:
                with self.subTest(offer=offer):
                    self.assertIn(call(connect, '/v1/sync/catalog', dict(credential=credential, offers=[offer]))[0], (403, 409))
            self.assertIn(call(connect, '/v1/sync/inventory', dict(credential=credential, offer_id='o1', stock=0))[0], (403, 409))
            visible = call(seller, '/v1/offers/region/eu')[1]['offers']
            self.assertEqual(visible, [OFFER])
            own = {**OFFER, 'offer_id': 'own', 'tenant': 'tenant-a'}
            self.assertEqual(call(connect, '/v1/sync/catalog', dict(credential=credential, offers=[own]))[0], 200)
            self.assertEqual(call(connect, '/v1/sync/inventory', dict(credential=credential, offer_id='own', stock=0))[0], 200)

    def test_inventory_versions_reject_stale_and_conflicting_replays(self):
        with peer(lambda *_: (200, {})) as sink, service('seller-svc', COORDINATOR_URL=sink, CONNECT_URL=sink) as seller:
            self.assertEqual(call(seller, '/v1/offers', OFFER)[0], 201)
            base = dict(tenant=OFFER['tenant'], offer_id=OFFER['offer_id'])
            for stock, stamp, expected in [(0, 20, 200), (5, 10, 409), (5, 20, 409), (0, 20, 200)]:
                self.assertEqual(call(seller, '/v1/offers/inventory', dict(base, stock=stock, delta_ts=stamp))[0], expected)
            self.assertEqual(call(seller, '/v1/offers/region/eu')[1]['offers'], [])
            self.assertEqual(call(seller, '/v1/offers/inventory', dict(base, stock=5, delta_ts=30))[0], 200)
            self.assertEqual(call(seller, '/v1/offers/region/eu')[1]['offers'], [OFFER])

    def test_connector_inventory_preserves_version(self):
        with peer(lambda *_: (200, {})) as sink, service('seller-svc', COORDINATOR_URL=sink, CONNECT_URL=sink) as seller, service('connect-svc', SELLER_URL=seller) as connect:
            self.assertEqual(call(seller, '/v1/offers', OFFER)[0], 201)
            partner = call(connect, '/v1/partners', {'name': 'ERP'})[1]['partner_id']
            call(connect, '/v1/partners/certify', {'partner_id': partner})
            credential = call(connect, '/v1/grants', dict(partner_id=partner, tenant=OFFER['tenant'], scopes=['inventory']))[1]['credential']
            base = dict(credential=credential, offer_id=OFFER['offer_id'])
            self.assertEqual(call(connect, '/v1/sync/inventory', dict(base, stock=0, delta_ts=20))[0], 200)
            self.assertEqual(call(connect, '/v1/sync/inventory', dict(base, stock=5, delta_ts=10))[0], 409)
            self.assertEqual(call(connect, '/v1/sync/inventory', dict(base, stock=0, delta_ts=20))[0], 200)
            self.assertEqual(call(seller, '/v1/offers/region/eu')[1]['offers'], [])

    def test_settlement_failure_is_retryable(self):
        answer = [503]
        with peer(lambda *_: (answer[0], {})) as ledger, service('seller-svc', LEDGER_URL=ledger, COORDINATOR_URL=ledger, CONNECT_URL=ledger) as seller:
            call(seller, '/v1/offers', OFFER)
            call(seller, '/v1/orders', dict(match_id='m1', offer_id='o1', tenant='tenant-b'))
            self.assertEqual(call(seller, '/v1/orders/advance', dict(match_id='m1', state='provisioning'))[0], 200)
            self.assertEqual(call(seller, '/v1/orders/advance', dict(match_id='m1', state='fulfilled'))[0], 503)
            self.assertEqual(call(seller, '/v1/orders/match/m1')[1]['state'], 'provisioning')
            answer[0] = 201
            self.assertEqual(call(seller, '/v1/orders/advance', dict(match_id='m1', state='fulfilled'))[1]['state'], 'settled')

    def test_refund_replay_preserves_chain(self):
        with service('ledger-svc') as ledger:
            call(ledger, '/v1/settlements/instructions', INSTRUCTION)
            call(ledger, '/v1/settlements/confirm', {'match_id': 'm1'})
            payload = dict(match_id='m1', case_id='c1')
            first = call(ledger, '/v1/settlements/adjust', payload)
            before = call(ledger, '/v1/settlements')[1]
            again = call(ledger, '/v1/settlements/adjust', payload)
            self.assertEqual(again[1], first[1])
            self.assertEqual(call(ledger, '/v1/settlements')[1], before)
            self.assertEqual(call(ledger, '/v1/settlements/adjust', dict(match_id='m1', case_id='c2'))[0], 409)
            self.assertEqual(call(ledger, '/v1/settlements')[1], before)

    def test_booking_writes_are_idempotent_and_conflicts_rejected(self):
        with peer(lambda *_: (200, {})) as sink, service('seller-svc', COORDINATOR_URL=sink, CONNECT_URL=sink) as seller, service('ledger-svc') as ledger:
            call(seller, '/v1/offers', OFFER)
            for attempt, expected in enumerate([201, 200]):
                self.assertEqual(call(ledger, '/v1/settlements/instructions', INSTRUCTION)[0], expected)
                self.assertEqual(call(seller, '/v1/orders', dict(match_id='m1', offer_id='o1', tenant='tenant-b'))[0], expected)
            self.assertEqual(call(seller, '/v1/orders', dict(match_id='m1', offer_id='o1', tenant='tenant-a'))[0], 409)
            changed = {**INSTRUCTION, 'splits': dict(seller_cents=70, network_cents=20, platform_cents=10, ads_cents=0)}
            self.assertEqual(call(ledger, '/v1/settlements/instructions', changed)[0], 409)

    def test_audit_rejects_missing_and_malformed_chain_evidence(self):
        dump = [{}]
        with peer(lambda *_: (200, dump[0])) as ledger, service('audit-svc', LEDGER_URL=ledger) as audit:
            for malformed in [{}, [], {'entries': None}, {'entries': []}, {'entries': [], 'head': 'f' * 64}, {'entries': [{}], 'head': '0' * 64}]:
                with self.subTest(dump=malformed):
                    dump[0] = malformed
                    self.assertEqual(call(audit, '/v1/certify', {})[0], 502)
            dump[0] = {'entries': [], 'head': '0' * 64, 'instructions': []}
            self.assertTrue(call(audit, '/v1/certify', {})[1]['certified'])

    def test_booking_recovers_from_seller_failure_and_response_loss(self):
        for lose_response in [False, True]:
            with self.subTest(lose_response=lose_response), peer(lambda *_: (200, {})) as sink, service('seller-svc', COORDINATOR_URL=sink, CONNECT_URL=sink) as seller, service('ledger-svc') as ledger:
                call(seller, '/v1/offers', OFFER)
                failed = [False]
                dispatched = [0]
                def upstream(path, body):
                    if path == '/v1/verify':
                        return 200, dict(actor='buyer', **{'class': 'person'})
                    if path == '/v1/placements':
                        return 200, dict(endpoint=stub)
                    if path == '/v1/environments':
                        dispatched[0] += 1
                        return 201, dict(environment_id=f'e{dispatched[0]}', need_context='dress', shortlist=[OFFER])
                    if path.startswith('/v1/campaigns/'):
                        return 200, dict(campaigns=[])
                    if path == '/v1/orders' and not failed[0]:
                        failed[0] = True
                        if lose_response:
                            self.assertEqual(call(seller, path, body)[0], 201)
                        return 503, {}
                    return call(seller, path, body)
                with peer(upstream) as stub, service('fabric-coordinator', IDENTITY_URL=stub, RESOURCE_URL=stub, ADS_URL=stub, SELLER_URL=stub, LEDGER_URL=ledger) as coordinator:
                    status, need = call(coordinator, '/v1/needs', dict(token='token', jurisdiction='eu', envelope='sealed'))
                    self.assertEqual(status, 201, need)
                    booking = dict(handle=need['handle'], offer_id='o1')
                    self.assertEqual(call(coordinator, '/v1/bookings', booking)[0], 502)
                    status, result = call(coordinator, '/v1/bookings', booking)
                    self.assertEqual(status, 201, result)
                    self.assertEqual(call(coordinator, '/v1/bookings', booking), (200, result))
                    self.assertEqual(len(call(coordinator, '/v1/notifications/' + need['handle'])[1]['notifications']), 2)
                    self.assertEqual(call(seller, '/v1/orders')[1]['count'], 1)
                    self.assertEqual(call(ledger, '/v1/settlements/match/' + result['match_id'])[1]['value_cents'], 100)
                    uses = [e['payload'] for e in call(ledger, '/v1/consents')[1]['entries'] if e['payload']['action'] == 'use']
                    self.assertTrue(uses and all(u['grant_type'] == 'participation' and u['match_id'] == result['match_id'] for u in uses), uses)
                    with service('audit-svc', LEDGER_URL=ledger) as audit:
                        self.assertTrue(call(audit, '/v1/certify', {})[1]['consent']['ok'])
                    # A shortlist issued before a revoke cannot be booked after it.
                    status, later = call(coordinator, '/v1/needs', dict(token='token', jurisdiction='eu', envelope='sealed-later'))
                    self.assertEqual(status, 201, later)
                    call(coordinator, '/v1/consents', dict(token='token', grant_type='participation', action='revoke'))
                    status, refused = call(coordinator, '/v1/bookings', dict(handle=later['handle'], offer_id='o1'))
                    self.assertEqual((status, refused.get('reason')), (403, 'participation revoked'), refused)
                    after = [e['payload'] for e in call(ledger, '/v1/consents')[1]['entries'] if e['payload']['action'] == 'use']
                    self.assertEqual(after, uses)
                    self.assertEqual(call(seller, '/v1/orders')[1]['count'], 1)

    def test_http_exact_body_boundary_truncation_and_language(self):
        with service('connect-svc') as url:
            host, port = url.removeprefix('http://').split(':')
            conn = http.client.HTTPConnection(host, port, timeout=3)
            payload = b'{"name":"ERP"}'
            conn.request('POST', '/v1/partners', payload + b' ' * (1024 * 1024 - len(payload)))
            response = conn.getresponse()
            self.assertEqual(response.status, 201)
            response.read()
            conn.close()
            with socket.create_connection((host, int(port)), timeout=3) as sock:
                sock.sendall(b'POST /v1/partners HTTP/1.1\r\nContent-Length: 5\r\n\r\n{}')
                sock.shutdown(socket.SHUT_WR)
                self.assertTrue(sock.recv(1024).startswith(b'HTTP/1.1 400'))
            for locale in ['en-US', 'pt-BR', 'zh-CN', 'he-IL']:
                conn = http.client.HTTPConnection(host, port, timeout=3)
                conn.request('POST', '/v1/partners', '{}', headers={'Accept-Language': locale, 'Content-Length': str(1024 * 1024 + 1)})
                response = conn.getresponse()
                body = json.loads(response.read())
                self.assertEqual(response.status, 413)
                self.assertEqual(body['code'], 'request_too_large')
                catalog = json.loads((Path(__file__).resolve().parents[1] / 'components/lib/amisad-common/locales' / (locale + '.json')).read_text())
                self.assertEqual(body['error'], catalog['messages']['request_too_large']['text'])
                conn.close()

    def test_http_total_deadline_survives_slow_body(self):
        with service('connect-svc') as url:
            with socket.create_connection(('127.0.0.1', int(url.rsplit(':', 1)[1])), timeout=25) as sock:
                sock.sendall(b'POST /v1/partners HTTP/1.1\r\nContent-Length: 50\r\n\r\n{')
                def drip():
                    for _ in range(22):
                        time.sleep(1)
                        try:
                            sock.sendall(b' ')
                        except OSError:
                            return
                writer = threading.Thread(target=drip, daemon=True)
                writer.start()
                started = time.monotonic()
                response = sock.recv(1024)
                self.assertTrue(response.startswith(b'HTTP/1.1 408'), response)
                self.assertLess(time.monotonic() - started, 23)
            writer.join(timeout=2)
            self.assertEqual(call(url, '/health')[0], 200)

    def test_audit_validates_lifecycle_order_and_settlement_amounts(self):
        import hashlib
        def chain(payloads):
            previous = '0' * 64
            entries = []
            for payload in payloads:
                digest = hashlib.sha256((previous + json.dumps(payload, separators=(',', ':'))).encode()).hexdigest()
                entries.append(dict(payload=payload, prev=previous, hash=digest))
                previous = digest
            return dict(entries=entries, head=previous)
        parties = dict(seller=80, network=10, platform=10, ads=0)
        instructions = dict(instructions=[dict(match_id='m1', value_cents=100, confirmed=True,
            splits=[dict(party=p, amount_cents=n) for p, n in parties.items()])])
        events = [dict(environment_id='e1', lifecycle=e, jurisdiction='eu', region='eu')
            for e in ['created', 'attested', 'executed', 'destroyed']]
        splits = [dict(match_id='m1', party=p, amount_cents=n) for p, n in parties.items()]
        refund = [dict(match_id='m1', party=p, amount_cents=-n, entry_type='adjustment', case_id='c1') for p, n in parties.items()]
        use = dict(subject='s1', grant_type='participation', action='use', match_id='m1', ts=2)
        evidence = {'/v1/attestations': chain(events), '/v1/settlements': chain(splits),
                    '/v1/consents': chain([use]), '/v1/settlements/instructions': instructions}
        with peer(lambda path, _: (200, evidence[path])) as ledger, service('audit-svc', LEDGER_URL=ledger) as audit:
            for broken in [list(reversed(events)), events + [events[-1]], events[:2] + [events[0]] + events[2:]]:
                evidence['/v1/attestations'] = chain(broken)
                self.assertFalse(call(audit, '/v1/certify', {})[1]['certified'])
            evidence['/v1/attestations'] = chain(events)
            for broken in [splits + refund + refund, [{**splits[0], 'amount_cents': 81}] + splits[1:], splits[:-1]]:
                evidence['/v1/settlements'] = chain(broken)
                self.assertFalse(call(audit, '/v1/certify', {})[1]['certified'])
            for valid in [splits, splits + refund]:
                evidence['/v1/settlements'] = chain(valid)
                self.assertTrue(call(audit, '/v1/certify', {})[1]['certified'])
            revoke = dict(subject='s1', grant_type='participation', action='revoke', ts=1)
            for broken in [[], [revoke, use], [{**use, 'match_id': 'm2'}]]:
                evidence['/v1/consents'] = chain(broken)
                result = call(audit, '/v1/certify', {})[1]
                self.assertFalse(result['consent']['ok'], broken)
                self.assertFalse(result['certified'], broken)

    def test_offer_published_event_survives_two_failed_deliveries(self):
        # The coordinator matches only on this event, so a lost one leaves a
        # fitting open need unmatched.
        posts = []
        def coordinator(path, body):
            posts.append((path, body))
            return (503, {}) if len(posts) <= 2 else (200, {'rematched': 0})
        with peer(coordinator) as fabric, peer(lambda *_: (200, {})) as sink, service('seller-svc', COORDINATOR_URL=fabric, CONNECT_URL=sink) as seller:
            self.assertEqual(call(seller, '/v1/offers', OFFER)[0], 201)
            deadline = time.monotonic() + 10
            while len(posts) < 3 and time.monotonic() < deadline:
                time.sleep(.05)
            self.assertEqual(posts, [('/v1/offers/published', OFFER)] * 3)

    def test_a_refused_offer_event_is_not_resent(self):
        posts = []
        def coordinator(path, body):
            posts.append(path)
            return 400, {'error': 'refused'}
        with peer(coordinator) as fabric, peer(lambda *_: (200, {})) as sink, service('seller-svc', COORDINATOR_URL=fabric, CONNECT_URL=sink) as seller:
            self.assertEqual(call(seller, '/v1/offers', OFFER)[0], 201)
            time.sleep(4)
            self.assertEqual(posts, ['/v1/offers/published'])

    MANDATE = dict(token='maya', delegate='pat', category='housewares', per_item_cents=14000)
    DELEGATED_NEED = dict(token='pat', principal='maya', category='housewares', jurisdiction='eu', envelope='sealed')

    def test_delegated_approval_survives_commit_failure_and_replay(self):
        # The hold stays until its commit succeeds: a retry records another
        # mandate use and resumes the writes, whose identical replays answer
        # 200; a committed approval leaves nothing to approve again.
        vase = {**OFFER, 'offer_id': 'vase', 'category': 'housewares', 'price_cents': 18000}
        entry = dict(offer_id='vase', tenant='tenant-b', category='housewares', price_cents=18000)
        for lose_response in [False, True]:
            with self.subTest(lose_response=lose_response):
                self.approve_after_a_failed_order(vase, entry, lose_response)

    def approve_after_a_failed_order(self, vase, entry, lose_response):
        # The ledger takes appends only with the write token, so the commit
        # proves the coordinator's delegated writes carry it.
        with peer(lambda *_: (200, {})) as sink, service('seller-svc', COORDINATOR_URL=sink, CONNECT_URL=sink) as seller, service('ledger-svc', LEDGER_WRITE_TOKEN=WRITE_TOKEN) as ledger:
            self.assertEqual(call(seller, '/v1/offers', vase)[0], 201)
            failed = [False]
            def upstream(path, body):
                if path == '/v1/verify':
                    return 200, {'actor': body['token'], 'class': 'person'}
                if path == '/v1/placements':
                    return 200, dict(endpoint=stub)
                if path.startswith('/v1/campaigns/'):
                    return 200, dict(campaigns=[])
                if path == '/v1/environments':
                    return 201, dict(environment_id='e-vase', need_context='vase', shortlist=[entry])
                if path == '/v1/orders' and not failed[0]:
                    failed[0] = True
                    if lose_response:
                        self.assertEqual(call(seller, path, body)[0], 201)
                    return 503, {}
                return call(seller, path, body)
            with peer(upstream) as stub, service('fabric-coordinator', IDENTITY_URL=stub, RESOURCE_URL=stub, ADS_URL=stub, SELLER_URL=stub, LEDGER_URL=ledger, LEDGER_WRITE_TOKEN=WRITE_TOKEN) as coordinator:
                self.assertEqual(call(coordinator, '/v1/mandates', self.MANDATE)[0], 201)
                status, held = call(coordinator, '/v1/delegate/needs', self.DELEGATED_NEED)
                self.assertEqual((status, held.get('status')), (201, 'held-for-approval'), held)
                approval = dict(token='maya', handle=held['handle'])
                status, failure = call(coordinator, '/v1/mandates/approve', approval)
                self.assertEqual(status, 502, failure)
                status, committed = call(coordinator, '/v1/mandates/approve', approval)
                self.assertEqual((status, committed.get('via')), (201, 'approval'), committed)
                status, replay = call(coordinator, '/v1/mandates/approve', approval)
                self.assertEqual((status, replay.get('code')), (404, 'held_match_not_found'), replay)
                self.assertEqual(failure.get('code'), 'upstream_failed', failure)
                self.assertEqual(call(seller, '/v1/orders')[1]['count'], 1)
                instructions = call(ledger, '/v1/settlements/instructions')[1]['instructions']
                self.assertEqual([(i['match_id'], i['value_cents']) for i in instructions], [(committed['match_id'], 18000)])
                uses = [e['payload'] for e in call(ledger, '/v1/consents')[1]['entries'] if e['payload']['action'] == 'use']
                self.assertEqual([(u['grant_type'], u['via'], u['match_id']) for u in uses],
                                 [('mandate', 'approval', committed['match_id'])] * 2)
                with service('audit-svc', LEDGER_URL=ledger) as audit:
                    self.assertTrue(call(audit, '/v1/certify', {})[1]['consent']['ok'])

    def test_delegated_need_is_dispatched_manual_and_never_auto_closes(self):
        # Only the coordinator may close a delegated need, against the mandate
        # cap; an environment that closes anyway gets nothing recorded for it.
        pot = {**OFFER, 'offer_id': 'pot', 'category': 'housewares', 'price_cents': 12000}
        entry = dict(offer_id='pot', tenant='tenant-b', category='housewares', price_cents=12000)
        dispatches, closes = [], [False]
        with peer(lambda *_: (200, {})) as sink, service('seller-svc', COORDINATOR_URL=sink, CONNECT_URL=sink) as seller, service('ledger-svc') as ledger:
            self.assertEqual(call(seller, '/v1/offers', pot)[0], 201)
            def upstream(path, body):
                if path == '/v1/verify':
                    return 200, {'actor': body['token'], 'class': 'person'}
                if path == '/v1/placements':
                    return 200, dict(endpoint=stub)
                if path.startswith('/v1/campaigns/'):
                    return 200, dict(campaigns=[])
                if path == '/v1/environments':
                    dispatches.append(body)
                    environment = f'e{len(dispatches)}'
                    if body.get('policy') == 'manual' and not closes[0]:
                        return 201, dict(environment_id=environment, need_context='pot', shortlist=[entry])
                    return 201, dict(environment_id=environment, need_context='pot', match_id='m-' + environment, offer=entry)
                return call(seller, path, body)
            with peer(upstream) as stub, service('fabric-coordinator', IDENTITY_URL=stub, RESOURCE_URL=stub, ADS_URL=stub, SELLER_URL=stub, LEDGER_URL=ledger) as coordinator:
                self.assertEqual(call(coordinator, '/v1/mandates', self.MANDATE)[0], 201)
                status, result = call(coordinator, '/v1/delegate/needs', self.DELEGATED_NEED)
                self.assertEqual((status, result.get('status'), result.get('via')), (201, 'committed', 'delegate'), result)
                self.assertEqual([d.get('policy') for d in dispatches], ['manual'])
                consents = call(ledger, '/v1/consents')[1]
                uses = [e['payload'] for e in consents['entries'] if e['payload']['action'] == 'use']
                self.assertEqual([(u['grant_type'], u.get('via'), u['match_id']) for u in uses],
                                 [('mandate', 'delegate', result['match_id'])])
                self.assertEqual(call(seller, '/v1/orders')[1]['count'], 1)
                closes[0] = True
                status, refused = call(coordinator, '/v1/delegate/needs', self.DELEGATED_NEED)
                self.assertEqual((status, refused.get('code')), (502, 'manual_dispatch_ignored'), refused)
                self.assertEqual([d.get('policy') for d in dispatches], ['manual', 'manual'])
                self.assertEqual(call(ledger, '/v1/consents')[1], consents)
                self.assertEqual(call(seller, '/v1/orders')[1]['count'], 1)

    def test_edge_lease_lapses_and_renews(self):
        edge = dict(region='eu', endpoint='http://edge-eu:8080', lease_secs=1)
        with service('resource-svc') as resource:
            self.assertEqual(call(resource, '/v1/edges', edge)[0], 201)
            self.assertEqual(call(resource, '/v1/placements', dict(jurisdiction='eu')), (200, dict(region='eu', endpoint=edge['endpoint'])))
            time.sleep(1.2)
            status, lapsed = call(resource, '/v1/placements', dict(jurisdiction='eu'))
            self.assertEqual((status, lapsed.get('code')), (409, 'no_compliant_edge'), lapsed)
            self.assertEqual(call(resource, '/v1/edges')[1]['edges'], [dict(region='eu', endpoint=edge['endpoint'], capacity=1, lease_remaining_secs=0)])
            self.assertEqual(call(resource, '/v1/edges', edge)[0], 201)
            self.assertEqual(call(resource, '/v1/placements', dict(jurisdiction='eu'))[0], 200)

    def test_coordinator_errors_are_coded_and_correlated(self):
        catalog = json.loads(CATALOG.read_text(encoding='utf-8'))['messages']
        with socket.socket() as closed:
            closed.bind(('127.0.0.1', 0))
            nobody = f'http://127.0.0.1:{closed.getsockname()[1]}'
        need = dict(token='buyer', jurisdiction='eu', envelope='sealed')
        with service('fabric-coordinator', IDENTITY_URL=nobody) as coordinator:
            # The refused dial is retried once after 2 s before the call fails.
            status, body, headers = exchange(coordinator, '/v1/needs', need, {'X-Request-Id': 'contract-1'}, timeout=10)
            self.assertEqual((status, body.get('code')), (503, 'upstream_unavailable'), body)
            self.assertEqual(body['error'], catalog['upstream_unavailable']['text'])
            self.assertIn('identity unavailable', body['detail'])
            self.assertEqual((body['correlation_id'], headers['X-Request-Id']), ('contract-1', 'contract-1'))
            status, body, headers = exchange(coordinator, '/v1/bookings', dict(handle='unknown', offer_id='o1'))
            self.assertEqual((status, body.get('code')), (404, 'unknown_handle'), body)
            self.assertEqual(body['error'], catalog['unknown_handle']['text'])
            self.assertRegex(body['correlation_id'], r'^[0-9a-f]{16}$')
            self.assertEqual(headers['X-Request-Id'], body['correlation_id'])
        seen = []
        with peer(lambda *_: (500, {}), seen) as identity, service('fabric-coordinator', IDENTITY_URL=identity) as coordinator:
            status, body = call(coordinator, '/v1/needs', need, {'X-Request-Id': 'contract-2'})
            self.assertEqual((status, body.get('code'), body.get('correlation_id')), (401, 'unverified_actor', 'contract-2'), body)
            self.assertEqual([(path, headers['X-Request-Id']) for path, headers in seen], [('/v1/verify', 'contract-2')])

    def test_resource_errors_are_coded(self):
        with service('resource-svc') as resource:
            status, body = call(resource, '/v1/placements', {})
            self.assertEqual((status, body.get('code'), body.get('detail')), (400, 'invalid_request', 'jurisdiction required'), body)
            status, body = call(resource, '/v1/placements', dict(jurisdiction='eu'))
            self.assertEqual((status, body.get('code')), (409, 'no_compliant_edge'), body)
            status, body = call(resource, '/v1/nowhere')
            self.assertEqual((status, body.get('code')), (404, 'not_found'), body)

    def test_the_ledger_refuses_an_append_without_the_write_token(self):
        attestation = dict(environment_id='e1', lifecycle='created')
        with service('ledger-svc', LEDGER_WRITE_TOKEN=WRITE_TOKEN) as ledger:
            for headers in [{}, {'Authorization': 'Bearer wrong'}, {'Authorization': WRITE_TOKEN}]:
                status, body = call(ledger, '/v1/attestations', attestation, headers)
                self.assertEqual((status, body.get('code')), (401, 'write_token_required'), headers)
            status, body = call(ledger, '/v1/settlements/adjust', dict(match_id='m1', case_id='c1'))
            self.assertEqual((status, body.get('code')), (401, 'write_token_required'), body)
            self.assertEqual(call(ledger, '/v1/attestations')[1]['entries'], [], 'reads stay open; refused appends add nothing')
            self.assertEqual(call(ledger, '/v1/attestations', attestation, BEARER)[0], 201)
            self.assertEqual(len(call(ledger, '/v1/attestations')[1]['entries']), 1)
            self.assertTrue(call(ledger, '/v1/verify')[1]['attestation_ok'])

    def test_platform_refunds_a_case_through_the_ledger_with_the_write_token(self):
        with service('ledger-svc', LEDGER_WRITE_TOKEN=WRITE_TOKEN) as ledger, \
                service('platform-svc', LEDGER_URL=ledger, LEDGER_WRITE_TOKEN=WRITE_TOKEN) as platform:
            self.assertEqual(call(ledger, '/v1/settlements/instructions', INSTRUCTION, BEARER)[0], 201)
            self.assertEqual(call(ledger, '/v1/settlements/confirm', {'match_id': 'm1'}, BEARER)[0], 201)
            self.assertEqual(call(platform, '/v1/support/cases/refund', {'case_id': 'support-0001'})[0], 404)
            case_id = call(platform, '/v1/support/cases', dict(match_id='m1', metadata={}))[1]['case_id']
            status, refund = call(platform, '/v1/support/cases/refund', {'case_id': case_id})
            self.assertEqual((status, refund), (201, dict(match_id='m1', case_id=case_id, adjustment_entries=4)))
            self.assertEqual(call(platform, '/v1/support/cases/refund', {'case_id': case_id}), (200, refund))
            settlement = call(ledger, '/v1/settlements/match/m1')[1]
            self.assertEqual(settlement['total_cents'], 0, settlement)
            self.assertEqual({e['case_id'] for e in settlement['entries'] if e.get('entry_type') == 'adjustment'}, {case_id})
        # Without the token the ledger's refusal comes back as it was answered.
        with service('ledger-svc', LEDGER_WRITE_TOKEN=WRITE_TOKEN) as ledger, service('platform-svc', LEDGER_URL=ledger) as platform:
            case_id = call(platform, '/v1/support/cases', dict(match_id='m1', metadata={}))[1]['case_id']
            status, body = call(platform, '/v1/support/cases/refund', {'case_id': case_id})
            self.assertEqual((status, body.get('code')), (401, 'write_token_required'), body)

    def test_platform_refunds_the_case_match_whatever_the_body_names(self):
        other = {**INSTRUCTION, 'match_id': 'other'}
        with service('ledger-svc', LEDGER_WRITE_TOKEN=WRITE_TOKEN) as ledger, \
                service('platform-svc', LEDGER_URL=ledger, LEDGER_WRITE_TOKEN=WRITE_TOKEN) as platform:
            for instruction in (INSTRUCTION, other):
                self.assertEqual(call(ledger, '/v1/settlements/instructions', instruction, BEARER)[0], 201)
                self.assertEqual(call(ledger, '/v1/settlements/confirm', {'match_id': instruction['match_id']}, BEARER)[0], 201)
            untouched = call(ledger, '/v1/settlements/match/other')[1]
            case_id = call(platform, '/v1/support/cases', dict(match_id='m1', metadata={}))[1]['case_id']
            status, refund = call(platform, '/v1/support/cases/refund', {'case_id': case_id, 'match_id': 'other'})
            self.assertEqual((status, refund.get('match_id')), (201, 'm1'), refund)
            settlement = call(ledger, '/v1/settlements/match/m1')[1]
            self.assertEqual(settlement['total_cents'], 0, settlement)
            self.assertEqual({e['case_id'] for e in settlement['entries'] if e.get('entry_type') == 'adjustment'}, {case_id})
            self.assertEqual(call(ledger, '/v1/settlements/match/other')[1], untouched, 'the body named another match')

    def test_every_ledger_writer_carries_the_write_token(self):
        token = dict(LEDGER_WRITE_TOKEN=WRITE_TOKEN)
        with service('ledger-svc', **token) as ledger, peer(lambda *_: (200, {})) as sink, \
                service('seller-svc', COORDINATOR_URL=sink, CONNECT_URL=sink, LEDGER_URL=ledger, **token) as seller:
            self.assertEqual(call(seller, '/v1/offers', OFFER)[0], 201)

            def upstream(path, body):
                if path == '/v1/verify':
                    return 200, dict(actor='buyer', **{'class': 'person'})
                if path == '/v1/placements':
                    return 200, dict(endpoint=stub)
                if path == '/v1/environments':
                    return 201, dict(environment_id='e1', need_context='dress', shortlist=[OFFER])
                if path.startswith('/v1/campaigns/'):
                    return 200, dict(campaigns=[])
                return call(seller, path, body)
            with peer(upstream) as stub, \
                    service('fabric-coordinator', IDENTITY_URL=stub, RESOURCE_URL=stub, ADS_URL=stub, SELLER_URL=stub,
                            LEDGER_URL=ledger, **token) as coordinator, \
                    service('platform-svc', LEDGER_URL=ledger, **token) as platform:
                status, need = call(coordinator, '/v1/needs', dict(token='token', jurisdiction='eu', envelope='sealed'))
                self.assertEqual(status, 201, need)
                status, booked = call(coordinator, '/v1/bookings', dict(handle=need['handle'], offer_id='o1'))
                self.assertEqual(status, 201, booked)
                for state in ('provisioning', 'fulfilled'):
                    status, order = call(seller, '/v1/orders/advance', dict(match_id=booked['match_id'], state=state))
                    self.assertEqual(status, 200, order)
                self.assertEqual(order['state'], 'settled')
                status, revoked = call(coordinator, '/v1/consents', dict(token='token', grant_type='participation', action='revoke'))
                self.assertEqual(status, 201, revoked)
                case_id = call(platform, '/v1/support/cases', dict(match_id=booked['match_id'], metadata={}))[1]['case_id']
                self.assertEqual(call(platform, '/v1/support/cases/refund', {'case_id': case_id})[0], 201)
                consents = [e['payload']['action'] for e in call(ledger, '/v1/consents')[1]['entries']]
                self.assertEqual(consents, ['use', 'revoke'])
                settlement = call(ledger, '/v1/settlements/match/' + booked['match_id'])[1]
                self.assertEqual((settlement['confirmed'], len(settlement['entries']), settlement['total_cents']),
                                 (True, 8, 0), settlement)
                with service('audit-svc', LEDGER_URL=ledger) as audit:
                    self.assertTrue(call(audit, '/v1/certify', {})[1]['consent']['ok'])


class DurableContracts(unittest.TestCase):
    """Run explicitly with AMISAD_TEST_DATABASE_URL pointing at an empty disposable schema."""
    def test_tenant_ownership_with_stale_store(self):
        database = os.environ['AMISAD_TEST_DATABASE_URL']
        with peer(lambda *_: (200, {})) as sink, service('seller-svc', DATABASE_URL=database, COORDINATOR_URL=sink, CONNECT_URL=sink) as first, service('seller-svc', DATABASE_URL=database, COORDINATOR_URL=sink, CONNECT_URL=sink) as stale:
            offer = {**OFFER, 'offer_id': 'concurrent-offer'}
            self.assertEqual(call(first, '/v1/offers', offer)[0], 201)
            self.assertEqual(call(stale, '/v1/offers', {**offer, 'tenant': 'tenant-a'})[0], 403)
        with peer(lambda *_: (200, {})) as sink, service('seller-svc', DATABASE_URL=database, COORDINATOR_URL=sink, CONNECT_URL=sink) as reloaded:
            offers = call(reloaded, '/v1/offers/region/eu')[1]['offers']
            self.assertEqual(next(o for o in offers if o['offer_id'] == 'concurrent-offer')['tenant'], 'tenant-b')

    def test_inventory_version_survives_restart(self):
        database = os.environ['AMISAD_TEST_DATABASE_URL']
        offer = {**OFFER, 'offer_id': 'inventory-durable'}
        update = dict(tenant=offer['tenant'], offer_id=offer['offer_id'], stock=0, delta_ts=20)
        with peer(lambda *_: (200, {})) as sink:
            with service('seller-svc', DATABASE_URL=database, COORDINATOR_URL=sink, CONNECT_URL=sink) as seller:
                self.assertEqual(call(seller, '/v1/offers', offer)[0], 201)
                self.assertEqual(call(seller, '/v1/offers/inventory', update)[0], 200)
            with service('seller-svc', DATABASE_URL=database, COORDINATOR_URL=sink, CONNECT_URL=sink) as seller:
                self.assertNotIn(offer, call(seller, '/v1/offers/region/eu')[1]['offers'])
                self.assertEqual(call(seller, '/v1/offers/inventory', dict(update, stock=5, delta_ts=10))[0], 409)
                self.assertEqual(call(seller, '/v1/offers/inventory', update)[0], 200)
                self.assertEqual(call(seller, '/v1/offers/inventory', dict(update, stock=5, delta_ts=30))[0], 200)

    def test_replay_and_settlement_across_restart(self):
        database = os.environ['AMISAD_TEST_DATABASE_URL']
        order = dict(match_id='durable', offer_id='o1', tenant='tenant-b')
        instruction = {**INSTRUCTION, 'match_id': 'durable'}
        refund = dict(match_id='durable', case_id='durable-case')
        with peer(lambda *_: (503, {})) as failing:
            with service('seller-svc', DATABASE_URL=database, COORDINATOR_URL=failing, CONNECT_URL=failing, LEDGER_URL=failing) as seller, service('ledger-svc', DATABASE_URL=database) as ledger:
                self.assertEqual(call(seller, '/v1/offers', OFFER)[0], 201)
                self.assertEqual(call(ledger, '/v1/settlements/instructions', instruction)[0], 201)
                self.assertEqual(call(seller, '/v1/orders', order)[0], 201)
                call(seller, '/v1/orders/advance', dict(match_id='durable', state='provisioning'))
                self.assertEqual(call(seller, '/v1/orders/advance', dict(match_id='durable', state='fulfilled'))[0], 503)
                self.assertEqual(call(ledger, '/v1/settlements/confirm', {'match_id': 'durable'})[0], 201)
            with service('ledger-svc', DATABASE_URL=database) as ledger, service('seller-svc', DATABASE_URL=database, COORDINATOR_URL=failing, CONNECT_URL=failing, LEDGER_URL=ledger) as seller:
                self.assertEqual(call(seller, '/v1/orders/match/durable')[1]['state'], 'provisioning')
                self.assertEqual(call(seller, '/v1/orders/advance', dict(match_id='durable', state='fulfilled'))[1]['state'], 'settled')
                self.assertEqual(call(seller, '/v1/orders', order)[0], 200)
                self.assertEqual(call(ledger, '/v1/settlements/instructions', instruction)[0], 200)
                original = call(ledger, '/v1/settlements/adjust', refund)[1]
                chain = call(ledger, '/v1/settlements')[1]
            with service('ledger-svc', DATABASE_URL=database) as ledger, service('seller-svc', DATABASE_URL=database, COORDINATOR_URL=failing, CONNECT_URL=failing) as seller:
                self.assertEqual(call(ledger, '/v1/settlements/adjust', refund), (200, original))
                self.assertEqual(call(ledger, '/v1/settlements')[1], chain)
                self.assertEqual(call(ledger, '/v1/settlements/match/durable')[1]['total_cents'], 0)
                self.assertEqual(call(seller, '/v1/offers', {**OFFER, 'tenant': 'tenant-a'})[0], 403)
                self.assertEqual(call(seller, '/v1/orders/match/durable')[1]['state'], 'settled')

    def test_policy_survives_restart(self):
        # Edges register again after a restart; a policy that did not survive
        # would let its jurisdiction land on the roomier, non-compliant region.
        database = os.environ['AMISAD_TEST_DATABASE_URL']
        with service('resource-svc', DATABASE_URL=database) as resource:
            self.assertEqual(call(resource, '/v1/policies', dict(jurisdiction='durable-eu', regions=['durable-eu']))[0], 201)
        with service('resource-svc', DATABASE_URL=database) as resource:
            for region, capacity in [('durable-eu', 1), ('elsewhere', 10)]:
                self.assertEqual(call(resource, '/v1/edges', dict(region=region, endpoint=f'http://{region}:8080', capacity=capacity))[0], 201)
            self.assertEqual(call(resource, '/v1/placements', dict(jurisdiction='durable-eu')),
                             (200, dict(region='durable-eu', endpoint='http://durable-eu:8080')))


if __name__ == '__main__':
    unittest.main(defaultTest="Contracts")
