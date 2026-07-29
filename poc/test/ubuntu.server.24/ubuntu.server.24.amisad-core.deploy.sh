#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# AmisAd POC - amisad-core deploy step: download the prebuilt binaries from the
# stash service (produced by amisad-build), build thin distroless images from
# them, and deploy the ten services to the in-VM Kubernetes cluster. This VM has
# the runtime stack (Docker+containerd+kubeadm K8s+Helm+PostgreSQL+NATS from the
# amisad-core-k8s baseline) plus python3 - but NO Rust toolchain and no source build.
# STASH_HOST: the stash service to pull binaries from. REQUIRED, and with no
# default -- the sequence supplies it from ${ext:stash-service.ResolveHost(...)},
# which returns the address the cycle's warm-up resolved and confirmed answers
# /healthz. A run that reaches this script with nothing to have published an
# address stops immediately rather than fetching executables from a guessed host.
set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

echo "== runtime deps (python3 for the scenario asserts; curl for the stash) =="
export DEBIAN_FRONTEND=noninteractive
sudo apt-get install -y python3 curl >/dev/null

echo "== obtain project tree (helm charts + deploy layout; NOT the binaries) =="
if [ -r /etc/yuruna/host.env ]; then
    # shellcheck disable=SC1091
    . /etc/yuruna/host.env
fi
if [ -z "${YURUNA_STATUS_SERVICE_IP:-}" ] || [ -z "${YURUNA_STATUS_SERVICE_PORT:-}" ]; then
    echo "no host.env - cannot locate the host status service" >&2
    exit 2
fi
rm -rf "$REAL_HOME/amisad.dev"
mkdir -p "$REAL_HOME/amisad.dev"
# /yuruna-project-archive.tar.gz is the framework's project-tarball endpoint --
# a fresh tar of <RepoRoot>/project, with the project tree (poc/, test/, ...) at
# the TOP LEVEL, which is exactly what the extract below expects.
# NOT /yuruna-repo/project-poc.tar.gz: /yuruna-repo/* serves the working tree
# file-by-file and no such file exists, so that path 404s. wget then exits 8 and
# `set -euo pipefail` aborts the whole deploy before it starts.
wget --no-proxy -qO /tmp/project-poc.tar.gz \
    "http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/yuruna-project-archive.tar.gz?nocache=${RANDOM}"
tar -xzf /tmp/project-poc.tar.gz -C "$REAL_HOME/amisad.dev"
rm -f /tmp/project-poc.tar.gz

POC="$REAL_HOME/amisad.dev/poc"
cd "$POC"

echo "== download prebuilt binaries from the stash service =="
# --noproxy '*': the stash IP is not in the guest no_proxy list, so an HTTP GET
# would otherwise be sent through squid. The label carries the architecture
# (amisad-<arch>-binaries): the stash is shared by the whole lab, so a plain
# "newest wins" query hands this guest whatever machine built last, and a
# foreign build's binaries cannot execute here at all. Match our own uname -m
# and nothing else. /api/stashes returns newest-first, so limit=1 is the
# latest build FOR THIS ARCHITECTURE.
# No default address: the caller supplies one it already verified, and guessing
# here would pull executables from whatever answers on someone's network.
if [ -z "${STASH_HOST:-}" ]; then
    echo "STASH_HOST is empty - the sequence supplies it from \${ext:stash-service.ResolveHost(...)} and the cycle's warm-up publishes the address it verified. Nowhere to fetch the binaries from; aborting." >&2
    exit 3
fi
STASH="http://${STASH_HOST}"
ARCH=$(uname -m)
LABEL="amisad-${ARCH}-binaries"
curl -fsS --noproxy '*' --connect-timeout 20 "${STASH}/healthz" >/dev/null || {
    echo "STASH UNREACHABLE at ${STASH} - is yuruna-stash-service running and reachable from this guest?" >&2
    exit 3
}
# `|| true`: grep exits 1 when the list is empty (no artifact yet), which under
# `set -o pipefail` would abort here BEFORE the guard below could explain why.
PERMALINK=$(curl -fsS --noproxy '*' \
    "${STASH}/api/stashes?username=amisad-poc&filename=${LABEL}&limit=1" \
    | grep -o '"permalink":"[^"]*"' | head -n1 | cut -d'"' -f4 || true)
if [ -z "$PERMALINK" ]; then
    echo "no stash artifact found for label amisad-poc/${LABEL} - did amisad-build run first on a ${ARCH} host?" >&2
    exit 3
fi
DOWNLOAD="${STASH}${PERMALINK/#\/s\//\/download\/}"
mkdir -p target/release
curl -fsS --noproxy '*' "$DOWNLOAD" -o /tmp/amisad-binaries.tgz
tar -xzf /tmp/amisad-binaries.tgz -C target/release
chmod +x target/release/*
echo "binaries retrieved from stash:"
ls -l target/release/

# Confirm the binaries can actually run here before spending the deploy on
# them. A mismatch is otherwise invisible until every pod crashes with "exec
# format error" and the rollout wait burns its full timeout, which reports a
# stuck deployment and says nothing about the cause. Read the ELF header
# directly: `file` is not installed on this guest, python3 is (installed above).
python3 - "$ARCH" target/release/seller-svc <<'PY'
import sys, struct
want, path = sys.argv[1], sys.argv[2]
# e_machine sits at offset 18 of the ELF header, 2 bytes little-endian.
with open(path, 'rb') as fh:
    head = fh.read(20)
if head[:4] != b'\x7fELF':
    sys.exit(f"stash artifact is not an ELF binary: {path}")
machine = struct.unpack_from('<H', head, 18)[0]
names = {0x3E: 'x86_64', 0xB7: 'aarch64', 0x28: 'arm', 0xF3: 'riscv64'}
got = names.get(machine, hex(machine))
if got != want:
    sys.exit(
        f"stash artifact is {got} but this guest is {want}: the binaries cannot "
        f"execute here. The stash is shared by the whole lab -- an artifact built "
        f"on another architecture was published under this label.")
print(f"binaries match this guest ({got})")
PY

echo "== build thin images + deploy 10 services =="
sudo chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.kube" 2>/dev/null || true
SERVICES="seller-svc resource-svc ads-svc insights-svc platform-svc audit-svc connect-svc fabric-coordinator identity-mock ledger-svc"
# Durable stores: ledger-svc and seller-svc reach the host PostgreSQL via the
# node IP, resolved by the POD at start ($(NODE_IP) is kubernetes env
# expansion from the downward API, NOT shell) - a snapshot restore with a new
# DHCP lease would make a deploy-time IP stale. Role/password: db step.
DATABASE_URL='postgres://amisad:amisadpoc2026@$(NODE_IP):5432/amisad'
NODE_IP=$(hostname -I | awk '{print $1}')
# docker.io is unreachable in this lab: distroless base from gcr.io, thin images
# from the prebuilt binaries, imported straight into the cluster's containerd
# (no registry), charts pinned pullPolicy=Never.
for svc in $SERVICES; do
    ctx="/tmp/ctx-${svc}"
    rm -rf "$ctx" && mkdir -p "$ctx"
    cp "target/release/${svc}" "$ctx/${svc}"
    printf 'FROM gcr.io/distroless/cc-debian12\nCOPY %s /usr/local/bin/%s\nENV PORT=8080\nEXPOSE 8080\nENTRYPOINT ["/usr/local/bin/%s"]\n' \
        "$svc" "$svc" "$svc" > "$ctx/Dockerfile"
    docker build -t "amisad/${svc}:poc" "$ctx"
    docker save "amisad/${svc}:poc" | sudo ctr -n k8s.io images import -
    rm -rf "$ctx"
    EXTRA=()
    case "$svc" in
        ledger-svc|seller-svc) EXTRA=(--set-string "databaseUrl=${DATABASE_URL}") ;;
    esac
    helm upgrade --install "$svc" "workloads/services/${svc}" \
        --namespace amisad --create-namespace \
        --set "image=amisad/${svc}:poc" --set "pullPolicy=Never" "${EXTRA[@]}"
done
for svc in $SERVICES; do
    if kubectl -n amisad wait --for=condition=available "deployment/${svc}" --timeout=600s; then
        continue
    fi
    # `wait` reports only that the condition never arrived, so on its own a
    # failure here says a deployment is stuck and nothing about why -- and the
    # VM is torn down before anyone can look. Dump what the cluster already
    # knows: the pod phase, the scheduling/pull events, and whatever the
    # container wrote before dying are each enough to name the cause on their
    # own. Every probe is best-effort; the exit below is the real result.
    echo "== ${svc} never became available; cluster state ==" >&2
    kubectl -n amisad get pods -o wide >&2 || true
    kubectl -n amisad describe "deployment/${svc}" 2>&1 | tail -25 >&2 || true
    echo "-- pod detail (waiting/terminated reason) --" >&2
    kubectl -n amisad get pods -l "app=${svc}" \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{range .status.containerStatuses[*]}{.state}{.lastState}{end}{"\n"}{end}' >&2 || true
    echo "-- container log --" >&2
    kubectl -n amisad logs "deployment/${svc}" --all-containers --tail=40 >&2 || true
    kubectl -n amisad logs "deployment/${svc}" --all-containers --previous --tail=40 >&2 || true
    echo "-- recent namespace events --" >&2
    kubectl -n amisad get events --sort-by=.lastTimestamp 2>&1 | tail -25 >&2 || true
    exit 1
done

echo "== expose NodePorts for host/edge access =="
declare -A NP=( [fabric-coordinator]=30080 [ledger-svc]=30081 [resource-svc]=30082 [seller-svc]=30083 [identity-mock]=30084 [insights-svc]=30085 [platform-svc]=30086 [ads-svc]=30087 [connect-svc]=30088 [audit-svc]=30089 )
for svc in "${!NP[@]}"; do
    kubectl -n amisad patch svc "$svc" -p \
        "{\"spec\":{\"type\":\"NodePort\",\"ports\":[{\"port\":8080,\"targetPort\":8080,\"nodePort\":${NP[$svc]}}]}}"
done

echo "amisad-core DEPLOY PASSED"
