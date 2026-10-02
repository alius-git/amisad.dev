# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
"""Verified nested downloads: the helper every guest script carries, the order
in which each script uses it, and the launch commands that supply the digests.

fetch-and-execute verifies the script it launches against a digest the host
types into the command. What that script then downloads and extracts, installs
or feeds to a program is a plain HTTP answer, so each such input is checked
against a SHA-256 carried by the same launch command BEFORE it is used.

Shell behavior is exercised with bash on relative paths only (cwd is the
fixture directory), so the same file runs under Git Bash and on Linux.
"""
import hashlib
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GUEST = ROOT / 'test/ubuntu.server.24'
SEQUENCES = ROOT / 'test'
COMPILE = GUEST / 'ubuntu.server.24.amisad-build.compile.sh'
DEPLOY = GUEST / 'ubuntu.server.24.amisad-core.deploy.sh'
DB = GUEST / 'ubuntu.server.24.amisad-core.db.sh'
TOOLS = GUEST / 'ubuntu.server.24.amisad-build.tools.sh'
NATS = GUEST / 'ubuntu.server.24.amisad-core.nats.sh'
SCRIPTS = [COMPILE, DEPLOY, DB]
BEGIN = '# --- amisad download verification: identical copy in compile.sh, deploy.sh and db.sh ---'
END = '# --- end amisad download verification ---'
PINNED_BEGIN = '# --- amisad pinned download check: identical copy in tools.sh and nats.sh ---'
PINNED_END = '# --- end amisad pinned download check ---'


def text_of(path):
    return path.read_text(encoding='utf-8')


def helper_block(path):
    text = text_of(path)
    start = text.index(BEGIN)
    stop = text.index(END, start) + len(END)
    return text[start:stop]


def pinned_block(path):
    text = text_of(path)
    start = text.index(PINNED_BEGIN)
    stop = text.index(PINNED_END, start) + len(PINNED_END)
    return text[start:stop]


def function_text(path, name):
    """One top-level shell function, from its name to the closing brace in column 0."""
    match = re.search(r'(?ms)^' + re.escape(name) + r'\(\) \{.*?^\}', text_of(path))
    if not match:
        raise AssertionError(f'{name} is not defined in {path.name}')
    return match.group(0)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


class Contract(unittest.TestCase):
    """Assertions that name the missing thing instead of dumping a whole script."""

    def contains(self, needle, text, message):
        self.assertTrue(needle in text, message)

    def lacks(self, needle, text, message):
        self.assertFalse(needle in text, message)

    def matches(self, pattern, text, message, flags=0):
        self.assertIsNotNone(re.search(pattern, text, flags), message)

    def never_matches(self, pattern, text, message, flags=0):
        self.assertIsNone(re.search(pattern, text, flags), message)


def run_bash(script, cwd, extra_env=None, drop_env=()):
    env = {key: value for key, value in os.environ.items() if key not in drop_env}
    env.update(extra_env or {})
    return subprocess.run(['bash', '-c', script], cwd=cwd, env=env, capture_output=True, text=True, timeout=60)


class VerificationHelper(Contract):
    def test_every_script_carries_the_same_helper(self):
        blocks = {path.name: helper_block(path) for path in SCRIPTS}
        self.assertEqual(len(set(blocks.values())), 1, 'the verification helper drifted between scripts')
        self.contains('amisad_verify_download()', blocks[COMPILE.name], 'the helper block lost its verifier')

    def verify(self, expected, content=b'payload', override=False):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'f.bin').write_bytes(content)
            script = (
                'set -u\n' + helper_block(COMPILE) + '\n'
                'amisad_verify_download f.bin "$EXPECTED" "the thing" VAR_NAME; echo "rc=$?"\n'
                '[ -e f.bin ] && echo kept || echo deleted\n')
            result = run_bash(script, directory, {'EXPECTED': expected, **({'AMISAD_ALLOW_UNVERIFIED': '1'} if override else {})},
                              drop_env=() if override else ('AMISAD_ALLOW_UNVERIFIED',))
            return result.stdout, result.stderr

    def test_matching_digest_keeps_the_file(self):
        out, _ = self.verify(sha256(b'payload'))
        self.assertIn('rc=0', out)
        self.assertIn('kept', out)
        self.assertIn('sha256 verified (the thing)', out)

    def test_uppercase_digest_is_accepted(self):
        out, _ = self.verify(sha256(b'payload').upper())
        self.assertIn('rc=0', out)

    def test_wrong_digest_refuses_deletes_and_names_both_values(self):
        out, err = self.verify(sha256(b'something else'))
        self.assertIn('rc=1', out)
        self.assertIn('deleted', out)
        self.assertIn('INTEGRITY MISMATCH', err)
        self.assertIn(sha256(b'something else'), err)
        self.assertIn(sha256(b'payload'), err)

    def test_absent_digest_fails_closed_and_names_the_variable(self):
        out, err = self.verify('')
        self.assertIn('rc=1', out)
        self.assertIn('deleted', out)
        self.assertIn('VAR_NAME is empty', err)
        self.assertIn('AMISAD_ALLOW_UNVERIFIED=1', err)

    def test_override_accepts_an_absent_digest_with_a_banner(self):
        out, err = self.verify('', override=True)
        self.assertIn('rc=0', out)
        self.assertIn('kept', out)
        self.assertIn('UNVERIFIED DOWNLOAD', err)
        self.assertIn('the thing', err)

    def test_override_does_not_excuse_a_wrong_digest(self):
        out, err = self.verify(sha256(b'something else'), override=True)
        self.assertIn('rc=1', out)
        self.assertIn('deleted', out)
        self.assertIn('INTEGRITY MISMATCH', err)

    def test_malformed_digest_is_refused_even_with_the_override(self):
        for expected in ('zz', 'a' * 63, 'g' * 64):
            with self.subTest(expected=expected):
                out, err = self.verify(expected, override=True)
                self.assertIn('rc=1', out)
                self.assertIn('deleted', out)
                self.assertIn('not a SHA-256', err)


class StashBinaries(Contract):
    """amisad_fetch_stash_binaries against a stash that lists uploads newest first."""

    LIST = '{"ok":true,"stashes":[%s]}' % ','.join('{"permalink":"/s/h1/2026/10/01/%s"}' % name for name in ('aaa', 'bbb'))

    def fetch(self, artifacts, expected, listing=None, override=False):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'artifacts').mkdir()
            for name, data in artifacts.items():
                Path(directory, 'artifacts', name).write_bytes(data)
            Path(directory, 'list.json').write_text(self.LIST if listing is None else listing)
            script = (
                'set -u\n' + helper_block(DEPLOY) + '\n' + function_text(DEPLOY, 'amisad_fetch_stash_binaries') + '\n'
                # A stand-in for the stash: the listing for /api/stashes, an upload for /download/...
                'curl() {\n'
                '    local url="" dest=""\n'
                '    while [ $# -gt 0 ]; do\n'
                '        case "$1" in -o) dest="$2"; shift 2 ;; http*) url="$1"; shift ;; *) shift ;; esac\n'
                '    done\n'
                '    case "$url" in\n'
                '        */api/stashes*) cat list.json ;;\n'
                '        */download/*) [ -f "artifacts/${url##*/}" ] || return 22; cp "artifacts/${url##*/}" "$dest" ;;\n'
                '        *) return 22 ;;\n'
                '    esac\n'
                '}\n'
                'amisad_fetch_stash_binaries http://stash.invalid amisad-x86_64-binaries got.tgz; echo "rc=$?"\n'
                '[ -e got.tgz ] && { printf "got="; cat got.tgz; echo; } || echo "got=<none>"\n')
            result = run_bash(script, directory, {'AMISAD_BINARIES_SHA256': expected, **({'AMISAD_ALLOW_UNVERIFIED': '1'} if override else {})},
                              drop_env=() if override else ('AMISAD_ALLOW_UNVERIFIED',))
            return result.stdout, result.stderr

    def test_takes_the_newest_upload_when_it_is_this_passes_build(self):
        out, _ = self.fetch({'aaa': b'new build', 'bbb': b'old build'}, sha256(b'new build'))
        self.assertIn('rc=0', out)
        self.assertIn('got=new build', out)

    def test_looks_past_an_upload_another_pass_made_since(self):
        out, err = self.fetch({'aaa': b"someone else's build", 'bbb': b'this pass'}, sha256(b'this pass'))
        self.assertIn('rc=0', out)
        self.assertIn('got=this pass', out)
        self.assertIn('is not this pass', err)

    def test_looks_past_an_upload_that_cannot_be_downloaded(self):
        out, _ = self.fetch({'bbb': b'this pass'}, sha256(b'this pass'))
        self.assertIn('rc=0', out)
        self.assertIn('got=this pass', out)

    def test_refuses_and_leaves_nothing_when_no_upload_matches(self):
        out, err = self.fetch({'aaa': b'forged', 'bbb': b'also forged'}, sha256(b'this pass'))
        self.assertIn('rc=7', out)
        self.assertIn('got=<none>', out)
        self.assertIn('INTEGRITY MISMATCH', err)
        self.assertIn(sha256(b'this pass'), err)

    def test_without_a_digest_it_refuses_and_leaves_nothing(self):
        out, err = self.fetch({'aaa': b'new build', 'bbb': b'old build'}, '')
        self.assertIn('rc=7', out)
        self.assertIn('got=<none>', out)
        self.assertIn('AMISAD_BINARIES_SHA256 is empty', err)

    def test_override_takes_only_the_newest_and_says_so(self):
        out, err = self.fetch({'aaa': b'new build', 'bbb': b'old build'}, '', override=True)
        self.assertIn('rc=0', out)
        self.assertIn('got=new build', out)
        self.assertIn('UNVERIFIED DOWNLOAD', err)

    def test_malformed_digest_is_refused(self):
        out, err = self.fetch({'aaa': b'new build'}, 'not-a-digest')
        self.assertIn('rc=7', out)
        self.assertIn('got=<none>', out)
        self.assertIn('not a SHA-256', err)

    def test_an_empty_listing_is_reported_as_missing_not_as_a_mismatch(self):
        out, err = self.fetch({}, sha256(b'x'), listing='{"ok":true,"stashes":[]}')
        self.assertIn('rc=3', out)
        self.assertIn('no stash artifact found', err)


class PinnedUpstreamDownloads(Contract):
    """rustup-init, bazelisk and the NATS server are executed or installed as root,
    so each is checked against a publisher's SHA-256 pinned in the (verified) script."""

    def test_both_scripts_carry_the_same_check(self):
        self.assertEqual(pinned_block(TOOLS), pinned_block(NATS), 'the pinned-download check drifted between scripts')

    def run_check(self, content, pinned):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'f.bin').write_bytes(content)
            script = ('set -u\n' + pinned_block(TOOLS) + '\n'
                      'amisad_verify_pinned f.bin "$PINNED" "the thing"; echo "rc=$?"\n'
                      '[ -e f.bin ] && echo kept || echo deleted\n')
            result = run_bash(script, directory, {'PINNED': pinned})
            return result.stdout, result.stderr

    def test_a_matching_download_is_kept(self):
        out, _ = self.run_check(b'release', sha256(b'release'))
        self.assertIn('rc=0', out)
        self.assertIn('kept', out)

    def test_a_different_download_is_refused_and_deleted(self):
        out, err = self.run_check(b'release', sha256(b'another release'))
        self.assertIn('rc=1', out)
        self.assertIn('deleted', out)
        self.assertIn('INTEGRITY MISMATCH', err)
        self.assertIn(sha256(b'release'), err)

    def test_an_empty_pin_never_matches(self):
        out, _ = self.run_check(b'', '')
        self.assertIn('rc=1', out)

    def test_pins_are_publisher_digests_of_named_releases(self):
        tools = text_of(TOOLS)
        self.matches(r'(?m)^RUSTUP_VERSION=\d+\.\d+\.\d+$', tools, 'rustup-init is not pinned to a version')
        self.matches(r'(?m)^BAZELISK_VERSION=v\d+\.\d+\.\d+$', tools, 'bazelisk is not pinned to a version')
        for name in ('RUSTUP_SHA256_X86_64', 'RUSTUP_SHA256_AARCH64', 'BAZELISK_SHA256_AMD64', 'BAZELISK_SHA256_ARM64'):
            self.matches(rf'(?m)^{name}=[0-9a-f]{{64}}$', tools, f'{name} is not a pinned SHA-256')
        for arch in ('AMD64', 'ARM64'):
            self.matches(rf'(?m)^NATS_SHA256_{arch}=[0-9a-f]{{64}}$', text_of(NATS), f'NATS_SHA256_{arch} is not a pinned SHA-256')

    def test_nothing_is_piped_into_a_shell_or_taken_from_latest(self):
        for script in (TOOLS, NATS):
            code = re.sub(r'(?m)^\s*#.*$', '', text_of(script))
            self.never_matches(r'\|\s*(?:sudo\s+)?(?:ba)?sh\b', code, f'{script.name} pipes a download into a shell')
            self.lacks('sh.rustup.rs', code, f'{script.name} still runs the rustup shell installer')
            self.lacks('releases/latest', code, f'{script.name} installs whatever release is latest')

    def test_every_install_checks_before_it_runs_or_installs(self):
        tools = text_of(TOOLS)
        self.assertLess(tools.index('amisad_verify_pinned "$work/rustup-init"'), tools.index('"$work/rustup-init" -y'))
        self.assertLess(tools.index('amisad_verify_pinned "$BAZELISK_DIR/bazelisk"'),
                        tools.index('sudo install -m 0755 "$BAZELISK_DIR/bazelisk"'))
        nats = text_of(NATS)
        self.assertLess(nats.index('amisad_verify_pinned "$NATS_WORK/nats-server.tar.gz"'),
                        nats.index('tar -xzf "$NATS_WORK/nats-server.tar.gz"'))

    def install(self, function, setup, payload, after=''):
        """Run one install function of tools.sh with a stand-in curl that 'downloads' payload.

        Returns (stdout, stderr, names left in the temp directory, what a fake rustup-init recorded).
        """
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, 'payload').write_bytes(payload)
            Path(directory, 'tmp').mkdir()
            script = ('set -u\n' + pinned_block(TOOLS) + '\n' + setup + '\n' + function_text(TOOLS, function) + '\n'
                      'uname() { echo x86_64; }\n'
                      'curl() { local out=""; while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac; done; cp payload "$out"; }\n'
                      + function + '; echo "rc=$?"\n' + after)
            result = run_bash(script, directory, {'TMPDIR': './tmp'})
            left = [p.name for p in Path(directory, 'tmp').iterdir()]
            ran = Path(directory, 'ran.txt').read_text().strip() if Path(directory, 'ran.txt').exists() else None
            return result.stdout, result.stderr, left, ran

    # A stand-in rustup-init: records how it was called.
    FAKE_RUSTUP = b'#!/bin/sh\necho "$@" > ran.txt\n'

    def test_rustup_init_runs_only_when_it_is_the_pinned_release(self):
        digest = sha256(self.FAKE_RUSTUP)
        setup = f'RUSTUP_VERSION=1.29.1; RUSTUP_SHA256_X86_64={digest}; RUSTUP_SHA256_AARCH64={digest}'
        out, _, left, ran = self.install('amisad_install_rustup', setup, self.FAKE_RUSTUP)
        self.assertIn('rc=0', out)
        self.assertEqual(ran, '-y --default-toolchain 1.96.1')
        self.assertEqual(left, [], 'the private download directory was left behind')

        other = sha256(b'some other release')
        setup = f'RUSTUP_VERSION=1.29.1; RUSTUP_SHA256_X86_64={other}; RUSTUP_SHA256_AARCH64={other}'
        out, err, left, ran = self.install('amisad_install_rustup', setup, self.FAKE_RUSTUP)
        self.assertIn('rc=1', out)
        self.assertIsNone(ran, 'rustup-init ran although it did not verify')
        self.assertIn('INTEGRITY MISMATCH', err)
        self.assertEqual(left, [])

    def test_bazelisk_is_left_for_the_installer_only_when_it_verifies(self):
        downloaded = b'bazelisk binary'
        for pinned, expected_rc, expected_file in ((downloaded, 'rc=0', 'present'), (b'another release', 'rc=1', 'absent')):
            with self.subTest(expected=expected_rc):
                digest = sha256(pinned)
                setup = (f'BARCH=amd64; BAZELISK_VERSION=v1.29.0; BAZELISK_SHA256_AMD64={digest}; BAZELISK_SHA256_ARM64={digest}\n'
                         'BAZELISK_DIR=$(mktemp -d ./tmp/bazelisk.XXXXXX)')
                out, _, _, _ = self.install('amisad_install_bazelisk', setup, downloaded,
                                            after='[ -e "$BAZELISK_DIR/bazelisk" ] && echo present || echo absent\n')
                self.assertIn(expected_rc, out)
                self.assertIn(expected_file, out)


class ScriptsVerifyBeforeUse(Contract):
    def test_every_extraction_and_database_load_reads_a_verified_download(self):
        pattern = re.compile(r'(?:tar -x[a-z]* "([^"]+)"|psql[^\n]*-f - < "([^"]+)")')
        seen = 0
        for script in SCRIPTS:
            text = text_of(script)
            for match in pattern.finditer(text):
                target = match.group(1) or match.group(2)
                seen += 1
                before = text[:match.start()]
                self.assertTrue(
                    target.startswith('$AMISAD_WORK/') or target == '$SCHEMA',
                    f'{script.name} reads {target} from outside its private download directory')
                verified = (f'amisad_verify_download "{target}"' in before
                            or f'"{target}" || exit' in before and 'amisad_fetch_stash_binaries' in before)
                self.assertTrue(verified, f'{script.name} uses {target} before verifying it')
        self.assertEqual(seen, 4, 'expected the two archives, the binaries and the schema')

    def test_no_download_lands_loose_in_tmp(self):
        for script in SCRIPTS:
            text = text_of(script)
            self.never_matches(r'tar -x[a-z]* "?/tmp/', text, f'{script.name} extracts from /tmp')
            self.never_matches(r'(?:-f|-qO|-o)\s+"?/tmp/(?:project-poc|amisad-binaries|amisad-schema)', text,
                               f'{script.name} downloads loose into /tmp')

    def test_every_script_fails_with_the_integrity_exit_code(self):
        for script in SCRIPTS:
            self.contains('|| exit', text_of(script), f'{script.name} never exits on a refused download')
            self.contains('exit 7', text_of(script), f'{script.name} does not use the integrity exit code')

    def test_the_project_tree_is_replaced_only_after_its_archive_verified(self):
        for script in (COMPILE, DEPLOY):
            text = text_of(script)
            self.assertLess(text.index('amisad_verify_download "$AMISAD_WORK/project-poc.tar.gz"'),
                            text.index('rm -rf "$REAL_HOME/amisad.dev"'), script.name)

    def test_the_schema_is_verified_before_postgresql_is_installed(self):
        text = text_of(DB)
        self.assertLess(text.index('amisad_verify_download "$SCHEMA"'), text.index('apt-get install -y postgresql'),
                        'the schema is verified after PostgreSQL is installed')

    def test_the_grants_block_the_database_contract_reads_is_still_extractable(self):
        self.assertEqual(text_of(DB).count("<<'SQL'"), 1)

    def test_scripts_stay_ascii(self):
        for path in SCRIPTS + [GUEST / 'ubuntu.server.24.amisad-core.users.sh', GUEST / 'ubuntu.server.24.amisad-edge.setup.sh']:
            path.read_bytes().decode('ascii')


class LaunchCommandsCarryTheDigests(Contract):
    @staticmethod
    def commands(sequence):
        """Every command: value in a sequence file."""
        return re.findall(r'^\s*command:\s*"(.*)"\s*$', text_of(SEQUENCES / sequence), flags=re.M)

    def command_for(self, sequence, script_suffix):
        matches = [c for c in self.commands(sequence) if script_suffix in c]
        self.assertEqual(len(matches), 1, f'{sequence}: expected one command running {script_suffix}')
        return matches[0]

    def test_compile_carries_the_archive_digest_and_publishes_the_binaries_digest(self):
        sequence = 'workload.guest.ubuntu.server.24.amisad-build.compile.yml'
        command = self.command_for(sequence, 'amisad-build.compile.sh')
        self.assertIn("AMISAD_PROJECT_ARCHIVE_SHA256='${ext:digest.GetArchiveSha256(project)}'", command)
        text = text_of(SEQUENCES / sequence)
        self.assertRegex(text, r'(?s)action: callExtension\s+method: digest\.PublishGuestFileSha256\s+args:\s+name: amisad-binaries\b')
        self.assertIn('path: "/tmp/amisad-*-binaries.tgz"', text)
        # The compile script leaves the tarball where the host reads it.
        self.assertIn('TARBALL="/tmp/amisad-${ARCH}-binaries.tgz"', text_of(COMPILE))
        # The publish step comes after the step that builds and uploads.
        self.assertLess(text.index('amisad-build.compile.sh'), text.index('digest.PublishGuestFileSha256'))

    def test_deploy_carries_both_digests(self):
        command = self.command_for('workload.guest.ubuntu.server.24.amisad-core.deploy.yml', 'amisad-core.deploy.sh')
        self.contains("AMISAD_PROJECT_ARCHIVE_SHA256='${ext:digest.GetArchiveSha256(project)}'", command,
                      'the deploy command does not carry the archive digest')
        self.contains("AMISAD_BINARIES_SHA256='${ext:digest.GetPublishedSha256(amisad-binaries)}'", command,
                      'the deploy command does not carry the binaries digest')

    def test_db_step_carries_the_schema_digest_of_a_file_that_exists(self):
        command = self.command_for('workload.guest.ubuntu.server.24.amisad-core.k8s.yml', 'amisad-core.db.sh')
        self.contains("AMISAD_SCHEMA_SHA256='${ext:digest.GetFileSha256(project/poc/db/schema.sql)}'", command,
                      'the db command does not carry the schema digest')
        # Relative to the checkout root, where this repository is cloned as project/.
        self.assertTrue((ROOT / 'db/schema.sql').is_file())

    def test_every_digest_variable_a_script_reads_is_set_by_every_command_that_runs_it(self):
        sequences = sorted(SEQUENCES.glob('workload.guest.*.yml'))
        for script in SCRIPTS:
            variables = set(re.findall(r'\$\{(AMISAD_[A-Z_]*SHA256):-\}', text_of(script)))
            self.assertTrue(variables, script.name)
            runners = 0
            for sequence in sequences:
                for command in self.commands(sequence.name):
                    if script.name in command:
                        runners += 1
                        for variable in variables:
                            self.contains(variable + "='${ext:digest.", command, f'{sequence.name} runs {script.name} without {variable}')
            self.assertGreaterEqual(runners, 1, f'no sequence runs {script.name}')

    def test_no_sequence_waives_verification(self):
        for sequence in SEQUENCES.glob('*.yml'):
            self.lacks('AMISAD_ALLOW_UNVERIFIED', text_of(sequence), f'{sequence.name} waives verification')

    def test_ext_calls_use_methods_the_digest_area_exports(self):
        methods = {'GetFileSha256', 'GetArchiveSha256', 'GetPublishedSha256'}
        for sequence in SEQUENCES.glob('workload.guest.*.yml'):
            for method in re.findall(r'\$\{ext:digest\.([A-Za-z0-9]+)\(', text_of(sequence)):
                self.assertTrue(method in methods, f'{sequence.name} calls digest.{method}, which the area does not export')


if __name__ == '__main__':
    unittest.main()
