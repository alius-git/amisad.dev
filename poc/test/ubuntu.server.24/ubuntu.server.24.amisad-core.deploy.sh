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
# /healthz. A run that reaches this script with no published address stops
# immediately rather than fetching executables from a guessed host.
# AMISAD_PROJECT_ARCHIVE_SHA256 and AMISAD_BINARIES_SHA256: the SHA-256 of the
# project tarball and of the binaries tarball this script downloads and then
# extracts. The sequence supplies the first from ${ext:digest.GetArchiveSha256(project)}
# and the second from ${ext:digest.GetPublishedSha256(amisad-binaries)} (the
# digest the host read from the build VM after it uploaded); each download is
# verified before it is extracted, and the binaries run in pods as root, which
# is why that one matters most (see poc/test.md "Verified nested downloads").
# AMISAD_ALLOW_UNVERIFIED=1 waives an absent digest for a hand run.
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

# --- REGION: https://yuruna.link/4220a755-004d
amisad_host_fetch() {
    local dest="$1" path="$2" attempt
    for attempt in 1 2; do
        if [ "$attempt" -eq 2 ] && [ -x /usr/local/lib/yuruna/yuruna-host-locate.sh ]; then
            /usr/local/lib/yuruna/yuruna-host-locate.sh >/dev/null 2>&1 || true
        fi
        if [ -r /etc/yuruna/host.env ]; then
            # shellcheck disable=SC1091
            . /etc/yuruna/host.env
        fi
        if [ -n "${YURUNA_STATUS_SERVICE_IP:-}" ] && [ -n "${YURUNA_STATUS_SERVICE_PORT:-}" ] && \
           wget --no-proxy --timeout=30 --tries=2 -qO "$dest" \
                "http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/${path}"; then
            return 0
        fi
        if [ "$attempt" -eq 1 ]; then
            echo "host fetch of '${path}' failed; refreshing the host coordinates and retrying." >&2
        fi
    done
    return 1
}

# --- amisad download verification: identical copy in compile.sh, deploy.sh and db.sh ---
# fetch-and-execute verified THIS script against a SHA-256 the host typed into
# the launch command. Whatever this script downloads and then extracts, installs
# or feeds to a program is a plain HTTP answer from a LAN service, so it is
# checked here against a SHA-256 carried by the same launch command (the
# sequence's command: text, filled in by ${ext:digest....} on the host) BEFORE
# it is used. The digest is the trust boundary; the transport is not. An empty
# digest refuses the download; AMISAD_ALLOW_UNVERIFIED=1 is the loud override
# for a hand run, and no sequence sets it. test/download_contracts.py holds the
# three copies equal.
amisad_sha256() { # <file> -> its SHA-256 on stdout, lowercase hex
    local file="$1" out
    out=$(sha256sum "$file" 2>/dev/null) || out=$(shasum -a 256 "$file" 2>/dev/null) || return 1
    printf '%s' "${out%% *}" | tr 'A-F' 'a-f'
}

# amisad_verify_download <file> <expected sha256> <label> <variable name>
# Returns 0 when the bytes match (or when the digest is absent and the override
# is set), 1 otherwise; a refused download is deleted, never left to be reused.
amisad_verify_download() {
    local file="$1" expected="${2:-}" label="$3" variable="$4" actual
    if [ -z "$expected" ]; then
        if [ "${AMISAD_ALLOW_UNVERIFIED:-}" = "1" ]; then
            {
                echo ""
                echo "!! UNVERIFIED DOWNLOAD (AMISAD_ALLOW_UNVERIFIED=1)"
                echo "!!   input:  ${label}"
                echo "!!   cause:  ${variable} is empty, so nothing proves these bytes are the ones the host meant"
                echo "!!   effect: the download is used as it arrived. This override exists for hand runs;"
                echo "!!           a sequence never sets it."
                echo ""
            } >&2
            return 0
        fi
        rm -f -- "$file"
        {
            echo ""
            echo "!! DOWNLOAD NOT VERIFIED -- refusing to use ${label}"
            echo "!!   cause:  ${variable} is empty. The sequence puts the expected SHA-256 in this script's"
            echo "!!           launch command; an empty value means the host could not compute it (see the"
            echo "!!           host log for a digest warning) or this script was started by hand."
            echo "!!   by hand: set ${variable}=<sha256>, or AMISAD_ALLOW_UNVERIFIED=1 to use the download"
            echo "!!           unverified (a warning banner is printed)."
            echo ""
        } >&2
        return 1
    fi
    if [ "${#expected}" -ne 64 ] || [ -n "${expected//[0-9A-Fa-f]/}" ]; then
        rm -f -- "$file"
        echo "!! DOWNLOAD NOT VERIFIED -- ${variable} is not a SHA-256 (64 hex characters): ${expected}" >&2
        return 1
    fi
    expected=$(printf '%s' "$expected" | tr 'A-F' 'a-f')
    actual=$(amisad_sha256 "$file") || actual=''
    if [ "$actual" = "$expected" ]; then
        echo "  integrity: sha256 verified (${label})"
        return 0
    fi
    rm -f -- "$file"
    {
        echo ""
        echo "!! INTEGRITY MISMATCH -- refusing to use ${label}"
        echo "!!   expected: ${expected}"
        echo "!!   actual:   ${actual:-<unreadable>}"
        echo "!!   The download was deleted. Either the bytes changed after the host hashed them (the"
        echo "!!   clone moved, or something on the path answered instead of the status service) or"
        echo "!!   the host and this guest disagree about which input this is."
        echo ""
    } >&2
    return 1
}
# --- end amisad download verification ---

# amisad_fetch_stash_binaries <stash base url> <label> <dest file>
# Fetches the newest stash upload under <label> whose SHA-256 is the one the host
# read from the build VM (AMISAD_BINARIES_SHA256), looking back through the ten
# newest: the stash is shared by the whole lab, so another pass or host may have
# uploaded the same label since this pass's build. Returns 3 when the stash lists
# nothing for the label and 7 when no upload verifies. With no digest set, only
# the newest is a candidate and amisad_verify_download decides whether it may be
# used at all.
amisad_fetch_stash_binaries() {
    local stash="$1" label="$2" dest="$3" links link url want have tried=0
    # `|| true`: grep exits 1 when the list is empty (no artifact yet), which
    # under `set -o pipefail` would abort here BEFORE the guard below could
    # explain why.
    links=$(curl -fsS --noproxy '*' \
        "${stash}/api/stashes?username=amisad-poc&filename=${label}&limit=10" \
        | grep -o '"permalink":"[^"]*"' | cut -d'"' -f4 || true)
    if [ -z "$links" ]; then
        echo "no stash artifact found for label amisad-poc/${label} - did amisad-build run first on this architecture?" >&2
        return 3
    fi
    want=$(printf '%s' "${AMISAD_BINARIES_SHA256:-}" | tr 'A-F' 'a-f')
    if [ -n "$want" ] && { [ "${#want}" -ne 64 ] || [ -n "${want//[0-9a-f]/}" ]; }; then
        echo "!! DOWNLOAD NOT VERIFIED -- AMISAD_BINARIES_SHA256 is not a SHA-256 (64 hex characters): ${want}" >&2
        return 7
    fi
    for link in $links; do
        tried=$((tried + 1))
        url="${stash}${link/#\/s\//\/download\/}"
        if ! curl -fsS --noproxy '*' "$url" -o "$dest"; then
            rm -f -- "$dest"
            echo "  stash download of ${url} failed; trying an older upload" >&2
            continue
        fi
        if [ -z "$want" ]; then
            amisad_verify_download "$dest" "" "the stash binaries (${label})" AMISAD_BINARIES_SHA256 || return 7
            return 0
        fi
        have=$(amisad_sha256 "$dest") || have=''
        if [ "$have" = "$want" ]; then
            amisad_verify_download "$dest" "$want" "the stash binaries (${label}, ${link})" AMISAD_BINARIES_SHA256 || return 7
            return 0
        fi
        echo "  stash upload ${link} is not this pass's build (sha256 ${have:-<unreadable>}); trying an older one" >&2
        rm -f -- "$dest"
    done
    {
        echo ""
        echo "!! INTEGRITY MISMATCH -- none of the ${tried} newest stash uploads for ${label} is the build this pass made"
        echo "!!   expected: ${want}"
        echo "!!   The digest was read from the build VM after it uploaded. Either the upload was altered or"
        echo "!!   replaced on the way to or inside the stash, or it never arrived. Nothing was extracted."
        echo ""
    } >&2
    return 7
}

# Downloads land in a private directory (mode 0700), not loose in /tmp: another
# local user could otherwise swap a file between its digest check and its use.
AMISAD_WORK=$(mktemp -d "${TMPDIR:-/tmp}/amisad-fetch.XXXXXX")
trap 'rm -rf -- "$AMISAD_WORK"' EXIT

# Why this endpoint (and not /yuruna-repo/*): see poc/test.md "Repo delivery".
# The previous tree is replaced only after the new archive verified.
amisad_host_fetch "$AMISAD_WORK/project-poc.tar.gz" "yuruna-project-archive.tar.gz?nocache=${RANDOM}"
amisad_verify_download "$AMISAD_WORK/project-poc.tar.gz" "${AMISAD_PROJECT_ARCHIVE_SHA256:-}" \
    "the project archive (yuruna-project-archive.tar.gz)" AMISAD_PROJECT_ARCHIVE_SHA256 || exit 7
rm -rf "$REAL_HOME/amisad.dev"
mkdir -p "$REAL_HOME/amisad.dev"
tar -xzf "$AMISAD_WORK/project-poc.tar.gz" -C "$REAL_HOME/amisad.dev"
rm -f "$AMISAD_WORK/project-poc.tar.gz"

POC="$REAL_HOME/amisad.dev/poc"
cd "$POC"

echo "== download prebuilt binaries from the stash service =="
# --noproxy '*': the stash IP is not in the guest no_proxy list, so an HTTP GET
# would otherwise be sent through squid. The label carries the architecture
# (amisad-<arch>-binaries; see poc/test.md "Stash artifact naming"): match our
# own uname -m and nothing else. /api/stashes returns newest-first, and the
# build this pass made is the newest upload under that label unless another
# pass or host uploaded since; amisad_fetch_stash_binaries picks it by digest.
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
mkdir -p target/release
amisad_fetch_stash_binaries "$STASH" "$LABEL" "$AMISAD_WORK/amisad-binaries.tgz" || exit $?
tar -xzf "$AMISAD_WORK/amisad-binaries.tgz" -C target/release
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
