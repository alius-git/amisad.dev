#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# Shared service diagnostics and lab endpoint discovery.
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
amisad_edge_addr() { # <edge-vm-name>
    local edge="$1" ip
    ip=$(getent hosts "$edge" 2>/dev/null | awk '{print $1}' | grep -m1 '^192\.168\.122\.' || true)
    if [ -n "$ip" ]; then printf '%s' "$ip"; return 0; fi
    wget --no-proxy --timeout=10 --tries=2 -qO- \
        "http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/log/handoff/${edge}.ip.txt" 2>/dev/null || true
}

# --- REGION: amisad_stop_slice_runtime
# The edge VMs are never restored between scenarios, so the previous scenario's
# slice-runtime is still executing when the next one delivers its binary.
# pkill returns as soon as SIGTERM is sent, not when the process is gone; until
# then, overwriting /tmp/slice-runtime fails with ETXTBSY (scp reports it as
# "dest open: Failure") and a fresh instance cannot bind the port. Wait for the
# exit before returning, and escalate to SIGKILL for an instance that outlives
# the SIGTERM allowance.
# Matching is by process NAME (-x), never -f: fetch-and-execute runs the caller
# via `bash -c "<script text>"`, and that text contains "slice-runtime", so a
# `pkill -f` would SIGTERM the scenario itself (exit 143).
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
