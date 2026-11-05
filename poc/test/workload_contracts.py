#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# GUID: 420eaac3-a0d5-4866-a81d-a8f95bd07f88
"""Every namespace deletion in a workload file is bounded by a timeout."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TIMEOUT = re.compile(r'\s--timeout=\d+s(\s|"|$)')


def namespace_deletions(text):
    """The (line number, line) pairs that delete a namespace with kubectl."""
    return [(number, line) for number, line in enumerate(text.splitlines(), 1)
            if 'delete namespace' in line]


class NamespaceDeletion(unittest.TestCase):
    def test_every_namespace_deletion_carries_a_timeout(self):
        files = sorted((ROOT / 'config').glob('**/workloads.yml'))
        self.assertTrue(files, 'no workloads.yml under poc/config')
        offenders = []
        for path in files:
            for number, line in namespace_deletions(path.read_text(encoding='utf-8')):
                if not TIMEOUT.search(line):
                    offenders.append(f'{path.relative_to(ROOT)}:{number}: {line.strip()}')
        self.assertEqual([], offenders,
                         'a namespace deletion without --timeout holds the lane on a namespace '
                         'stuck in Terminating:\n' + '\n'.join(offenders))


if __name__ == '__main__':
    unittest.main()
