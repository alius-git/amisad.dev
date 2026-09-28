"""Run against a disposable schema; DATABASE_POLICY_URL and PSQL are required."""
import contextlib
import http.client
import os
import re
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
    def test_provisioned_inventory_permissions(self):
        root = Path(__file__).resolve().parents[1]
        source = (root / 'test/ubuntu.server.24/ubuntu.server.24.amisad-core.db.sh').read_text()
        grants = re.search(r"<<'SQL'\n(.*?)\nSQL", source, re.DOTALL)
        self.assertIsNotNone(grants, 'database provisioning SQL block is missing')
        # Execute the provisioning grants against real PostgreSQL, then exercise
        # the application role rather than the schema owner's implicit access.
        result = sql('BEGIN;\n' + (root / 'db/schema.sql').read_text() + """
DO $$ BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'amisad') THEN
        CREATE ROLE amisad LOGIN;
    END IF;
END $$;
REVOKE ALL ON ALL TABLES IN SCHEMA seller, ledger FROM amisad;
""" + grants.group(1) + """
SET LOCAL ROLE amisad;
SELECT current_user, rolsuper FROM pg_roles WHERE rolname = current_user;
INSERT INTO seller.offers (offer_id, tenant, title, category, region, price_cents)
VALUES ('provisioning-inventory', 'tenant', 'Offer', 'test', 'test', 100);
INSERT INTO seller.inventory (offer_id, stock, delta_ts)
VALUES ('provisioning-inventory', 5, 20);
UPDATE seller.inventory SET stock = 7, delta_ts = 21
WHERE offer_id = 'provisioning-inventory';
SELECT stock, delta_ts FROM seller.inventory WHERE offer_id = 'provisioning-inventory';
SELECT has_table_privilege(current_user, 'seller.inventory', 'DELETE');
SELECT has_table_privilege(current_user, table_name, 'UPDATE')
    OR has_table_privilege(current_user, table_name, 'DELETE')
FROM (VALUES ('ledger.consent_ledger'), ('ledger.settlement_ledger'),
             ('ledger.attestation_ledger')) AS ledgers(table_name);
ROLLBACK;
""")
        lines = result.splitlines()
        self.assertIn('amisad|f', lines)
        self.assertIn('7|21', lines)
        self.assertEqual(lines[-5:], ['f', 'f', 'f', 'f', 'ROLLBACK'])

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
