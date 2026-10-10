#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
"""Run the thin-image deployment region with private native command fixtures."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from bash_contract_support import find_usable_bash

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'test/ubuntu.server.24/ubuntu.server.24.amisad-core.deploy.sh'
BASH = find_usable_bash()
SERVICES = ['seller-svc', 'resource-svc', 'ads-svc', 'insights-svc', 'platform-svc',
            'audit-svc', 'connect-svc', 'fabric-coordinator', 'identity-mock', 'ledger-svc']
TAGS = [f'amisad/{service}:poc' for service in SERVICES]


@unittest.skipUnless(BASH, 'A usable native-filesystem Bash is required for guest shell contracts')
class ImageImport(unittest.TestCase):
    def fixture(self, directory):
        root = Path(directory)
        for folder in ('bin', 'target/release', 'contexts'):
            (root / folder).mkdir(parents=True)
        for service in SERVICES:
            (root / 'target/release' / service).write_text(f'fixture binary {service}\n')
        source = SCRIPT.read_text().split('SERVICES="', 1)[1]
        source = 'SERVICES="' + source.split('echo "== expose NodePorts', 1)[0]
        source = source.replace('/tmp/ctx-', root.as_posix() + '/contexts/ctx-')
        (root / 'case.sh').write_bytes(('set -euo pipefail\n' + source).encode())
        commands = {
            'hostname': 'echo 127.0.0.1',
            'sudo': 'exec "$@"',
            'docker': '''echo "docker $*" >> actions
case "$1" in
build)
    tag="$3"; svc="${tag#amisad/}"; svc="${svc%:poc}"; ctx="$4"
    [ "$svc" != "${FAIL_BUILD:-}" ] || exit 21
    cmp "$ctx/$svc" "target/release/$svc" || exit 31
    grep -q '^FROM gcr.io/distroless/cc-debian12$' "$ctx/Dockerfile" || exit 32
    grep -Fq "ENTRYPOINT [\\"/usr/local/bin/$svc\\"]" "$ctx/Dockerfile" || exit 33
    echo "$tag" >> built
    ;;
save)
    shift
    for tag in "$@"; do grep -Fxq "$tag" built || exit 34; done
    printf '%s\\n' "$@"
    [ "${FAIL_SAVE:-0}" = 0 ] || exit 22
    ;;
*) exit 35 ;;
esac''',
            'ctr': '''echo "ctr $*" >> actions
[ "$*" = '-n k8s.io images import -' ] || exit 36
cat > imported
[ "${FAIL_IMPORT:-0}" = 0 ] || exit 23''',
            'helm': '''echo "helm $*" >> actions
[ "$1 $2" = 'upgrade --install' ] || exit 37
while read -r tag; do grep -Fxq "$tag" imported || exit 38; done < built
[ "$(wc -l < imported)" -eq 10 ] || exit 39
[ "$3" != "${FAIL_HELM:-}" ] || exit 24''',
            'kubectl': '''echo "kubectl $*" >> actions
if [ "$3" = wait ] && [[ "$*" == *"deployment/${FAIL_WAIT:-none}"* ]]; then exit 25; fi''',
        }
        for name, body in commands.items():
            path = root / 'bin' / name
            path.write_bytes(('#!/bin/bash\n' + body + '\n').encode())
            path.chmod(0o755)
        return root

    @staticmethod
    def run_fixture(root, **changes):
        result = subprocess.run([BASH, '-c', 'export PATH="$PWD/bin:$PATH"; exec "$BASH" case.sh'],
                                cwd=root, env={**os.environ, **changes}, capture_output=True,
                                text=True, timeout=12)
        actions = (root / 'actions').read_text().splitlines()
        return result, actions

    def test_all_exact_tags_in_one_archive_before_any_helm(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(directory)
            result, actions = self.run_fixture(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((root / 'built').read_text().splitlines(), TAGS)
            self.assertEqual((root / 'imported').read_text().splitlines(), TAGS)
            saves = [a for a in actions if a.startswith('docker save ')]
            self.assertEqual(saves, ['docker save ' + ' '.join(TAGS)])
            imports = [a for a in actions if a.startswith('ctr ')]
            self.assertEqual(imports, ['ctr -n k8s.io images import -'])
            builds = [a for a in actions if a.startswith('docker build ')]
            self.assertEqual(len(builds), 10)
            helms = [a for a in actions if a.startswith('helm ')]
            self.assertEqual(len(helms), 10)
            self.assertLess(actions.index(builds[-1]), actions.index(saves[0]))
            self.assertLess(actions.index(imports[0]), actions.index(helms[0]))
            self.assertLess(actions.index(saves[0]), actions.index(helms[0]))
            for service, helm in zip(SERVICES, helms):
                self.assertIn(f'upgrade --install {service} workloads/services/{service}', helm)
                self.assertIn(f'--set image=amisad/{service}:poc --set pullPolicy=Never', helm)
                self.assertIn('--namespace amisad --create-namespace', helm)
                self.assertEqual('databaseUrl=' in helm, service in ('ledger-svc', 'seller-svc'))
            waits = [a for a in actions if ' wait ' in a]
            self.assertEqual(waits, [f'kubectl -n amisad wait --for=condition=available deployment/{service} --timeout=600s'
                                     for service in SERVICES])
            self.assertEqual(list((root / 'contexts').iterdir()), [])

    def test_each_build_failure_prevents_export_import_and_deploy(self):
        for service in SERVICES:
            with self.subTest(service=service), tempfile.TemporaryDirectory() as directory:
                root = self.fixture(directory)
                result, actions = self.run_fixture(root, FAIL_BUILD=service)
                self.assertEqual(result.returncode, 21, result.stderr)
                self.assertFalse(any(a.startswith(('docker save ', 'ctr ', 'helm ', 'kubectl '))
                                     for a in actions))

    def test_save_failure_cannot_be_hidden_by_successful_import(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(directory)
            result, actions = self.run_fixture(root, FAIL_SAVE='1')
            self.assertEqual(result.returncode, 22, result.stderr)
            self.assertTrue(any(a.startswith('ctr ') for a in actions))
            self.assertFalse(any(a.startswith(('helm ', 'kubectl ')) for a in actions))

    def test_import_failure_prevents_every_deployment(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(directory)
            result, actions = self.run_fixture(root, FAIL_IMPORT='1')
            self.assertEqual(result.returncode, 23, result.stderr)
            self.assertFalse(any(a.startswith(('helm ', 'kubectl ')) for a in actions))

    def test_helm_failure_still_stops_before_availability_success(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.fixture(directory)
            result, actions = self.run_fixture(root, FAIL_HELM='seller-svc')
            self.assertEqual(result.returncode, 24, result.stderr)
            self.assertEqual(len([a for a in actions if a.startswith('helm ')]), 1)
            self.assertFalse(any(' wait ' in a for a in actions))

    def test_availability_failure_retains_cluster_diagnostics(self):
        for service in ('seller-svc', 'ledger-svc'):
            with self.subTest(service=service), tempfile.TemporaryDirectory() as directory:
                root = self.fixture(directory)
                result, actions = self.run_fixture(root, FAIL_WAIT=service)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn(f'{service} never became available', result.stderr)
                for diagnostic in ('get pods -o wide', f'describe deployment/{service}',
                                   f'logs deployment/{service}', 'get events --sort-by=.lastTimestamp'):
                    self.assertTrue(any(diagnostic in a for a in actions), diagnostic)


if __name__ == '__main__':
    unittest.main()
