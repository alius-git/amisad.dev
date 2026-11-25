#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# GUID: 421b9912-2a9f-4929-8447-e77ebcd3499f
# Shared service diagnostics, lab endpoint discovery and the slice-runtime start.
# curl -sf inside command substitution hides a non-2xx body and leaves callers
# with a parser error at line 1. Preserve the HTTP status and body here.
# --- REGION: amisad_curl
amisad_curl() { # <same args as curl -sf>
    local out status body url='' arg
    for arg in "$@"; do
        case "$arg" in http://*|https://*) url="$arg" ;; esac
    done
    if ! out=$(curl -sS -w '\n%{http_code}' "$@"); then
        printf '\n!! SERVICE CALL FAILED\n!!   url:    %s\n!!   cause:  the request did not complete (curl reported it above)\n\n' \
            "${url:-<no url among the arguments>}" >&2
        return 1
    fi
    status=${out##*$'\n'}
    body=${out%$'\n'*}
    case "$status" in
        2[0-9][0-9]) ;;
        *)
            printf '\n!! SERVICE CALL FAILED\n!!   url:    %s\n!!   status: HTTP %s\n!!   body:   %s\n\n' \
                "${url:-<no url among the arguments>}" "$status" "$(printf '%.400s' "${body:-<empty>}")" >&2
            return 1
            ;;
    esac
    # A 2xx with no body is normal for a POST and fatal for a caller about to
    # parse it. Say so here rather than leave the parser to report a syntax
    # error at line 1 of nothing.
    if [ -z "$body" ]; then
        printf '!! note: %s answered HTTP %s with an empty body\n' "$url" "$status" >&2
    fi
    printf '%s' "$body"
}

# --- REGION: amisad_edge_addr
# Prints the edge's address or nothing and returns 0 either way: the caller
# decides what an unresolved edge means.
# See poc/contracts/service-behavior.md, "Lab edge delivery".
amisad_edge_addr() { # <edge-vm-name>
    local edge="$1" ip attempt
    ip=$(getent hosts "$edge" 2>/dev/null | awk '{print $1}' | grep -m1 '^192\.168\.122\.' || true)
    if [ -n "$ip" ]; then printf '%s' "$ip"; return 0; fi
    for attempt in 1 2; do
        if [ "$attempt" -eq 2 ]; then
            [ -x /usr/local/lib/yuruna/yuruna-host-locate.sh ] || return 0
            /usr/local/lib/yuruna/yuruna-host-locate.sh >/dev/null || return 0
            if [ -r /etc/yuruna/host.env ]; then
                # shellcheck disable=SC1091
                . /etc/yuruna/host.env
            fi
        fi
        ip=$(wget --no-proxy --timeout=10 --tries=2 -qO- \
            "http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/log/handoff/${edge}.ip.txt" 2>/dev/null || true)
        if [ -n "$ip" ]; then printf '%s' "$ip"; return 0; fi
        if [ "$attempt" -eq 1 ]; then
            echo "edge '${edge}' handoff fetch from ${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT} failed; refreshing the host coordinates and retrying." >&2
        fi
    done
    return 0
}

# --- REGION: amisad_stop_slice_runtime
# Stops slice-runtime and waits for it to exit, escalating to SIGKILL, so the
# next binary can overwrite /tmp/slice-runtime and bind the port.
# Matching is by process NAME (-x), never -f: fetch-and-execute runs the caller
# via `bash -c "<script text>"`, and that text contains "slice-runtime", so a
# `pkill -f` would SIGTERM the scenario itself (exit 143).
# See poc/contracts/service-behavior.md, "Lab edge delivery".
amisad_stop_slice_runtime() { # <ssh-target|''> [ssh-option...]   ('' stops it on this VM)
    local target="$1" script
    shift
    script=$(cat <<'STOP'
term_ticks=100
kill_ticks=50
pids=$(pgrep -x slice-runtime || true)
[ -n "$pids" ] || exit 0
pkill -x slice-runtime 2>/dev/null || true
for _ in $(seq 1 "$term_ticks"); do
    pgrep -x slice-runtime >/dev/null || { echo "stopped slice-runtime (pid $pids)"; exit 0; }
    sleep 0.1
done
pkill -KILL -x slice-runtime 2>/dev/null || true
for _ in $(seq 1 "$kill_ticks"); do
    pgrep -x slice-runtime >/dev/null || { echo "stopped slice-runtime (pid $pids, SIGKILL after SIGTERM was outlived)"; exit 0; }
    sleep 0.1
done
echo "slice-runtime (pid $pids) survived SIGTERM and SIGKILL" >&2
exit 1
STOP
)
    if [ -n "$target" ]; then
        # The stop script is composed here and runs on the edge; client-side
        # expansion of "$script" is the point.
        # shellcheck disable=SC2029
        ssh "$@" "$target" "$script"
    else
        bash -c "$script"
    fi
}

# --- REGION: amisad_ledger_write_token
# Writes this build's ledger write token, then a newline, to standard output
# for a pipe into the runtime's start.
# The token stays out of the caller's variables, every argument list and every
# file, so neither the caller's xtrace nor ps shows it, and the runtime
# receives it only in its environment.
# See poc/contracts/service-behavior.md, "Lab edge delivery".
amisad_ledger_write_token() (
    set +x
    set -o pipefail
    if ! kubectl -n amisad get secret amisad-ledger-write -o 'jsonpath={.data.token}' | base64 -d; then
        echo "!! no ledger write token from Secret amisad/amisad-ledger-write; slice-runtime starts without one" >&2
    fi
    echo
)

# --- REGION: amisad_deliver_slice_runtime
# Copies this build's slice-runtime to an edge and starts it there once the
# previous instance has exited; the ledger write token travels only on the
# start session's standard input.
# See poc/contracts/service-behavior.md, "Lab edge delivery".
amisad_deliver_slice_runtime() { # <ssh-target> <ledger-url> <resource-url> <region|''> [address-variable]
    local target="$1" ledger="$2" resource="$3" region="$4" rc reported
    local ssh_opts=(-i "$REAL_HOME/.ssh/amisad-demo-key" -o StrictHostKeyChecking=accept-new)
    amisad_stop_slice_runtime "$target" "${ssh_opts[@]}" \
        || { rc=$?; echo "stopping slice-runtime on ${target} failed" >&2; return "$rc"; }
    scp "${ssh_opts[@]}" target/release/slice-runtime "${target}:/tmp/slice-runtime" \
        || { rc=$?; echo "copying slice-runtime to ${target} failed" >&2; return "$rc"; }
    # The start command is composed here and runs on the edge.
    # shellcheck disable=SC2029
    amisad_ledger_write_token | ssh "${ssh_opts[@]}" "$target" \
        "IFS= read -r LEDGER_WRITE_TOKEN; export LEDGER_WRITE_TOKEN; PORT=8080 REGION=${region} LEDGER_URL=${ledger} RESOURCE_URL=${resource} nohup /tmp/slice-runtime >/tmp/slice-runtime.log 2>&1 & sleep 1; echo edge-started" \
        || { rc=$?; echo "starting slice-runtime on ${target} failed" >&2; return "$rc"; }
    [ -n "${5:-}" ] || return 0
    reported=$(ssh "${ssh_opts[@]}" "$target" "hostname -I | awk '{print \$1}'") \
        || { rc=$?; echo "reading the address of ${target} failed" >&2; return "$rc"; }
    printf -v "$5" '%s' "$reported"
}

# --- REGION: amisad_wait_slice_runtime
# A fresh slice-runtime answers /health within seconds. Allow it 30, then let a
# last probe decide, so a runtime that never comes up fails the caller instead
# of leaving the scenario to assert against nothing.
amisad_wait_slice_runtime() { # <endpoint>
    for _ in $(seq 1 15); do
        if curl -sf "$1/health" >/dev/null 2>&1; then break; fi
        sleep 2
    done
    curl -sf "$1/health" >/dev/null
}

# --- REGION: amisad_start_slice_runtime
# Starts this build's slice-runtime for a single-edge scenario on amisad-edge-a
# (on this VM only when the edge is unresolved and AMISAD_ALLOW_SINGLE_VM=1)
# and leaves its endpoint in SLICE_EP. SLICE_EP is global because the scenario
# registers and calls that endpoint afterwards. Call this as a plain command,
# never inside $( ) or a condition: errexit has to reach every step, and the
# refusal below has to end the scenario with exit 4.
amisad_start_slice_runtime() { # <ledger-url> <resource-url> [region]
    local ledger="$1" resource="$2" region="${3:-}" edge_host edge_ip node_ip
    # Resolve the edge from its boot-time IP report on the status service; an
    # explicit EDGE_HOST env wins.
    if [ -r /etc/yuruna/host.env ]; then
        # shellcheck disable=SC1091
        . /etc/yuruna/host.env
    fi
    edge_host="${EDGE_HOST:-}"
    # See https://yuruna.link/4220a755-0019
    if [ -z "$edge_host" ] && [ -n "${YURUNA_STATUS_SERVICE_IP:-}" ]; then
        edge_ip=$(amisad_edge_addr amisad-edge-a)
        if [ -n "$edge_ip" ]; then edge_host="amisad-edge-a-admin@${edge_ip}"; fi
    fi
    if [ -n "$edge_host" ]; then
        echo "edge: ${edge_host}"
        amisad_deliver_slice_runtime "$edge_host" "$ledger" "$resource" "$region" edge_ip
        SLICE_EP="http://${edge_ip}:8080"
    else
        # See https://yuruna.link/4220a755-004e
        if [ "${AMISAD_ALLOW_SINGLE_VM:-0}" != "1" ]; then
            echo "edge unresolved, and AMISAD_ALLOW_SINGLE_VM is not set: refusing to assert a distributed scenario against a single-VM topology." >&2
            exit 4
        fi
        echo "edge unresolved - slice-runtime on this VM (single-VM degraded fallback)"
        amisad_stop_slice_runtime ''
        amisad_ledger_write_token | {
            IFS= read -r LEDGER_WRITE_TOKEN
            export LEDGER_WRITE_TOKEN
            PORT=8090 REGION="$region" LEDGER_URL="$ledger" RESOURCE_URL="$resource" \
                nohup target/release/slice-runtime >/tmp/slice-runtime.log 2>&1 &
        }
        sleep 1
        node_ip=$(hostname -I | awk '{print $1}')
        SLICE_EP="http://${node_ip}:8090"
    fi
    amisad_wait_slice_runtime "$SLICE_EP"
    echo "slice-runtime at ${SLICE_EP}"
}
