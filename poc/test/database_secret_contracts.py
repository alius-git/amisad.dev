#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# GUID: 42fa8db5-7c9d-4a74-950a-f95b2fc39e9b
"""The database role's password: made for each build by the deploy step, set
through psql standard input, published only as the Kubernetes Secret the
ledger, seller and resource charts read, and written nowhere else. The ledger
write token: made for each build by the same step, right after the password,
and published only as the Kubernetes Secret the ledger and its writers read.

The deploy step's function runs with private openssl, sudo, pg_isready, psql
and kubectl fixtures that log their arguments and standard input; base64 and tr
are the real tools. The apiserver fixture can refuse its first dials and the
PostgreSQL fixtures can refuse their first connections, the way a cluster and a
database that are still starting do.
"""
import base64
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
import unittest

from bash_contract_support import find_usable_bash

ROOT = Path(__file__).resolve().parents[1]
GUEST = ROOT / 'test/ubuntu.server.24'
DEPLOY = GUEST / 'ubuntu.server.24.amisad-core.deploy.sh'
DB = GUEST / 'ubuntu.server.24.amisad-core.db.sh'
CHARTS = ROOT / 'workloads/services'
BASH = find_usable_bash()
FUNCTION = 'amisad_publish_database_password'
TOKEN_FUNCTION = 'amisad_publish_ledger_write_token'
LEDGER_WRITERS = ('ledger-svc', 'fabric-coordinator', 'seller-svc', 'platform-svc')
SET_LINES = ["SET log_statement = 'none';", 'SET log_min_duration_statement = -1;',
             "SET log_min_error_statement = 'panic';"]
FIXTURE_SWITCHES = ('FAIL_OPENSSL', 'OPENSSL_OUTPUT', 'FAIL_PSQL', 'FAIL_DELETE', 'FAIL_CREATE', 'NO_NAMESPACE',
                    'APISERVER_DOWN_FOR', 'POSTGRES_DOWN_FOR')
SECRET_HEAD = ['apiVersion: v1', 'kind: Secret', 'metadata:', '  name: amisad-database',
               '  namespace: amisad', 'type: Opaque', 'data:']
TOKEN_SECRET_HEAD = ['apiVersion: v1', 'kind: Secret', 'metadata:', '  name: amisad-ledger-write',
                     '  namespace: amisad', 'type: Opaque', 'data:']
TOKEN_DELETE = 'kubectl -n amisad delete secret amisad-ledger-write --ignore-not-found'
READYZ = 'kubectl --request-timeout=2s get --raw=/readyz'
PG_READY = ['sudo -u postgres pg_isready -q', 'pg_isready -q']
# Each fixture logs its command line to argv, in call order, from the case's
# working directory. APISERVER_DOWN_FOR=<n> refuses the first n kubectl calls of
# any kind, and POSTGRES_DOWN_FOR=<n> the first n pg_isready or psql
# connections; 'always' refuses every one.
DOWN = '''down_for() { # <counter file> <switch value>
    echo x >> "$1"
    [ "${2:-0}" = always ] || [ "$(( $(wc -l < "$1") ))" -le "${2:-0}" ]
}
'''
FIXTURES = {
    'openssl': '''echo "openssl $*" >> argv
[ -z "${FAIL_OPENSSL:-}" ] || exit 1
if [ -n "${OPENSSL_OUTPUT+set}" ]; then printf '%s\\n' "$OPENSSL_OUTPUT"; exit 0; fi
od -An -N"${!#}" -tx1 /dev/urandom | tr -d ' \\n'
echo''',
    'sudo': '''echo "sudo $*" >> argv
[ "$1 $2" = '-u postgres' ] || exit 40
shift 2
exec "$@"''',
    'pg_isready': DOWN + '''echo "pg_isready $*" >> argv
! down_for postgres.contacts "${POSTGRES_DOWN_FOR:-}" || exit 2''',
    'psql': DOWN + '''echo "psql $*" >> argv
if down_for postgres.contacts "${POSTGRES_DOWN_FOR:-}"; then
    echo 'psql: error: connection to server on socket "/var/run/postgresql/.s.PGSQL.5432" failed: No such file or directory' >&2
    exit 2
fi
cat > psql.stdin
cat psql.stdin >> psql.history
if [ -n "${FAIL_PSQL:-}" ]; then
    echo "ERROR:  fixture refusal at: $(tail -n 1 psql.stdin)" >&2
    exit 3
fi''',
    'kubectl': DOWN + '''echo "kubectl $*" >> argv
if down_for kubectl.contacts "${APISERVER_DOWN_FOR:-}"; then
    echo 'The connection to the server 127.0.0.1:6443 was refused - did you specify the right host or port?' >&2
    exit 1
fi
case "$*" in
'--request-timeout='[12]'s get --raw=/readyz') echo ok ;;
'get namespace amisad') [ -z "${NO_NAMESPACE:-}" ] ;;
'create namespace amisad') echo 'namespace/amisad created' ;;
'-n amisad delete secret amisad-database --ignore-not-found')
    if [ -n "${FAIL_DELETE:-}" ]; then echo 'error: fixture refused the delete' >&2; exit 5; fi
    echo 'secret "amisad-database" deleted' ;;
'-n amisad delete secret amisad-ledger-write --ignore-not-found')
    if [ -n "${FAIL_DELETE:-}" ]; then echo 'error: fixture refused the delete' >&2; exit 5; fi
    echo 'secret "amisad-ledger-write" deleted' ;;
'create -f -')
    cat > secret.yaml
    if [ -n "${FAIL_CREATE:-}" ]; then
        printf 'error: fixture refused this manifest:\\n%s\\n' "$(cat secret.yaml)" >&2
        exit 4
    fi
    echo 'secret/amisad-database created' ;;
*) exit 41 ;;
esac''',
}


def function_text(name=FUNCTION):
    """The deploy step's function, from its name to the closing parenthesis of its subshell body."""
    match = re.search(r'(?ms)^' + name + r'\(\) \(\n.*?^\)$', DEPLOY.read_text(encoding='utf-8'))
    if not match:
        raise AssertionError(f'{name} is not defined in {DEPLOY.name}')
    return match.group(0)


class DeployFunctionRun:
    """Runs one of the deploy step's functions, named by `function`, against the fixtures."""
    function = FUNCTION

    def run_function(self, directory, script=None, **env):
        root = Path(directory)
        (root / 'bin').mkdir(exist_ok=True)
        for name, body in FIXTURES.items():
            path = root / 'bin' / name
            path.write_bytes(('#!/bin/bash\n' + body + '\n').encode())
            path.chmod(0o755)
        script = self.function + '\n' if script is None else script
        (root / 'case.sh').write_bytes(('set -euo pipefail\n' + function_text(self.function) + '\n' + script).encode())
        result = subprocess.run([BASH, '-c', 'export PATH="$PWD/bin:$PATH"; exec "$BASH" case.sh'],
                                cwd=root, env={**{key: value for key, value in os.environ.items()
                                                  if key not in FIXTURE_SWITCHES}, **env},
                                capture_output=True, text=True, timeout=30)
        calls = (root / 'argv').read_text().splitlines() if (root / 'argv').exists() else []
        return result, calls


@unittest.skipUnless(BASH, 'A usable native-filesystem Bash is required for guest shell contracts')
class PublishDatabasePassword(DeployFunctionRun, unittest.TestCase):

    def sent_password(self, directory):
        """The password the ALTER carried on psql's standard input, after the three SET lines."""
        lines = (Path(directory) / 'psql.stdin').read_text().splitlines()
        self.assertEqual(lines[:3], SET_LINES)
        self.assertEqual(len(lines), 4, lines)
        match = re.fullmatch(r"ALTER ROLE amisad LOGIN PASSWORD '([0-9a-f]{48})';", lines[3])
        self.assertIsNotNone(match, lines[3])
        return match.group(1)

    def test_each_run_sets_a_new_48_hex_password_through_psql_standard_input_only(self):
        passwords = []
        for _ in range(2):
            with tempfile.TemporaryDirectory() as directory:
                result, calls = self.run_function(directory)
                self.assertEqual(result.returncode, 0, result.stderr)
                password = self.sent_password(directory)
                self.assertIn('openssl rand -hex 24', calls)
                self.assertIn('sudo -u postgres psql -v ON_ERROR_STOP=1 -d amisad -f -', calls)
                self.assertNotIn(password, '\n'.join(calls))
                self.assertNotIn(password, result.stdout + result.stderr)
                passwords.append(password)
        self.assertNotEqual(passwords[0], passwords[1])

    def test_the_secret_carries_the_same_password_and_is_created_not_applied_after_the_previous_one_is_deleted(self):
        for missing, namespace_calls in ((False, ['kubectl get namespace amisad']),
                                         (True, ['kubectl get namespace amisad', 'kubectl create namespace amisad'])):
            with self.subTest(namespace_missing=missing), tempfile.TemporaryDirectory() as directory:
                result, calls = self.run_function(directory, **({'NO_NAMESPACE': '1'} if missing else {}))
                self.assertEqual(result.returncode, 0, result.stderr)
                password = self.sent_password(directory)
                self.assertEqual([c for c in calls if c.startswith('kubectl ')], [READYZ] + namespace_calls + [
                    'kubectl -n amisad delete secret amisad-database --ignore-not-found', 'kubectl create -f -'])
                psql = calls.index('psql -v ON_ERROR_STOP=1 -d amisad -f -')
                self.assertLess(calls.index(namespace_calls[-1]), psql)
                self.assertLess(psql, calls.index('kubectl -n amisad delete secret amisad-database --ignore-not-found'))
                self.assertLess(psql, calls.index('kubectl create -f -'))
                manifest = (Path(directory) / 'secret.yaml').read_text().splitlines()
                self.assertEqual(manifest[:-1], SECRET_HEAD)
                key, _, encoded = manifest[-1].partition(': ')
                self.assertEqual(key, '  password')
                self.assertEqual(base64.b64decode(encoded, validate=True).decode(), password)
                for secret in (password, encoded):
                    self.assertNotIn(secret, '\n'.join(calls))
                    self.assertNotIn(secret, result.stdout + result.stderr)
                self.assertIn('published only as Secret amisad/amisad-database', result.stdout)

    def test_a_failing_psql_stops_before_any_secret_and_never_prints_the_password(self):
        with tempfile.TemporaryDirectory() as directory:
            result, calls = self.run_function(directory, FAIL_PSQL='1')
            self.assertNotEqual(result.returncode, 0)
            password = self.sent_password(directory)
            self.assertEqual([c for c in calls if c.startswith('kubectl ')], [READYZ, 'kubectl get namespace amisad'])
            self.assertIn('could not set the amisad role password', result.stderr)
            self.assertIn("fixture refusal at: ALTER ROLE amisad LOGIN PASSWORD '<redacted>';", result.stderr)
            self.assertNotIn(password, result.stdout + result.stderr)

    def test_a_failing_secret_create_names_the_cause_without_the_password(self):
        with tempfile.TemporaryDirectory() as directory:
            result, calls = self.run_function(directory, FAIL_CREATE='1')
            self.assertNotEqual(result.returncode, 0)
            password = self.sent_password(directory)
            encoded = (Path(directory) / 'secret.yaml').read_text().splitlines()[-1].partition(': ')[2]
            self.assertIn('could not create Secret amisad/amisad-database', result.stderr)
            self.assertIn('  password: <redacted>', result.stderr)
            for secret in (password, encoded):
                self.assertNotIn(secret, result.stdout + result.stderr)

    def test_output_that_is_not_hex_is_refused_before_it_reaches_sql(self):
        for case in ({'OPENSSL_OUTPUT': "x'; DROP ROLE amisad; --"}, {'OPENSSL_OUTPUT': '0123456789abcdef'},
                     {'OPENSSL_OUTPUT': ''}, {'FAIL_OPENSSL': '1'}):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                result, calls = self.run_function(directory, **case)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, [READYZ] + PG_READY + ['openssl rand -hex 24'])
                self.assertFalse((Path(directory) / 'psql.stdin').exists())
                self.assertIn('openssl did not return 24 random bytes as 48 hex characters', result.stderr)

    def test_the_trace_never_shows_the_password_and_comes_back_on(self):
        with tempfile.TemporaryDirectory() as directory:
            result, _ = self.run_function(directory, script=f'set -x\n{FUNCTION}\necho "flags after: $-"\n')
            self.assertEqual(result.returncode, 0, result.stderr)
            password = self.sent_password(directory)
            encoded = (Path(directory) / 'secret.yaml').read_text().splitlines()[-1].partition(': ')[2]
            self.assertIn('+ ' + FUNCTION, result.stderr)
            for secret in (password, encoded):
                self.assertNotIn(secret, result.stderr)
            self.assertRegex(result.stdout, r'flags after: \S*x')
            self.assertIn('+ echo', result.stderr)

    def test_a_refused_apiserver_is_waited_for_before_the_password_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            result, calls = self.run_function(directory, APISERVER_DOWN_FOR='2')
            self.assertEqual(result.returncode, 0, result.stderr)
            kubectl = [c for c in calls if c.startswith('kubectl ')]
            # The two refused dials and the answered one are all readiness probes.
            self.assertEqual(kubectl[:3], [READYZ] * 3)
            self.assertEqual(kubectl[3:], ['kubectl get namespace amisad',
                                           'kubectl -n amisad delete secret amisad-database --ignore-not-found',
                                           'kubectl create -f -'])
            self.assertLess(len(calls) - 1 - calls[::-1].index(READYZ), calls.index('psql -v ON_ERROR_STOP=1 -d amisad -f -'))
            password = self.sent_password(directory)
            encoded = (Path(directory) / 'secret.yaml').read_text().splitlines()[-1].partition(': ')[2]
            self.assertEqual(base64.b64decode(encoded, validate=True).decode(), password)

    def test_postgres_is_waited_for_before_the_alter(self):
        with tempfile.TemporaryDirectory() as directory:
            result, calls = self.run_function(directory, POSTGRES_DOWN_FOR='2')
            self.assertEqual(result.returncode, 0, result.stderr)
            postgres = [c for c in calls if c.startswith(('pg_isready ', 'psql '))]
            self.assertEqual(postgres, ['pg_isready -q'] * 3 + ['psql -v ON_ERROR_STOP=1 -d amisad -f -'])
            self.assertEqual(len((Path(directory) / 'psql.history').read_text().splitlines()), 4)
            self.sent_password(directory)

    def test_a_dependency_that_never_answers_ends_the_wait_naming_it_and_changes_nothing(self):
        api = 'the apiserver did not answer /readyz within 2s'
        database = 'PostgreSQL did not accept connections (pg_isready) within 2s'
        for case, named, unnamed in (({'APISERVER_DOWN_FOR': 'always'}, [api], [database]),
                                     ({'POSTGRES_DOWN_FOR': 'always'}, [database], [api]),
                                     ({'APISERVER_DOWN_FOR': 'always', 'POSTGRES_DOWN_FOR': 'always'}, [api, database], [])):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                started = time.monotonic()
                result, calls = self.run_function(directory, script=FUNCTION + ' 2\n', **case)
                self.assertLess(time.monotonic() - started, 10)
                self.assertNotEqual(result.returncode, 0)
                for text in named:
                    self.assertIn(text, result.stderr)
                for text in unnamed:
                    self.assertNotIn(text, result.stderr)
                self.assertIn('the role password was not changed', result.stderr)
                if 'APISERVER_DOWN_FOR' in case:
                    self.assertIn('was refused', result.stderr)
                self.assertFalse((Path(directory) / 'psql.stdin').exists())
                self.assertEqual({c.split(' ')[0] for c in calls} - {'kubectl', 'sudo', 'pg_isready'}, set())
                self.assertEqual({c for c in calls if c.startswith('kubectl ')} - {READYZ, READYZ.replace('=2s', '=1s')}, set())

    def test_a_failure_after_the_alter_is_repaired_by_the_next_run(self):
        for switch in ('FAIL_DELETE', 'FAIL_CREATE'):
            with self.subTest(switch=switch), tempfile.TemporaryDirectory() as directory:
                failed, _ = self.run_function(directory, **{switch: '1'})
                self.assertNotEqual(failed.returncode, 0)
                self.assertIn('the role password changed, but Secret amisad/amisad-database does not carry it', failed.stderr)
                self.assertIn('the next run of this step sets a new password and creates the Secret again', failed.stderr)
                stale = self.sent_password(directory)
                result, calls = self.run_function(directory)
                self.assertEqual(result.returncode, 0, result.stderr)
                current = self.sent_password(directory)
                self.assertNotEqual(current, stale)
                history = (Path(directory) / 'psql.history').read_text().splitlines()
                self.assertEqual([line for line in history if line.startswith('ALTER ROLE')],
                                 [f"ALTER ROLE amisad LOGIN PASSWORD '{stale}';", f"ALTER ROLE amisad LOGIN PASSWORD '{current}';"])
                encoded = (Path(directory) / 'secret.yaml').read_text().splitlines()[-1].partition(': ')[2]
                self.assertEqual(base64.b64decode(encoded, validate=True).decode(), current)
                second = calls[len(calls) - 1 - calls[::-1].index('psql -v ON_ERROR_STOP=1 -d amisad -f -'):]
                self.assertEqual([c for c in second if c.startswith('kubectl ')],
                                 ['kubectl -n amisad delete secret amisad-database --ignore-not-found', 'kubectl create -f -'])


@unittest.skipUnless(BASH, 'A usable native-filesystem Bash is required for guest shell contracts')
class PublishLedgerWriteToken(DeployFunctionRun, unittest.TestCase):
    function = TOKEN_FUNCTION

    def sent_token(self, directory):
        """The token the Secret manifest on kubectl's standard input carried, and its base64."""
        manifest = (Path(directory) / 'secret.yaml').read_text().splitlines()
        self.assertEqual(manifest[:-1], TOKEN_SECRET_HEAD)
        key, _, encoded = manifest[-1].partition(': ')
        self.assertEqual(key, '  token')
        token = base64.b64decode(encoded, validate=True).decode()
        self.assertRegex(token, r'^[0-9a-f]{64}$')
        return token, encoded

    def test_each_run_publishes_a_new_64_hex_token_through_kubectl_standard_input_only(self):
        tokens = []
        for _ in range(2):
            with tempfile.TemporaryDirectory() as directory:
                result, calls = self.run_function(directory)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(calls, ['openssl rand -hex 32', TOKEN_DELETE, 'kubectl create -f -'])
                token, encoded = self.sent_token(directory)
                for secret in (token, encoded):
                    self.assertNotIn(secret, '\n'.join(calls))
                    self.assertNotIn(secret, result.stdout + result.stderr)
                self.assertIn('published only as Secret amisad/amisad-ledger-write', result.stdout)
                self.assertFalse((Path(directory) / 'psql.stdin').exists(), 'the token reached SQL')
                tokens.append(token)
        self.assertNotEqual(tokens[0], tokens[1])

    def test_output_that_is_not_64_hex_is_refused_before_any_secret(self):
        for case in ({'OPENSSL_OUTPUT': 'ab' * 24}, {'OPENSSL_OUTPUT': "x'; --"}, {'OPENSSL_OUTPUT': ''}, {'FAIL_OPENSSL': '1'}):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                result, calls = self.run_function(directory, **case)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(calls, ['openssl rand -hex 32'])
                self.assertIn('openssl did not return 32 random bytes as 64 hex characters', result.stderr)

    def test_a_failing_secret_step_stops_the_deploy_without_the_token(self):
        for switch, cause in (('FAIL_DELETE', 'could not delete the previous Secret amisad/amisad-ledger-write'),
                              ('FAIL_CREATE', 'could not create Secret amisad/amisad-ledger-write')):
            with self.subTest(switch=switch), tempfile.TemporaryDirectory() as directory:
                result, calls = self.run_function(directory, **{switch: '1'})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(cause, result.stderr)
                if switch == 'FAIL_DELETE':
                    self.assertEqual(calls, ['openssl rand -hex 32', TOKEN_DELETE])
                    continue
                token, encoded = self.sent_token(directory)
                self.assertIn('  token: <redacted>', result.stderr)
                for secret in (token, encoded):
                    self.assertNotIn(secret, result.stdout + result.stderr)

    def test_the_trace_never_shows_the_token_and_comes_back_on(self):
        with tempfile.TemporaryDirectory() as directory:
            result, _ = self.run_function(directory, script=f'set -x\n{TOKEN_FUNCTION}\necho "flags after: $-"\n')
            self.assertEqual(result.returncode, 0, result.stderr)
            token, encoded = self.sent_token(directory)
            self.assertIn('+ ' + TOKEN_FUNCTION, result.stderr)
            for secret in (token, encoded):
                self.assertNotIn(secret, result.stderr)
            self.assertRegex(result.stdout, r'flags after: \S*x')



class DeployPath(unittest.TestCase):
    def test_no_tracked_file_carries_a_fixed_database_password(self):
        # Every tracked file, documentation included: a password written in a
        # runbook is as published as one in a chart. The SBOM is generated from
        # the tree, and this file has to name what it looks for.
        repo = ROOT.parent
        listed = subprocess.run(['git', '-C', str(repo), 'ls-files', '-z'], capture_output=True, check=True).stdout
        this = Path(__file__).resolve().relative_to(repo).as_posix()
        paths = [path for path in listed.decode('utf-8').split('\0')
                 if path and path != this and not path.startswith('docs/sbom/')]
        self.assertIn(DEPLOY.relative_to(repo).as_posix(), paths)
        url_with_password = re.compile(rb'postgres(?:ql)?://[^:/@\s]+:(?!\$\()[^@\s]*@')
        fixed, in_url = [], []
        for path in paths:
            target = repo / path
            if target.is_symlink() or not target.is_file():
                continue
            data = target.read_bytes()
            if b'amisadpoc2026' in data:
                fixed.append(path)
            if url_with_password.search(data):
                in_url.append(path)
        self.assertEqual(fixed, [], 'files that carry the former fixed database password')
        self.assertEqual(in_url, [], 'files that write a password into a connection URL')
        self.assertNotIn('PASSWORD', DB.read_text(encoding='utf-8'), 'the db step sets a password of its own')

    def test_each_database_chart_builds_database_url_from_node_ip_and_the_secret_in_that_order(self):
        # The Secret's variable, as the chart renders it whenever a Secret is named.
        entry = ('            {{- if .Values.databasePasswordSecret }}\n'
                 '            - name: AMISAD_DB_PASSWORD\n'
                 '              valueFrom:\n'
                 '                secretKeyRef:\n'
                 '                  name: {{ .Values.databasePasswordSecret | quote }}\n'
                 '                  key: password\n'
                 '            {{- end }}\n')
        for service in ('ledger-svc', 'seller-svc', 'resource-svc'):
            with self.subTest(service=service):
                values = (CHARTS / service / 'values.yaml').read_text(encoding='utf-8')
                self.assertRegex(values, r'(?m)^databasePasswordSecret: ""$')
                template = (CHARTS / service / f'templates/01-{service}.yml').read_text(encoding='utf-8')
                block = template.split('{{- if .Values.databaseUrl }}\n', 1)[1]
                code = ''.join(line for line in block.splitlines(keepends=True) if not line.lstrip().startswith('#'))
                order = [code.find(f'- name: {name}\n') for name in ('NODE_IP', 'AMISAD_DB_PASSWORD', 'DATABASE_URL')]
                self.assertTrue(0 <= order[0] < order[1] < order[2], order)
                self.assertIn(entry, code)
                self.assertIn('            - name: DATABASE_URL\n              value: {{ .Values.databaseUrl | quote }}\n', code)
        self.assertIn("DATABASE_URL='postgres://amisad:$(AMISAD_DB_PASSWORD)@$(NODE_IP):5432/amisad'",
                      DEPLOY.read_text(encoding='utf-8'))

    def test_the_password_is_published_after_the_kube_chown_and_before_any_helm_install(self):
        text = DEPLOY.read_text(encoding='utf-8')
        calls = [match.start() for match in re.finditer(r'(?m)^' + FUNCTION + r'$', text)]
        self.assertEqual(len(calls), 1, f'expected one top-level call of {FUNCTION}')
        chown = text.index('sudo chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.kube"')
        self.assertLess(chown, calls[0])
        self.assertLess(calls[0], text.index('helm upgrade --install'))

    def test_the_token_is_published_after_the_password_and_before_any_helm_install(self):
        # The password's function waits for the apiserver and ensures the
        # namespace; the token's function relies on both.
        text = DEPLOY.read_text(encoding='utf-8')
        calls = [match.start() for match in re.finditer(r'(?m)^' + TOKEN_FUNCTION + r'$', text)]
        self.assertEqual(len(calls), 1, f'expected one top-level call of {TOKEN_FUNCTION}')
        password = re.search(r'(?m)^' + FUNCTION + r'$', text).start()
        self.assertLess(password, calls[0])
        self.assertLess(calls[0], text.index('helm upgrade --install'))

    def test_each_ledger_writer_chart_reads_the_token_from_the_secret(self):
        entry = ('            {{- if .Values.ledgerWriteSecret }}\n'
                 '            # The bearer token ledger-svc requires on appends. Only this Secret\n'
                 '            # carries it; the deploy step makes a new one for each build.\n'
                 '            - name: LEDGER_WRITE_TOKEN\n'
                 '              valueFrom:\n'
                 '                secretKeyRef:\n'
                 '                  name: {{ .Values.ledgerWriteSecret | quote }}\n'
                 '                  key: token\n'
                 '            {{- end }}\n')
        for chart in sorted(path.name for path in CHARTS.iterdir() if path.is_dir()):
            with self.subTest(chart=chart):
                values = (CHARTS / chart / 'values.yaml').read_text(encoding='utf-8')
                template = (CHARTS / chart / f'templates/01-{chart}.yml').read_text(encoding='utf-8')
                if chart in LEDGER_WRITERS:
                    self.assertRegex(values, r'(?m)^ledgerWriteSecret: ""$')
                    self.assertIn(entry, template)
                else:
                    self.assertNotIn('ledgerWriteSecret', values + template)
                    self.assertNotIn('LEDGER_WRITE_TOKEN', template)


if __name__ == '__main__':
    unittest.main()
