#!/bin/bash
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
# AmisAd POC - edge VM setup (shared by amisad-edge-a/b): install a boot-time IP
# reporter that posts <hostname>.ip.txt to the host status service so
# amisad-core can locate this edge. The slice runtime itself is delivered per
# scenario run - the edge VM stays stateless.
#
# The core->edge demo key is NOT installed here. vm-core generates that keypair
# (after the edges are built) and keeps the private half; the host then
# authorizes the PUBLIC half in this VM's authorized_keys over the harness SSH
# channel (test/AmisAd.Lab.psm1 Sync-AmisAdDemoKey). Nothing about the key is
# fetched over the status service's HTTP, where an answer from anything on the
# LAN would be believed.
set -euo pipefail

if [ -r /etc/yuruna/host.env ]; then
    # shellcheck disable=SC1091
    . /etc/yuruna/host.env
fi
if [ -z "${YURUNA_STATUS_SERVICE_IP:-}" ] || [ -z "${YURUNA_STATUS_SERVICE_PORT:-}" ]; then
    echo "no host.env - cannot locate the host status service" >&2
    exit 2
fi

echo "== boot-time IP reporter =="
# Posts this VM's IP to the status service's log-upload sink at every boot (and
# now), so vm-core resolves the edge without DNS: GET /log/handoff/<hostname>.ip.txt
sudo tee /usr/local/lib/amisad-ip-report.sh >/dev/null <<'EOS'
#!/bin/bash
set -eu
for _ in $(seq 1 30); do
    # Both ends of this report can move while it is being made. host.env is
    # re-read per attempt because yuruna-host-locate refreshes it when the HOST
    # renumbers, and the address is re-read because it is THIS VM's, which the
    # same DHCP server can move just as easily. Reading either one once, outside
    # the loop, is what makes a retry send a stale value to a stale place.
    if [ -r /etc/yuruna/host.env ]; then
        . /etc/yuruna/host.env
    fi
    ip=$(hostname -I | awk '{print $1}')
    if [ -n "$ip" ] && [ -n "${YURUNA_STATUS_SERVICE_IP:-}" ] && [ -n "${YURUNA_STATUS_SERVICE_PORT:-}" ]; then
        curl -fsS --noproxy '*' --connect-timeout 5 --max-time 15 -X PUT --data "$ip" \
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
sudo tee /etc/systemd/system/amisad-ip-report.timer >/dev/null <<'EOS'
[Unit]
Description=Keep this edge VM's reported IP current

[Timer]
# Boot-only reporting publishes the address this VM had when it started, and
# amisad-core reads that file to find the edge for the whole cycle. Under a
# short DHCP lease neither end stays put for a cycle, so a report that is never
# repeated is a report that goes stale and strands the scenario -- which
# refuses to degrade to a single-VM run rather than quietly pretending it
# passed. Re-reporting is one small PUT; the interval is well inside the gap
# between a renumber and the next scenario needing the address.
OnBootSec=45s
OnUnitActiveSec=30s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOS
sudo systemctl daemon-reload
sudo systemctl enable amisad-ip-report.service amisad-ip-report.timer
sudo systemctl start amisad-ip-report.service
sudo systemctl start amisad-ip-report.timer

# A snapshot without writeback would strip the just-written IP-reporter units --
# see poc/test.md "Snapshot page-cache flush".
sync

echo "amisad edge setup complete"
