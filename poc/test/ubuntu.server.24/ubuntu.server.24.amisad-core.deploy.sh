#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# GUID: 42c1acfe-069d-43e1-bf01-bd373334f486
# See https://yuruna.link/42010605-00d3
# --- REGION: Initialize environment
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

# --- REGION: amisad_host_fetch
# See https://yuruna.link/4220a755-004d
amisad_host_fetch() {
    local dest="$1" path="$2" attempt
    for attempt in 1 2; do
        if [ "$attempt" -eq 2 ] && [ -x /usr/local/lib/yuruna/yuruna-host-locate.sh ]; then
            /usr/local/lib/yuruna/yuruna-host-locate.sh >/dev/null || return 1
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

# --- REGION: amisad_sha256
# See https://yuruna.link/42010605-00cb
amisad_sha256() { # <file> -> its SHA-256 on stdout, lowercase hex
    local file="$1" out
    out=$(sha256sum "$file" 2>/dev/null) || out=$(shasum -a 256 "$file" 2>/dev/null) || return 1
    printf '%s' "${out%% *}" | tr 'A-F' 'a-f'
}

# amisad_verify_download <file> <expected sha256> <label> <variable name>
# Returns 0 when the bytes match (or when the digest is absent and the override
# is set), 1 otherwise; a refused download is deleted, never left to be reused.
# --- REGION: amisad_verify_download
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
# End download verification

# --- REGION: amisad_fetch_stash_binaries
# See https://yuruna.link/42010605-00d2
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

# Gives the app role 'amisad' a password made for this build and publishes it
# only as the Kubernetes Secret amisad-database (key 'password'), which the
# ledger, seller and resource charts read. The password never lands in a file,
# an argument list, the profile trace or the database's statement log: psql
# reads the ALTER on standard input after the session turns statement logging
# off, kubectl reads the Secret on standard input, and create (unlike apply)
# keeps it out of a last-applied-configuration annotation. 48 hex characters
# fit in DATABASE_URL without escaping. Every run, a transport retry included,
# sets a new password; pods read the Secret when they start, and the readiness
# step restarts them before each scenario. The body is a subshell, so its
# 'set +x' ends with it and the caller's trace resumes on every path.
#
# This is the deploy step's first contact with the cluster and the database,
# and kubectl does not retry a refused TCP dial, so it first waits (up to
# $1 seconds, default 300) for the apiserver's /readyz and for pg_isready, and
# ensures the namespace, all before the ALTER: a cluster or database that is
# still starting changes nothing. Only the Secret's delete and create follow the
# ALTER. If either fails, the role is left on a password no Secret carries and
# the step exits before helm; its next run sets a new password and creates the
# Secret again unconditionally, so a re-run converges.
# --- REGION: amisad_publish_database_password
amisad_publish_database_password() (
    set +x
    local budget="${1:-300}" deadline remaining max_time api_ready=0 api_rc=0 api_error='' db_ready=0 db_rc=0
    local pw encoded err
    local stale='!!   the role password changed, but Secret amisad/amisad-database does not carry it; the next run of this step sets a new password and creates the Secret again'
    deadline=$((SECONDS + budget))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if [ "$api_ready" -eq 0 ]; then
            # Bound the dial itself as well as the retries; 0s would mean no timeout.
            remaining=$((deadline - SECONDS))
            max_time=2
            if [ "$remaining" -ge 1 ] && [ "$remaining" -lt "$max_time" ]; then max_time="$remaining"; fi
            if api_error=$(kubectl --request-timeout="${max_time}s" get --raw='/readyz' 2>&1); then
                api_ready=1
            else
                api_rc=$?
            fi
        fi
        if [ "$db_ready" -eq 0 ]; then
            if sudo -u postgres pg_isready -q; then db_ready=1; else db_rc=$?; fi
        fi
        if [ "$api_ready" -eq 1 ] && [ "$db_ready" -eq 1 ]; then break; fi
        if [ "$SECONDS" -lt "$deadline" ]; then sleep 1; fi
    done
    if [ "$api_ready" -eq 0 ]; then
        echo "!! the apiserver did not answer /readyz within ${budget}s (last kubectl exit: ${api_rc}); the role password was not changed" >&2
        if [ -n "$api_error" ]; then printf '%s\n' "${api_error:0:4096}" >&2; fi
    fi
    if [ "$db_ready" -eq 0 ]; then
        echo "!! PostgreSQL did not accept connections (pg_isready) within ${budget}s (last exit: ${db_rc}); the role password was not changed" >&2
    fi
    if [ "$api_ready" -eq 0 ] || [ "$db_ready" -eq 0 ]; then exit 1; fi
    pw=$(openssl rand -hex 24) || pw=''
    if [[ ! "$pw" =~ ^[0-9a-f]{48}$ ]]; then
        echo "!! no database password: openssl did not return 24 random bytes as 48 hex characters" >&2
        exit 1
    fi
    kubectl get namespace amisad >/dev/null 2>&1 || kubectl create namespace amisad >/dev/null || exit 1
    if ! err=$(printf "SET log_statement = 'none';\nSET log_min_duration_statement = -1;\nSET log_min_error_statement = 'panic';\nALTER ROLE amisad LOGIN PASSWORD '%s';\n" "$pw" \
            | sudo -u postgres psql -v ON_ERROR_STOP=1 -d amisad -f - 2>&1 >/dev/null); then
        echo "!! could not set the amisad role password:" >&2
        printf '%s\n' "${err//"$pw"/<redacted>}" >&2
        exit 1
    fi
    encoded=$(printf '%s' "$pw" | base64 | tr -d '\n')
    if ! kubectl -n amisad delete secret amisad-database --ignore-not-found >/dev/null; then
        echo "!! could not delete the previous Secret amisad/amisad-database" >&2
        printf '%s\n' "$stale" >&2
        exit 1
    fi
    if ! err=$(printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: amisad-database\n  namespace: amisad\ntype: Opaque\ndata:\n  password: %s\n' "$encoded" \
            | kubectl create -f - 2>&1 >/dev/null); then
        err=${err//"$pw"/<redacted>}
        echo "!! could not create Secret amisad/amisad-database:" >&2
        printf '%s\n' "${err//"$encoded"/<redacted>}" >&2
        printf '%s\n' "$stale" >&2
        exit 1
    fi
    echo "  amisad role password set for this build; published only as Secret amisad/amisad-database"
)

# Makes the ledger write token for this build and publishes it only as the
# Kubernetes Secret amisad-ledger-write (key 'token'). The ledger-svc,
# fabric-coordinator, seller-svc and platform-svc charts read it into
# LEDGER_WRITE_TOKEN, and the scenario scripts read it from the Secret for the
# edges' slice-runtime; ledger-svc refuses an append without it. Like the role
# password, it never lands in a file, an argument list or the profile trace:
# kubectl reads the Secret on standard input, and create (unlike apply) keeps
# it out of a last-applied-configuration annotation. It runs right after
# amisad_publish_database_password, whose wait for the apiserver and the
# namespace it relies on. Every run makes a new token. Pods read it when they
# start, and a re-run leaves running pods on the previous one until the
# readiness step restarts them before each scenario. A run that fails exits
# before helm, and the next one makes a new token and creates the Secret again.
# The body is a subshell, so its 'set +x' ends with it.
# --- REGION: amisad_publish_ledger_write_token
amisad_publish_ledger_write_token() (
    set +x
    local token encoded err
    token=$(openssl rand -hex 32) || token=''
    if [[ ! "$token" =~ ^[0-9a-f]{64}$ ]]; then
        echo "!! no ledger write token: openssl did not return 32 random bytes as 64 hex characters" >&2
        exit 1
    fi
    encoded=$(printf '%s' "$token" | base64 | tr -d '\n')
    if ! kubectl -n amisad delete secret amisad-ledger-write --ignore-not-found >/dev/null; then
        echo "!! could not delete the previous Secret amisad/amisad-ledger-write" >&2
        exit 1
    fi
    if ! err=$(printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: amisad-ledger-write\n  namespace: amisad\ntype: Opaque\ndata:\n  token: %s\n' "$encoded" \
            | kubectl create -f - 2>&1 >/dev/null); then
        err=${err//"$token"/<redacted>}
        echo "!! could not create Secret amisad/amisad-ledger-write:" >&2
        printf '%s\n' "${err//"$encoded"/<redacted>}" >&2
        exit 1
    fi
    echo "  ledger write token made for this build; published only as Secret amisad/amisad-ledger-write"
)

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
# See https://yuruna.link/42010605-00d1
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
amisad_publish_database_password
amisad_publish_ledger_write_token
SERVICES="seller-svc resource-svc ads-svc insights-svc platform-svc audit-svc connect-svc fabric-coordinator identity-mock ledger-svc"
# Durable stores: ledger-svc, seller-svc and resource-svc reach the host
# PostgreSQL via the node IP, resolved by the POD at start ($(NODE_IP) is
# kubernetes env expansion from the downward API, NOT shell) - a snapshot
# restore with a new DHCP lease would make a deploy-time IP stale.
# $(AMISAD_DB_PASSWORD) expands the same way, from the Secret
# amisad_publish_database_password created, so neither the Helm release nor the
# Deployment carries the password.
DATABASE_URL='postgres://amisad:$(AMISAD_DB_PASSWORD)@$(NODE_IP):5432/amisad'
# --- REGION: Resolve service endpoints
NODE_IP=$(hostname -I | awk '{print $1}')
# docker.io is unreachable in this lab: distroless base from gcr.io, thin images
# from the prebuilt binaries, imported straight into the cluster's containerd
# (no registry), charts pinned pullPolicy=Never.
IMAGES=()
for svc in $SERVICES; do
    ctx="/tmp/ctx-${svc}"
    rm -rf "$ctx" && mkdir -p "$ctx"
    cp "target/release/${svc}" "$ctx/${svc}"
    printf 'FROM gcr.io/distroless/cc-debian12\nCOPY %s /usr/local/bin/%s\nENV PORT=8080\nEXPOSE 8080\nENTRYPOINT ["/usr/local/bin/%s"]\n' \
        "$svc" "$svc" "$svc" > "$ctx/Dockerfile"
    docker build -t "amisad/${svc}:poc" "$ctx"
    IMAGES+=("amisad/${svc}:poc")
    rm -rf "$ctx"
done
# One archive carries the shared distroless layers once. Import every tag
# before Helm can create a pod whose pullPolicy forbids a registry fallback.
docker save "${IMAGES[@]}" | sudo ctr -n k8s.io images import -
for svc in $SERVICES; do
    EXTRA=()
    case "$svc" in
        ledger-svc|seller-svc|resource-svc) EXTRA+=(--set-string "databaseUrl=${DATABASE_URL}" --set-string databasePasswordSecret=amisad-database) ;;
    esac
    # The ledger and the services that append to it read the write token.
    case "$svc" in
        ledger-svc|seller-svc|fabric-coordinator|platform-svc) EXTRA+=(--set-string ledgerWriteSecret=amisad-ledger-write) ;;
    esac
    helm upgrade --install "$svc" "workloads/services/${svc}" \
        --namespace amisad --create-namespace \
        --set "image=amisad/${svc}:poc" --set "pullPolicy=Never" "${EXTRA[@]}"
done
for svc in $SERVICES; do
    if kubectl -n amisad wait --for=condition=available "deployment/${svc}" --timeout=600s; then
        continue
    fi
    # See https://yuruna.link/42010605-00d0
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
