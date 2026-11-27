# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# GUID: 429ddbf7-1b5a-49fa-8b97-36b1d602e2e3
"""Run both demo modes with a disposable local proxy upstream and framework."""
import contextlib
import hashlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
BASELINE = os.environ.get("AMISAD_DEMO_BASELINE") == "1"
BINARY = Path(os.environ.get("AMISAD_BIN_DIR", ROOT / "poc/target/debug")) / (
    "amisad-demo-host.exe" if os.name == "nt" else "amisad-demo-host"
)


class Upstream(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/interrupted"):
            self.send_response(200)
            self.send_header("Content-Length", "40")
            self.end_headers()
            self.wfile.write(b"partial")
            self.close_connection = True
        else:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(self.path.encode())

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        self.send_response(410)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        return


@contextlib.contextmanager
def upstream():
    for port in range(30080, 30090):
        try:
            server = ThreadingHTTPServer(("127.0.0.1", port), Upstream)
            break
        except OSError:
            continue
    else:
        raise RuntimeError("No free demo core service port")
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server.server_port
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def request(port, method, path, headers=None, body=None):
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=12)
    try:
        conn.request(method, path, body, headers or {})
        reply = conn.getresponse()
        return reply.status, {key.lower(): value for key, value in reply.getheaders()}, reply.read()
    finally:
        conn.close()


@contextlib.contextmanager
def demo(mode, port=None, core=None, framework=None, launcher=False, share=False, vault_log=None, artifact_log=None):
    port = port or free_port()
    with tempfile.TemporaryDirectory() as dirname:
        if framework is None:
            framework = Path(dirname) / "framework"
            marker = framework / "test/modules/Test.HostContract.psm1"
            marker.parent.mkdir(parents=True)
            marker.write_text("")
        use_launcher = launcher or BASELINE
        if use_launcher:
            command = [
                "pwsh", "-NoProfile", "-File", str(ROOT / f"poc/demo/{mode}/serve-{mode}.ps1"),
                "-Port", str(port), "-YurunaRoot", str(framework), "-SkipFirewall",
            ]
        else:
            command = [str(BINARY), mode, "--port", str(port),
                       "--yuruna-root", str(framework)]
        if core:
            command += ["-CoreIp" if use_launcher else "--core-ip", core]
        env = os.environ.copy()
        env.pop("YURUNA_LOG_DIR", None)
        env.pop("YURUNA_CONFIG_PATH", None)
        if use_launcher:
            env["AMISAD_BIN_DIR"] = str(BINARY.parent if launcher else Path(dirname) / "no-native-artifacts")
        if share:
            command += ["-SharePersonaPasswords" if use_launcher else "--share-persona-passwords"]
        if vault_log is not None:
            env["AMISAD_TEST_VAULT_LOG"] = str(vault_log)
        if artifact_log is not None:
            env["AMISAD_TEST_ARTIFACT_LOG"] = str(artifact_log)
            env["AMISAD_TEST_ARTIFACT"] = str(BINARY)
        logfile = Path(dirname) / "demo.log"
        with logfile.open("wb") as log:
            process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=log,
                                       stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 12
            while time.monotonic() < deadline and process.poll() is None:
                try:
                    if request(port, "GET", "/")[0] == 200:
                        break
                except OSError:
                    time.sleep(0.1)
            else:
                raise RuntimeError(logfile.read_text(errors="replace"))
            process.demo_log = logfile
            yield port, process
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=4)


def create_host_fixture(framework):
    driver = framework / "test/modules/Test.HostContract.psm1"
    driver.parent.mkdir(parents=True)
    driver.write_text("""
function Get-HostType { 'host.fixture' }
function Initialize-YurunaHost { param($RepoRoot, $HostType) }
function Get-VMIp {
    param([string]$VMName)
    switch ($VMName) {
        'amisad-core' { '127.0.0.10' }
        'amisad-edge-a' { '127.0.0.11' }
        'amisad-edge-b' { '127.0.0.12' }
    }
}
function Get-VMState {
    param([string]$VMName)
    switch ($VMName) {
        'amisad-core' { 'running' }
        'amisad-edge-a' { 'stopped' }
        'amisad-edge-b' { 'absent' }
    }
}
Export-ModuleMember -Function Get-HostType, Initialize-YurunaHost, Get-VMIp, Get-VMState
""")
    vault = framework / "test/extension/authentication/default.psm1"
    vault.parent.mkdir(parents=True)
    vault.write_text("""
function Get-Password {
    param([string]$Username)
    [IO.File]::AppendAllText($env:AMISAD_TEST_VAULT_LOG, "$Username`n")
    return "fixture-$Username"
}
Export-ModuleMember -Function Get-Password
""")


class DemoContracts(unittest.TestCase):
    def test_host_and_post_origin_rejections_precede_routing(self):
        for mode in ("by-act", "data-view"):
            with self.subTest(mode=mode), demo(mode) as (port, _):
                headers = {"Host": f"unrelated.invalid:{port}", "Origin": "https://unrelated.invalid"}
                self.assertEqual(request(port, "POST", "/api/personas", headers)[0], 421)
                self.assertEqual(request(port, "POST", "/api/topology", {"Origin": "https://unrelated.invalid"})[0], 403)
                self.assertEqual(request(port, "POST", "/api/topology", {"Origin": f"http://127.0.0.1:{port}"})[0], 200)

    def test_persona_withholding_topology_and_subjects(self):
        for mode in ("by-act", "data-view"):
            with self.subTest(mode=mode), demo(mode, core="127.0.0.1") as (port, _):
                status, headers, result = request(port, "GET", "/api/personas")
                self.assertEqual(status, 200)
                self.assertEqual(headers["cache-control"], "no-store")
                personas = json.loads(result)
                self.assertEqual(len(personas), 11)
                self.assertEqual(personas[0]["username"], "maya")
                self.assertIn("vault error", personas[0]["password"])
                headers = {"Host": f"{socket.gethostname()}:{port}"}
                status, _, result = request(port, "GET", "/api/personas", headers)
                self.assertEqual(status, 200)
                self.assertTrue(all(item["password"] == "<withheld: remote viewer>" for item in json.loads(result)))
                self.assertEqual(json.loads(request(port, "GET", "/api/topology")[2]), {
                    "core": "127.0.0.1", "edgeA": "", "edgeB": "",
                })
                if mode == "data-view":
                    status, _, result = request(port, "GET", "/api/subjects")
                    self.assertEqual(status, 200)
                    self.assertEqual(json.loads(result), {
                        name: hashlib.sha256(f"{name}|person|subject".encode()).hexdigest()[:16]
                        for name in ("maya", "pat")
                    })

    def test_static_files_and_traversal(self):
        for mode in ("by-act", "data-view"):
            with self.subTest(mode=mode), demo(mode) as (port, _):
                status, headers, page = request(port, "GET", "/")
                self.assertEqual(status, 200)
                self.assertEqual(headers["content-type"], "text/html; charset=utf-8")
                self.assertIn(b"AmisAd", page)
                self.assertEqual(request(port, "GET", "/art/icon.svg")[0], 200)
                self.assertEqual(request(port, "GET", "/common/../by-act/README.md")[0], 404)
                self.assertEqual(request(port, "GET", "/art/%2e%2e/%2e%2e/Cargo.toml")[0], 404)
                self.assertEqual(request(port, "GET", "/data")[0], 200 if mode == "data-view" else 404)

    def test_core_allowlist_edge_unresolved_and_upstream_payload(self):
        for mode in ("by-act", "data-view"):
            with self.subTest(mode=mode), upstream() as core_port, demo(mode, core="127.0.0.1") as (port, _):
                for unauthorized in (22, 5432, 8222, 30079, 30090, 300810):
                    self.assertEqual(request(port, "GET", f"/api/core/{unauthorized}/version")[0], 404)
                self.assertEqual(request(port, "GET", "/api/edge-b/health")[0], 503)
                status, _, body = request(port, "GET", f"/api/core/{core_port}/query?fixture=1")
                self.assertEqual((status, body), (200, b"/query?fixture=1"))
                probe = b'{"fixture":"apostrophe\'"}'
                status, headers, body = request(port, "POST", f"/api/core/{core_port}/post", body=probe)
                self.assertEqual((status, body), (410, probe))
                self.assertEqual(headers["cache-control"], "no-store")
                self.assertEqual(headers["content-type"], "application/json")

    def test_interrupted_upstream_returns_502_then_recovers(self):
        for mode in ("by-act", "data-view"):
            with self.subTest(mode=mode), upstream() as core_port, demo(mode, core="127.0.0.1") as (port, _):
                self.assertEqual(request(port, "GET", f"/api/core/{core_port}/interrupted")[0], 502)
                self.assertEqual(request(port, "GET", f"/api/core/{core_port}/healthy")[0], 200)

    def test_normal_launcher_can_use_a_configured_dns_name_for_the_core(self):
        for mode in ("by-act", "data-view"):
            with self.subTest(mode=mode), upstream() as core_port, demo(mode, core="localhost", launcher=True) as (port, _):
                self.assertEqual(request(port, "GET", f"/api/core/{core_port}/resolved")[2], b"/resolved")

    def test_journal_creation_reset_cursor_and_invalid_methods(self):
        with demo("data-view") as (port, _):
            self.assertEqual(request(port, "GET", "/api/journal/reset")[0], 405)
            self.assertEqual(request(port, "POST", "/api/journal", body=b"not JSON")[0], 400)
            status, _, body = request(port, "POST", "/api/journal", body=b'{"kind":"click","seq":99,"ts":99}')
            self.assertEqual(status, 201)
            event = json.loads(body)
            self.assertEqual(event["seq"], 1)
            self.assertGreater(event["ts"], 99)
            current = json.loads(request(port, "GET", "/api/journal?since=1")[2])
            self.assertEqual((current["latest"], current["events"]), (1, []))
            status, _, body = request(port, "POST", "/api/journal/reset")
            self.assertEqual((status, json.loads(body)["seq"]), (200, 2))
            last = json.loads(request(port, "GET", "/api/journal?since=0")[2])
            self.assertEqual((last["latest"], [e["kind"] for e in last["events"]]), (2, ["reset"]))

    def test_existing_launchers_select_rust_and_read_vault_only_for_an_authorized_request(self):
        for mode in ("by-act", "data-view"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                framework = root / "fixture-framework"
                create_host_fixture(framework)
                vault_log = root / "vault-reads"
                with demo(mode, framework=framework, launcher=True, vault_log=vault_log) as (port, process):
                    env_host = {"Host": f"{socket.gethostname()}:{port}"}
                    status, _, result = request(port, "GET", "/api/personas", env_host)
                    self.assertEqual(status, 200)
                    self.assertTrue(all(item["password"] == "<withheld: remote viewer>" for item in json.loads(result)))
                    self.assertFalse(vault_log.exists(), "a restricted request must never read the vault")
                    status, _, result = request(port, "GET", "/api/personas")
                    self.assertEqual(status, 200)
                    personas = json.loads(result)
                    self.assertEqual(len(personas), 11)
                    self.assertTrue(all(item["password"] == f"fixture-{item['username']}" for item in personas))
                    self.assertEqual(len(vault_log.read_text().splitlines()), 11)
                    self.assertEqual(request(port, "GET", "/api/personas")[0], 200)
                    self.assertEqual(len(vault_log.read_text().splitlines()), 11, "the host provider caches the vault")
                    self.assertEqual(json.loads(request(port, "GET", "/api/topology")[2]), {
                        "core": "127.0.0.10", "edgeA": "127.0.0.11", "edgeB": "127.0.0.12",
                    })
                    if mode == "data-view":
                        states = json.loads(request(port, "GET", "/api/vms")[2])
                        self.assertEqual([vm["state"] for vm in states], ["running", "stopped", "absent"])
                    logs = process.demo_log.read_text()
                    self.assertIn(f"{mode} listening on", logs)
                    self.assertNotIn("fixture-maya", logs)
                    self.assertNotIn("AMISAD-HOST ", logs)

    def test_explicit_share_flag_and_exit_of_the_launcher_preserve_native_lifecycle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            framework = root / "fixture-framework"
            create_host_fixture(framework)
            vault_log = root / "vault-reads"
            with demo("data-view", framework=framework, launcher=True, share=True, vault_log=vault_log) as (port, process):
                env_host = {"Host": f"{socket.gethostname()}:{port}"}
                status, _, result = request(port, "GET", "/api/personas", env_host)
                self.assertEqual(status, 200)
                self.assertEqual(json.loads(result)[0]["password"], "fixture-maya")
                process.kill()
                process.wait(timeout=4)
            # The child loses the launcher's pipe on an ungraceful exit. The
            # port must be reusable without having to find or kill a child PID.
            deadline = time.monotonic() + 5
            while True:
                with socket.socket() as client:
                    if client.connect_ex(("127.0.0.1", port)) != 0:
                        break
                if time.monotonic() >= deadline:
                    self.fail("the native listener survived the launcher's exit")
                time.sleep(0.05)
            with demo("data-view", port=port) as (rebound, _):
                self.assertEqual(request(rebound, "GET", "/")[0], 200)

    def test_normal_launcher_verifies_the_pinned_project_revision(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            framework = root / "fixture-framework"
            create_host_fixture(framework)
            artifact_log = root / "artifact-request"
            (framework / "test/test.config.yml").write_text("")
            (framework / "test/builder.json").write_text(json.dumps({"consumer": {
                "baseUrl": "http://builder.invalid/",
                "trustedPublicKeyFile": "fixture-public-key.pem",
                "amisad": {"candidateId": "a" * 64, "manifestSha256": "b" * 64},
            }}))
            (framework / "test/modules/Test.Config.psm1").write_text("""
function Read-TestConfig {
    param([string]$Path)
    return @{ vmStart = @{ buildServiceConfigFile = 'builder.json' } }
}
Export-ModuleMember -Function Read-TestConfig
""")
            verifier = framework / "test/extension/build-service/default.psm1"
            verifier.parent.mkdir(parents=True)
            verifier.write_text("""
function Receive-BuildServiceArtifact {
    [CmdletBinding(SupportsShouldProcess)]
    param($BaseUrl, $CandidateId, $ManifestSha256, $TrustedKeyFile, $RequiredRevision, $Binary, $InstallRoot)
    [IO.File]::WriteAllText($env:AMISAD_TEST_ARTIFACT_LOG, (ConvertTo-Json -InputObject $PSBoundParameters))
    return $env:AMISAD_TEST_ARTIFACT
}
Export-ModuleMember -Function Receive-BuildServiceArtifact
""")
            with demo("by-act", framework=framework, launcher=True, artifact_log=artifact_log) as (port, process):
                self.assertEqual(request(port, "GET", "/")[0], 200)
                verified = json.loads(artifact_log.read_text())
                revision = subprocess.check_output(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).strip()
                self.assertEqual(verified["RequiredRevision"], revision)
                self.assertEqual(verified["CandidateId"], "a" * 64)
                self.assertEqual(verified["ManifestSha256"], "b" * 64)
                self.assertEqual(verified["TrustedKeyFile"], str(framework / "test/fixture-public-key.pem"))
                self.assertEqual(verified["Binary"], "amisad-demo-host")
                self.assertIn("by-act listening on", process.demo_log.read_text())

    def test_restart_after_an_interrupted_journal_upload(self):
        with demo("data-view") as (port, process):
            conn = socket.create_connection(("127.0.0.1", port), timeout=3)
            with conn:
                conn.sendall((f"POST /api/journal HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\n"
                              "Content-Length: 10000\r\n\r\n{\"kind\":\"partial").encode())
                process.kill()
                process.wait(timeout=4)
        with demo("data-view", port=port):
            self.assertEqual(json.loads(request(port, "GET", "/api/journal")[2]), {
                "latest": 0, "events": [],
            })


if __name__ == "__main__":
    unittest.main()
