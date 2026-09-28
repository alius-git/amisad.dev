"""Run against a disposable schema; DATABASE_POLICY_URL and PSQL are required."""
import contextlib
import http.client
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest
from service_contracts import BIN, OFFER, INSTRUCTION, call

DATABASE = os.environ['DATABASE_POLICY_URL']
PSQL = os.environ.get('PSQL', 'psql')


def sql(statement):
    return subprocess.check_output([PSQL, DATABASE, '-v', 'ON_ERROR_STOP=1', '-Atc', statement], text=True)


class DatabasePolicy(unittest.TestCase):
    def test_invalid_configuration_exits(self):
        for name in ('seller-svc', 'ledger-svc'):
            result = subprocess.run([str(BIN / name)], env={**os.environ, 'DATABASE_URL': 'invalid option'}, capture_output=True, timeout=5)
            self.assertEqual(result.returncode, 1)
            self.assertIn(b'connection failed', result.stderr)

    def test_sql_error_survives_and_closed_connection_exits(self):
        for name, table, endpoint, body in [('seller-svc', 'seller.offers', '/v1/offers', OFFER), ('ledger-svc', 'ledger.settlement_instructions', '/v1/settlements/instructions', INSTRUCTION)]:
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0))
                port = sock.getsockname()[1]
            url = f'http://127.0.0.1:{port}'
            with tempfile.TemporaryFile() as log:
                proc = subprocess.Popen([str(BIN / name)], stdout=log, stderr=log, env={**os.environ, 'PORT': str(port), 'DATABASE_URL': DATABASE + '?application_name=low-' + name})
                renamed = False
                try:
                    for _ in range(100):
                        try:
                            if call(url, '/health')[0] == 200:
                                break
                        except OSError:
                            time.sleep(.02)
                    else:
                        raise AssertionError('service did not start')
                    sql(f'ALTER TABLE {table} RENAME TO policy_fixture_hidden')
                    renamed = True
                    self.assertEqual(call(url, endpoint, body)[0], 503)
                    self.assertIsNone(proc.poll())
                    sql(f'ALTER TABLE {table.split(".")[0]}.policy_fixture_hidden RENAME TO {table.split(".")[1]}')
                    renamed = False
                    self.assertEqual(call(url, '/health')[0], 200)
                    sql(f"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE application_name='low-{name}'")
                    try:
                        call(url, endpoint, body)
                    except (OSError, http.client.HTTPException):
                        pass
                    self.assertEqual(proc.wait(timeout=5), 1)
                    log.seek(0)
                    self.assertIn(b'connection lost', log.read())
                finally:
                    if renamed:
                        sql(f'ALTER TABLE {table.split(".")[0]}.policy_fixture_hidden RENAME TO {table.split(".")[1]}')
                    if proc.poll() is None:
                        proc.terminate()
                    proc.wait(timeout=5)


if __name__ == '__main__':
    unittest.main()
