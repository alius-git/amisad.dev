# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# GUID: 4288c23b-ac80-47d8-b84e-150d5c3e5056
"""Run the actual installer in a disposable filesystem with native command fixtures."""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'test/fixtures/core-nats-before-rust.sh.fixture'
ACTIVE_SCRIPT = ROOT / 'test/ubuntu.server.24/ubuntu.server.24.amisad-core.nats.sh'
TARBALL = b'fixture nats-server release tarball'


class NatsInstaller(unittest.TestCase):
    def fixture(self, directory, pin_the_fixture_tarball, entry=SCRIPT):
        """A disposable root with command fixtures; returns (root, script, env)."""
        root = Path(directory)
        posix = root.as_posix()
        for folder in ['bin', 'usr/local/bin', 'etc/systemd/system', 'etc/yuruna', 'tmp']:
            (root / folder).mkdir(parents=True, exist_ok=True)
        source = entry.read_text()
        # Paths are spliced in POSIX form so the same file runs under Git Bash
        # (where a backslash in a script is an escape) and on Linux.
        for prefix in ['/tmp/', '/usr/local', '/etc/systemd', '/etc/yuruna']:
            source = source.replace(prefix, posix + prefix)
        if pin_the_fixture_tarball:
            # Exercise the real comparison: pin the fixture's digest in place of the
            # release's, so the verifier hashes with the real sha256sum.
            digest = hashlib.sha256(TARBALL).hexdigest()
            source = re.sub(r'(NATS_SHA256_(?:AMD64|ARM64)=)[0-9a-f]{64}', r'\g<1>' + digest, source)
        script = root / 'installer.sh'
        script.write_bytes(source.replace('\r\n', '\n').encode())
        installed = root / 'usr/local/bin/nats-server'
        installed.write_text('#!/bin/sh\necho "nats-server: v2.14.0"\n')
        installed.chmod(0o755)
        commands = {
            'sudo': 'exec "$@"',
            # wget -qO <file> <url>: leaves the fixture tarball where the installer asked for it.
            'wget': 'while [ $# -gt 0 ]; do case "$1" in -qO) out="$2"; shift 2 ;; *) shift ;; esac; done\n'
                    'printf %s "$TARBALL" > "$out"\necho wget >> "$FIXTURE/actions"',
            # tar -xzf <file> -C <dir>: unpacks a fake release into <dir>.
            'tar': 'dir=.\nwhile [ $# -gt 0 ]; do case "$1" in -C) dir="$2"; shift 2 ;; *) shift ;; esac; done\n'
                   'echo tar >> "$FIXTURE/actions"\n'
                   'mkdir -p "$dir/nats-server-v2.15.1-linux-amd64"\n'
                   'printf \'#!/bin/sh\\necho "nats-server: v2.15.1"\\n\' > "$dir/nats-server-v2.15.1-linux-amd64/nats-server"\n'
                   'chmod +x "$dir/nats-server-v2.15.1-linux-amd64/nats-server"',
            'uname': 'echo x86_64',
            'systemctl': 'echo "$*" >> "$FIXTURE/actions"\nif [ "$1" = restart ]; then echo 2.15.1 > "$FIXTURE/runtime"; fi',
            'curl': 'case "$*" in *varz*) printf \'{"version":"%s"}\\n\' "$(cat "$FIXTURE/runtime")";; esac',
            'sleep': ':', 'sync': ':',
            # The health probe pipes JSON through python3; run it with the interpreter
            # running this test, so a host whose python3 is only a launcher still works.
            'python3': 'exec "$PYTHON" "$@"',
        }
        for name, body in commands.items():
            path = root / 'bin' / name
            path.write_bytes(('#!/bin/sh\n' + body + '\n').encode())
            path.chmod(0o755)
        env = {**os.environ, 'FIXTURE': posix, 'TMPDIR': posix + '/tmp', 'TARBALL': TARBALL.decode(),
               'PYTHON': Path(sys.executable).as_posix()}
        return root, script, env

    @staticmethod
    def run_installer(root, env):
        # Prepend fixtures after Bash converts the host PATH into its native format.
        return subprocess.run(['bash', '-c', 'export PATH="$PWD/bin:$PATH"; exec bash ./installer.sh'],
                              cwd=root, env=env, capture_output=True, text=True)

    def test_upgrade_restart_idempotency_and_runtime_version(self):
        with tempfile.TemporaryDirectory() as directory:
            root, script, env = self.fixture(directory, pin_the_fixture_tarball=True)
            installed = root / 'usr/local/bin/nats-server'

            def run():
                return self.run_installer(root, env)
            result = run(); self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('v2.15.1', subprocess.check_output(['bash', str(installed), '--version'], text=True))
            self.assertEqual((root/'actions').read_text().count('restart nats'), 1)
            result = run(); self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((root/'actions').read_text().count('restart nats'), 1)
            (root/'runtime').write_text('2.14.0')
            result = run(); self.assertNotEqual(result.returncode, 0)
            self.assertIn('failed to become healthy', result.stderr)

    def test_verifies_the_download_before_extracting_and_cleans_up(self):
        with tempfile.TemporaryDirectory() as directory:
            root, script, env = self.fixture(directory, pin_the_fixture_tarball=True)
            result = self.run_installer(root, env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('sha256 verified', result.stdout)
            # The private download directory is gone once the install finished.
            self.assertEqual([p.name for p in (root / 'tmp').iterdir() if p.name.startswith('amisad-nats')], [])

    def test_signed_candidate_receives_the_architecture_pin(self):
        with tempfile.TemporaryDirectory() as directory:
            root, _, env = self.fixture(directory, pin_the_fixture_tarball=False, entry=ACTIVE_SCRIPT)
            (root / 'etc/yuruna/amisad-artifacts.json').write_text('{}\n')
            installer = root / 'usr/local/lib/yuruna/install-rust-artifacts'
            installer.parent.mkdir(parents=True)
            artifact = installer.parent / 'amisad-artifacts' / ('a' * 64)
            artifact.mkdir(parents=True)
            installer.write_text('#!/bin/sh\n'
                                 'printf "%s\\n" "$*" > "$FIXTURE/verification"\n'
                                 'printf "%s\\n" "' + artifact.as_posix() + '"\n')
            installer.chmod(0o755)
            native = artifact / 'amisad-provision'
            native.write_text('#!/bin/sh\n'
                              'if [ "$1" = --help ]; then echo nats-install; exit 0; fi\n'
                              'printf "%s\\n" "$*" > "$FIXTURE/native"\n')
            native.chmod(0o755)
            result = self.run_installer(root, env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((root / 'verification').read_text().rstrip().endswith('amisad-provision framework-revision'))
            self.assertEqual((root / 'native').read_text(),
                             'nats-install v2.15.1 bf5edc7b1ce98e885c368cb43a886eb148dc5d0551d99f3cf6141fb5e1954c70\n')
            self.assertFalse((root / 'actions').exists(), 'the verified command must own the setup')
            (root / 'bin/uname').write_text('#!/bin/sh\necho aarch64\n')
            result = self.run_installer(root, env)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((root / 'native').read_text(),
                             'nats-install v2.15.1 e2fbab4cad7d3c76e3052eb959570393c9d73ba756b70bf8e9eea61e9ae6d49c\n')

    def test_current_entry_refuses_missing_enrollment_before_any_service_effect(self):
        with tempfile.TemporaryDirectory() as directory:
            root, _, env = self.fixture(directory, pin_the_fixture_tarball=False, entry=ACTIVE_SCRIPT)
            result = self.run_installer(root, env)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertIn('Invalid enrolled AmisAd artifact plan', result.stderr)
            self.assertFalse((root / 'actions').exists())

    def test_refuses_a_download_that_is_not_the_pinned_release(self):
        with tempfile.TemporaryDirectory() as directory:
            # The real pins stay in place, so the fixture tarball cannot match them.
            root, script, env = self.fixture(directory, pin_the_fixture_tarball=False)
            installed = root / 'usr/local/bin/nats-server'
            before = installed.read_text()
            result = self.run_installer(root, env)
            self.assertEqual(result.returncode, 7, result.stderr)
            self.assertIn('INTEGRITY MISMATCH', result.stderr)
            self.assertIn(hashlib.sha256(TARBALL).hexdigest(), result.stderr)
            actions = (root / 'actions').read_text() if (root / 'actions').exists() else ''
            self.assertNotIn('tar', actions.split(), 'the tarball was extracted although it did not verify')
            self.assertNotIn('restart', actions, 'the service was restarted although nothing was installed')
            self.assertEqual(installed.read_text(), before, 'the installed binary changed')
            self.assertEqual([p.name for p in (root / 'tmp').iterdir() if p.name.startswith('amisad-nats')], [])

    def test_pins_are_the_publishers_values(self):
        text = ACTIVE_SCRIPT.read_text()
        self.assertRegex(text, r'NATS_VERSION=v\d+\.\d+\.\d+\n')
        for arch in ('AMD64', 'ARM64'):
            self.assertRegex(text, rf'NATS_SHA256_{arch}=[0-9a-f]{{64}}\n')
        self.assertNotIn('latest', re.sub(r'#.*', '', text), 'the install must name a pinned release')
        pins = r'(?m)^NATS_(?:VERSION|SHA256_(?:AMD64|ARM64))=.*$'
        self.assertEqual(re.findall(pins, text), re.findall(pins, SCRIPT.read_text()))


if __name__ == '__main__':
    unittest.main()
