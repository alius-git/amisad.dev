# AmisAd POC — running the demo by hand

How to get the deployed AmisAd topology ("prebuild", via the Yuruna framework)
and then drive the demo manually. Full test automation lives in
[test.md](test.md).

## Prebuild

With the [one-time setup](test.md#one-time-setup) done, run the automation once
from an **elevated** PowerShell:

```powershell
poc\build\serve-local.ps1
pwsh poc\build\run-tests.ps1 -NoConfigGate
```

A green run leaves the demo environment **live**: `amisad-vm-core` (the ten
services, NodePorts exposed) and `amisad-vm-edge-a` (the region-A slice VM,
running `slice-runtime` from the last scenario). `amisad-vm-build` and
`amisad-vm-edge-b` are kept on disk stopped.

Console logins on `amisad-vm-core` ([usernames.md](usernames.md)):
- **demo personas** (non-admin): `maya`, `elena`
- **administrator**: `amisad-vm-core-admin`

Passwords are in the host vault,
`c:\git\yuruna\test\status\extension\authentication\vault.yml`.

The last scenario's state is still live after a run — you can inspect it, or
re-arm below for a fresh walkthrough.

## Driving the demo

NodePorts on `amisad-vm-core`: coordinator `30080`, ledger `30081`, resource
`30082`, seller `30083`, identity `30084`. The same APIs answer from the host
or LAN at `http://<vm-ip>:<nodeport>`.

**Re-arm (only after a VM restart).** A reboot of `amisad-vm-core` brings the
services back empty (in-memory state) and without a registered edge. Run the
command steps below as **`amisad-vm-core-admin`** — the repo and
`target/release/` binaries live under its home, which the non-admin personas
cannot traverse; `maya`/`elena` are the demo *narrative* logins, and the plain
`curl` steps also work from any user or from the host via the NodePorts:

```bash
cd ~/amisad.dev/poc
NODE_IP=$(hostname -I | awk '{print $1}')
export COORDINATOR_URL=http://$NODE_IP:30080 IDENTITY_URL=http://$NODE_IP:30084
```

Then either re-run a scenario script end to end
(`ubuntu.server.24.amisad-vm-core.s001.fulfillment.sh` restarts slice-runtime
on the edge, registers it, and seeds offers), or register the edge + seed by
hand using the curls below.

**s001.fulfillment** — Maya's need auto-closes against Elena's standing offer,
Elena ships, Maya sees delivery:

```bash
curl -sf -X POST http://$NODE_IP:30083/v1/offers \
    -d '{"offer_id":"serving-set-01","tenant":"elena-atelier","title":"Ceramic serving set","category":"housewares","region":"region-a","price_cents":11000,"deliver_by_days":10,"auto_close":true}'
target/release/buyer-client submit          # as maya: prints handle + match as JSON
curl -X POST http://$NODE_IP:30083/v1/orders/advance -d '{"match_id":"<id>","state":"provisioning"}'   # as elena
curl -X POST http://$NODE_IP:30083/v1/orders/advance -d '{"match_id":"<id>","state":"fulfilled"}'
target/release/buyer-client wait <handle>   # -> status: delivered
```

**s002.fitting** — you play Maya: a manual-policy dress need returns a
shortlist (note the dusty blue and out-of-range dresses are absent), nothing
commits until you choose, then one tap books the Thursday fitting:

```bash
# Elena's dresses (one dusty blue, one missing required attributes) + a second
# seller's misfits (past deadline; out of range) + fitting slots — the same
# seed set the automated run uses:
curl -sf -X POST http://$NODE_IP:30083/v1/offers -d '{"offer_id":"linen-midi-04","tenant":"elena-atelier","title":"Linen midi dress","category":"dresses","region":"region-a","price_cents":18000,"deliver_by_days":3,"auto_close":false,"attributes":["midi","sleeves","warm-fabric"],"fitting_slots":[{"slot_id":"thu-1","day":"thursday","day_ordinal":4},{"slot_id":"sat-1","day":"saturday","day_ordinal":6}]}'
curl -sf -X POST http://$NODE_IP:30083/v1/offers -d '{"offer_id":"dusty-blue-02","tenant":"elena-atelier","title":"Dusty blue midi dress","category":"dresses","region":"region-a","price_cents":16000,"deliver_by_days":3,"auto_close":false,"attributes":["midi","sleeves","warm-fabric","dusty-blue"],"fitting_slots":[{"slot_id":"thu-2","day":"thursday","day_ordinal":4}]}'
curl -sf -X POST http://$NODE_IP:30083/v1/offers -d '{"offer_id":"silk-slip-03","tenant":"elena-atelier","title":"Silk slip dress","category":"dresses","region":"region-a","price_cents":15000,"deliver_by_days":3,"auto_close":false,"attributes":["midi","sleeveless"],"fitting_slots":[{"slot_id":"thu-3","day":"thursday","day_ordinal":4}]}'
curl -sf -X POST http://$NODE_IP:30083/v1/offers -d '{"offer_id":"wool-midi-07","tenant":"brisa-outlet","title":"Wool midi dress","category":"dresses","region":"region-a","price_cents":14000,"deliver_by_days":30,"auto_close":false,"attributes":["midi","sleeves","warm-fabric"],"fitting_slots":[{"slot_id":"wed-7","day":"wednesday","day_ordinal":3}]}'
curl -sf -X POST http://$NODE_IP:30083/v1/offers -d '{"offer_id":"linen-wrap-08","tenant":"brisa-outlet","title":"Linen wrap dress","category":"dresses","region":"region-b","price_cents":13000,"deliver_by_days":2,"auto_close":false,"attributes":["midi","sleeves","warm-fabric"],"fitting_slots":[{"slot_id":"thu-8","day":"thursday","day_ordinal":4}]}'

target/release/buyer-client shortlist                 # -> handle + the shortlist; review it
curl -s http://$NODE_IP:30083/v1/orders               # -> count 0: nothing has committed
target/release/buyer-client book <handle> linen-midi-04 thu-1   # your choice commits + books
curl -s http://$NODE_IP:30083/v1/orders/match/<match_id>        # Elena's board: appointment, no buyer identity
curl -X POST http://$NODE_IP:30083/v1/orders/advance -d '{"match_id":"<match_id>","state":"provisioning"}'
curl -X POST http://$NODE_IP:30083/v1/orders/advance -d '{"match_id":"<match_id>","state":"fulfilled"}'   # -> settled
target/release/buyer-client notifications <handle>    # exactly two: shortlist, booking-confirmed
```

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
