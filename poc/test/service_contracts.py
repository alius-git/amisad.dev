#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
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
OFFER = dict(offer_id='o1', tenant='tenant-b', title='Dress', category='dress', region='eu', price_cents=100)
INSTRUCTION = dict(match_id='m1', value_cents=100, splits=dict(seller_cents=80, network_cents=10, platform_cents=10, ads_cents=0))


def call(url, path, body=None):
    conn = http.client.HTTPConnection(url.removeprefix('http://'), timeout=3)
    try:
        conn.request('GET' if body is None else 'POST', path, None if body is None else json.dumps(body))
        response = conn.getresponse()
        return response.status, json.loads(response.read())
    finally:
        conn.close()


@contextlib.contextmanager
def peer(handler):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            status, result = handler(self.path, None)
            self.reply(status, result)

        def do_POST(self):
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
            dump[0] = {'entries': [], 'head': '0' * 64}
            self.assertTrue(call(audit, '/v1/certify', {})[1]['certified'])

    def test_booking_recovers_from_seller_failure_and_response_loss(self):
        for lose_response in [False, True]:
            with self.subTest(lose_response=lose_response), peer(lambda *_: (200, {})) as sink, service('seller-svc', COORDINATOR_URL=sink, CONNECT_URL=sink) as seller, service('ledger-svc') as ledger:
                call(seller, '/v1/offers', OFFER)
                failed = [False]
                def upstream(path, body):
                    if path == '/v1/verify':
                        return 200, dict(actor='buyer', **{'class': 'person'})
                    if path == '/v1/placements':
                        return 200, dict(endpoint=stub)
                    if path == '/v1/environments':
                        return 201, dict(environment_id='e1', need_context='dress', shortlist=[OFFER])
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


if __name__ == '__main__':
    unittest.main(defaultTest="Contracts")
