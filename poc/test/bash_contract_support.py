#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
"""Find a bounded Bash that can execute fixtures on the native filesystem."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


def bash_candidates():
    candidates = []
    seen = set()
    for directory in os.get_exec_path():
        candidate = shutil.which('bash', path=directory)
        if candidate is None:
            continue
        normalized = candidate.replace('\\', '/').lower()
        # Store aliases can open UI, and WSL launchers use a different filesystem.
        if '/windowsapps/' in normalized or (sys.platform == 'win32' and
                normalized.endswith(('/system32/bash.exe', '/sysnative/bash.exe'))):
            continue
        candidate = str(Path(candidate).resolve())
        key = os.path.normcase(candidate)
        if key not in seen:
            seen.add(key)
            candidates.append(candidate)
    return candidates


def find_usable_bash(timeout=2):
    deadline = time.monotonic() + timeout
    for candidate in bash_candidates():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        with tempfile.TemporaryDirectory(prefix='amisad Bash path with spaces ') as directory:
            root = Path(directory)
            (root / 'bin').mkdir()
            source = root / 'input with spaces.txt'
            source.write_bytes(b'amisad-bash-fixture\n')
            shim = root / 'bin' / 'fixture-command'
            shim.write_bytes(b'#!/bin/bash\ncat "$AMISAD_BASH_PROBE_FILE"\n')
            shim.chmod(0o755)
            command = '''set -euo pipefail
[ -n "${BASH_VERSION:-}" ]
export PATH="$PWD/bin:$PATH"
for tool in awk cat cmp cp grep mkdir rm wc; do command -v "$tool" >/dev/null; done
mkdir -p "work with spaces"
cp "$AMISAD_BASH_PROBE_FILE" "work with spaces/copy"
cmp "$AMISAD_BASH_PROBE_FILE" "work with spaces/copy"
grep -Fxq amisad-bash-fixture "work with spaces/copy"
[ "$(wc -l < "work with spaces/copy")" -eq 1 ]
[ "$(awk '{print $1}' "work with spaces/copy")" = amisad-bash-fixture ]
[ "$(fixture-command)" = amisad-bash-fixture ]
rm "work with spaces/copy"
printf 'amisad-bash-fixture\\n' > verified
'''
            try:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                # The proof file is authoritative; descendants cannot hold an
                # output pipe open after the immediate launcher's deadline.
                result = subprocess.run([candidate, '--noprofile', '--norc', '-c', command],
                                        cwd=root, env={**os.environ, 'AMISAD_BASH_PROBE_FILE': source.as_posix()},
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=remaining)
            except (OSError, subprocess.TimeoutExpired):
                continue
            proof = root / 'verified'
            if result.returncode == 0 and proof.is_file() and proof.read_bytes() == b'amisad-bash-fixture\n':
                return candidate
    return None
