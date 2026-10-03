# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
"""Native build wrapper and deployment packaging contracts."""
import os, subprocess, tempfile, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]

class BuildContracts(unittest.TestCase):

    def test_bazel_wrappers_use_workspace_sources(self):
        for app, tool, manifest in [('web-spa', 'npm', 'package.json'), ('buyer-flutter', 'flutter', 'pubspec.yaml')]:
            with self.subTest(app=app), tempfile.TemporaryDirectory() as directory:
                base = Path(directory)
                work = base / 'workspace'
                appdir = work / 'components/apps' / app
                appdir.mkdir(parents=True)
                (appdir / manifest).write_text('{}')
                runfiles = base / 'runfiles'
                runfiles.mkdir()
                wrapper = runfiles / 'build.sh'
                wrapper.write_text((ROOT / 'components/apps' / app / 'build.sh').read_text())
                tools = base / 'bin'
                tools.mkdir()
                command = tools / tool
                command.write_text(f'#!/bin/sh\n[ -f "{manifest}" ] || exit 42\npwd > build.cwd\n')
                command.chmod(493)
                result = subprocess.run(['bash', '-c', 'export PATH="$PWD/bin:$PATH"; export BUILD_WORKSPACE_DIRECTORY="$PWD/workspace"; exec bash runfiles/build.sh'],
                                        cwd=base, env=os.environ, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                expected = subprocess.check_output(['bash', '-c', 'pwd -P'], cwd=appdir, text=True).strip()
                self.assertEqual((appdir / 'build.cwd').read_text().strip(), expected)

    def test_dockerfiles_use_committed_lock(self):
        paths = list((ROOT / 'components').rglob('Dockerfile'))
        self.assertEqual(len(paths), 11)
        for path in paths:
            text = path.read_text()
            self.assertIn('COPY Cargo.toml Cargo.lock ./', text, str(path))
            self.assertRegex(text, 'RUN cargo build .*--locked')
if __name__ == '__main__':
    unittest.main()
