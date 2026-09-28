# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
"""Run the actual installer in a disposable filesystem with native command fixtures."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class NatsInstaller(unittest.TestCase):
    def test_upgrade_restart_idempotency_and_runtime_version(self):
        source = (ROOT / 'test/ubuntu.server.24/ubuntu.server.24.amisad-core.nats.sh').read_text()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for folder in ['bin', 'usr/local/bin', 'etc/systemd/system', 'tmp']:
                (root / folder).mkdir(parents=True, exist_ok=True)
            for prefix in ['/tmp/', '/usr/local', '/etc/systemd']:
                source = source.replace(prefix, str(root) + prefix)
            script = root / 'installer.sh'; script.write_text(source)
            installed = root / 'usr/local/bin/nats-server'
            installed.write_text('#!/bin/sh\necho "nats-server: v2.14.0"\n'); installed.chmod(0o755)
            commands = {
                'sudo': 'exec "$@"',
                'wget': ':',
                'tar': 'mkdir -p "$FIXTURE/tmp/nats-server-v2.15.0-linux-amd64"\nprintf \'#!/bin/sh\\necho "nats-server: v2.15.0"\\n\' > "$FIXTURE/tmp/nats-server-v2.15.0-linux-amd64/nats-server"\nchmod +x "$FIXTURE/tmp/nats-server-v2.15.0-linux-amd64/nats-server"',
                'uname': 'echo x86_64',
                'systemctl': 'echo "$*" >> "$FIXTURE/actions"\nif [ "$1" = restart ]; then echo 2.15.0 > "$FIXTURE/runtime"; fi',
                'curl': 'case "$*" in *varz*) printf \'{"version":"%s"}\\n\' "$(cat "$FIXTURE/runtime")";; esac',
                'sleep': ':', 'sync': ':',
            }
            for name, body in commands.items():
                path = root / 'bin' / name; path.write_text('#!/bin/sh\n' + body + '\n'); path.chmod(0o755)
            env = {**os.environ, 'FIXTURE': str(root), 'PATH': str(root/'bin') + ':' + os.environ['PATH']}
            def run():
                return subprocess.run(['bash', str(script)], env=env, capture_output=True, text=True)
            result = run(); self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('v2.15.0', subprocess.check_output([str(installed), '--version'], text=True))
            self.assertEqual((root/'actions').read_text().count('restart nats'), 1)
            result = run(); self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((root/'actions').read_text().count('restart nats'), 1)
            (root/'runtime').write_text('2.14.0')
            result = run(); self.assertNotEqual(result.returncode, 0)
            self.assertIn('failed to become healthy', result.stderr)

if __name__ == '__main__': unittest.main()
