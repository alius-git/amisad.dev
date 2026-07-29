#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# AmisAd POC - edge VM setup (shared by amisad-edge-a/b): authorize the
# core->edge demo key for the admin user, and install a boot-time IP reporter
# that posts <hostname>.ip.txt to the host status service so amisad-core can
# locate this edge. The slice runtime itself is delivered per scenario run -
# the edge VM stays stateless.
set -euo pipefail

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~$REAL_USER")

if [ -r /etc/yuruna/host.env ]; then
    # shellcheck disable=SC1091
    . /etc/yuruna/host.env
fi
if [ -z "${YURUNA_STATUS_SERVICE_IP:-}" ] || [ -z "${YURUNA_STATUS_SERVICE_PORT:-}" ]; then
    echo "no host.env - cannot locate the host status service" >&2
    exit 2
fi
BASE="http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}"

echo "== authorize the core->edge demo key =="
mkdir -p "$REAL_HOME/.ssh"
chmod 700 "$REAL_HOME/.ssh"
wget --no-proxy -qO- "${BASE}/handoff/amisad-demo-key.pub" >> "$REAL_HOME/.ssh/authorized_keys"
sort -u "$REAL_HOME/.ssh/authorized_keys" -o "$REAL_HOME/.ssh/authorized_keys"
chmod 600 "$REAL_HOME/.ssh/authorized_keys"
chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.ssh"

echo "== boot-time IP reporter =="
# Posts this VM's IP to the status service's log-upload sink at every boot (and
# now), so vm-core resolves the edge without DNS: GET /log/handoff/<hostname>.ip.txt
sudo tee /usr/local/lib/amisad-ip-report.sh >/dev/null <<'EOS'
#!/bin/bash
set -eu
. /etc/yuruna/host.env
for _ in $(seq 1 30); do
    ip=$(hostname -I | awk '{print $1}')
    if [ -n "$ip" ]; then
        curl -fsS --noproxy '*' -X PUT --data "$ip" \
            "http://${YURUNA_STATUS_SERVICE_IP}:${YURUNA_STATUS_SERVICE_PORT}/log-upload/handoff/$(hostname).ip.txt" && exit 0
    fi
    sleep 5
done
exit 1
EOS
sudo chmod 755 /usr/local/lib/amisad-ip-report.sh

sudo tee /etc/systemd/system/amisad-ip-report.service >/dev/null <<'EOS'
[Unit]
Description=Report this edge VM's IP to the Yuruna status service
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/lib/amisad-ip-report.sh

[Install]
WantedBy=multi-user.target
EOS
sudo systemctl daemon-reload
sudo systemctl enable amisad-ip-report.service
sudo systemctl start amisad-ip-report.service

# Flush before returning: the host snapshots this VM's disk as soon as this
# script exits, without asking the guest to write back, so anything still in
# the page cache is absent from the snapshot. Here that would silently strip
# the authorized_keys entry or the reporter unit -- the edge then boots from
# the restored snapshot never reporting its IP, and the scenarios that
# resolve the edge from that report fail far from this script.
sync

echo "amisad edge setup complete"
