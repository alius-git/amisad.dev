# AmisAd POC — running the demo by hand

How to get a deployed AmisAd cluster ("prebuild", via the Yuruna framework) and
then drive the demo manually. Full test automation lives in [test.md](test.md).

## Prebuild

With the [one-time setup](test.md#one-time-setup) done, run the automation once
from an **elevated** PowerShell:

```powershell
poc\build\serve-local.ps1
pwsh poc\build\run-tests.ps1 -NoConfigGate
```

A green run leaves the latest scenario's VM **live** (e.g.
`amisad.s001.fulfillment`) with the ten services deployed and NodePorts
exposed — that VM is the demo box. Earlier scenario VMs are kept on disk
stopped; start one in Hyper-V Manager to demo it instead.

To log into the VM console: user `yamisad-sNNN` (per scenario —
[usernames.md](usernames.md)); the current password is in the host vault,
`c:\git\yuruna\test\status\extension\authentication\vault.yml`.

## Driving the demo

NodePorts on the scenario VM: coordinator `30080`, ledger `30081`, resource
`30082`, seller `30083`, identity `30084`.

**Re-arm after boot.** The scenario run ends with a snapshot + restart, which
cold-boots the VM: the deployed services come back on their own, but their
in-memory state (registered edge, Elena's offers) and the `slice-runtime`
process do not. Re-arm once per boot (this mirrors what the automated run did):

```bash
cd ~/amisad.dev/poc
NODE_IP=$(hostname -I | awk '{print $1}')
PORT=8090 LEDGER_URL=http://$NODE_IP:30081 RESOURCE_URL=http://$NODE_IP:30082 \
    nohup target/release/slice-runtime >/tmp/slice-runtime.log 2>&1 &
sleep 1
curl -sf -X POST http://$NODE_IP:30082/v1/edges \
    -d "{\"region\":\"region-a\",\"endpoint\":\"http://$NODE_IP:8090\"}"
curl -sf -X POST http://$NODE_IP:30083/v1/offers \
    -d '{"offer_id":"serving-set-01","tenant":"elena-atelier","title":"Ceramic serving set","category":"housewares","region":"region-a","price_cents":11000,"deliver_by_days":10,"auto_close":true}'
```

(`slice-runtime` runs here in the single-VM degraded mode; point the sequence's
`edgeHost` variable at a separate edge VM for the two-VM topology.)

**Console / ssh (headless demo)** — Maya's need auto-closes against Elena's
standing offer, Elena ships, Maya sees delivery:

```bash
export COORDINATOR_URL=http://$NODE_IP:30080 IDENTITY_URL=http://$NODE_IP:30084
target/release/buyer-client submit          # prints handle + match as JSON
curl -X POST http://$NODE_IP:30083/v1/orders/advance -d '{"match_id":"<id>","state":"provisioning"}'
curl -X POST http://$NODE_IP:30083/v1/orders/advance -d '{"match_id":"<id>","state":"fulfilled"}'
target/release/buyer-client wait <handle>   # -> status: delivered
```

The same APIs answer from the host or LAN at `http://<vm-ip>:<nodeport>`.

**Mobile (manual demo):** build and side-load the buyer app against the VM's
LAN address, state a need on the needs screen, and refresh its status while
advancing the order as above:

```bash
cd components/apps/buyer-flutter
flutter build apk --debug \
  --dart-define=COORDINATOR_URL=http://<vm-ip>:30080 \
  --dart-define=IDENTITY_URL=http://<vm-ip>:30084
adb install build/app/outputs/flutter-apk/app-debug.apk
```

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
