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

A green run leaves the demo environment **live**: `amisad-core` (the ten
services, NodePorts exposed) and both edge VMs (`amisad-edge-a`/`-b`,
running `slice-runtime` with their region identity from the last scenario).
`amisad-build` is kept on disk stopped.

Console logins on `amisad-core` ([usernames.md](usernames.md)):
- **demo personas** (non-admin): `maya`, `elena`, `tom`, `priya`
- **administrator**: `amisad-core-admin`

Passwords are in the host vault,
`c:\git\yuruna\test\status\extension\authentication\vault.yml`.

The last scenario's state is still live after a run — you can inspect it, or
re-arm below for a fresh walkthrough.

## Driving the demo

NodePorts on `amisad-core`: coordinator `30080`, ledger `30081`, resource
`30082`, seller `30083`, identity `30084`, insights `30085`, platform `30086`,
ads `30087`, connect `30088`, audit `30089`. The same APIs answer from the host
or LAN at `http://<vm-ip>:<nodeport>`.

**Re-arm (only after a VM restart).** A reboot of `amisad-core` loses the
in-memory state (coordinator routing, identity tokens, the registered edge) —
but the ledgers, offers, and orders come back from PostgreSQL, chains intact. Run the
command steps below as **`amisad-core-admin`** — the repo and
`target/release/` binaries live under its home, which the non-admin personas
cannot traverse; maya/elena/tom/priya are the demo *narrative* logins, and the
plain `curl` steps also work from any user or from the host via the NodePorts:

```bash
cd ~/amisad.dev/poc
NODE_IP=$(hostname -I | awk '{print $1}')
export COORDINATOR_URL=http://$NODE_IP:30080 IDENTITY_URL=http://$NODE_IP:30084
```

Then either re-run a scenario script end to end
(`ubuntu.server.24.amisad-core.s001.fulfillment.sh` restarts slice-runtime
on the edge, registers it, and seeds offers), or register the edge + seed by
hand using the curls below. Note the scenario scripts assert against a fresh
database (the automation restores the `amisad-core` snapshot before each
one) — with durable orders on the board, s002's "zero commitments" check will
fail on a reused database; restore the snapshot for a clean walkthrough.

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

The settlement is now a durable record: `curl -s http://$NODE_IP:30081/v1/verify`
shows both hash chains verifying, and the same rows are on disk —
`sudo -u postgres psql -d amisad -c "TABLE ledger.settlement_ledger"` (as the
admin). They survive pod restarts and VM reboots; the app role cannot UPDATE or
DELETE ledger rows.

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

**s003.silence** — the kill switch: pause participation and the network goes
silent for you; commitments made before still complete; resuming brings your
open needs back to life. `buyer-client` runs as the admin; every step is
observable via curl. Fresh snapshot required: after an automated run,
`linen-wrap-09` is already in the durable catalog, so `open dress` would
match immediately instead of staying open — restore the `amisad-core`
snapshot first (as with s002's zero-state checks):

```bash
# Signup consents + one in-flight order + two open needs (nothing fits them):
target/release/buyer-client resume                    # records the signup grants
curl -sf -X POST http://$NODE_IP:30083/v1/offers -d '{"offer_id":"serving-set-01","tenant":"elena-atelier","title":"Ceramic serving set","category":"housewares","region":"region-a","price_cents":11000,"deliver_by_days":10,"auto_close":true}'
target/release/buyer-client submit                    # in-flight order (do NOT advance yet)
target/release/buyer-client open dress                # stays open - no fitting offer
target/release/buyer-client open decanter             # stays open
curl -s -X POST http://$NODE_IP:30085/v1/aggregation/cycle   # contributions: 2

# Pause, then watch a PERFECT offer produce... nothing:
target/release/buyer-client pause                     # revocation on the consent ledger
curl -sf -X POST http://$NODE_IP:30083/v1/offers -d '{"offer_id":"linen-wrap-09","tenant":"brisa-outlet","title":"Linen wrap dress","category":"dresses","region":"region-a","price_cents":13000,"deliver_by_days":2,"auto_close":true,"attributes":["midi","sleeves","warm-fabric"]}'
curl -s http://$NODE_IP:30080/v1/notifications/<dress_handle>   # [] - silence
curl -s http://$NODE_IP:30083/v1/orders                         # still just the in-flight order

# The pre-revocation commitment is honored (as elena):
curl -X POST http://$NODE_IP:30083/v1/orders/advance -d '{"match_id":"<id>","state":"provisioning"}'
curl -X POST http://$NODE_IP:30083/v1/orders/advance -d '{"match_id":"<id>","state":"fulfilled"}'   # -> settled

# Withdraw entirely, then resume - the open needs are served immediately:
target/release/buyer-client withdraw
curl -s -X POST http://$NODE_IP:30085/v1/aggregation/cycle   # contributions: 0
target/release/buyer-client resume                           # "rematched":1 - the dress matches now
target/release/buyer-client consents                         # full grant-revoke-regrant history
curl -s http://$NODE_IP:30081/v1/verify                      # all three chains verify
```

**s004.failover** — you play Tom (and then Priya): sovereignty pins the
match to the compliant region although region-b is roomier, two injected
isolation faults abort safely and retry clean, and the systemic pattern
becomes a cross-party case. Fresh snapshot recommended (attestation counts
assume a clean ledger). Both edges run `slice-runtime`; their IPs are in the
status server's `/log/handoff/amisad-edge-*.ip.txt` files:

```bash
# Tom: two regions with capacity, region-a sovereign (policy is the ONLY thing
# excluding the roomier region-b - check the unrestricted placement first):
curl -sf -X POST http://$NODE_IP:30082/v1/edges -d '{"region":"region-a","endpoint":"http://<edge-a-ip>:8080","capacity":2}'
curl -sf -X POST http://$NODE_IP:30082/v1/edges -d '{"region":"region-b","endpoint":"http://<edge-b-ip>:8080","capacity":10}'
curl -s -X POST http://$NODE_IP:30082/v1/placements -d '{"jurisdiction":"anywhere"}'   # -> region-b (roomier)
curl -sf -X POST http://$NODE_IP:30082/v1/policies -d '{"jurisdiction":"region-a","regions":["region-a"]}'
curl -s -X POST http://$NODE_IP:30082/v1/placements -d '{"jurisdiction":"region-a"}'   # -> region-a (sovereign)

# Harness hat on: arm two isolation faults on the compliant slice, then match:
curl -sf -X POST http://$NODE_IP:30083/v1/offers -d '{"offer_id":"serving-set-01","tenant":"elena-atelier","title":"Ceramic serving set","category":"housewares","region":"region-a","price_cents":11000,"deliver_by_days":10,"auto_close":true}'
curl -sf -X POST http://<edge-a-ip>:8080/v1/faults -d '{"mode":"isolation","count":2}'
target/release/buyer-client submit            # abort, abort, then the clean match

# Tom's queue and the evidence trail:
curl -s http://$NODE_IP:30082/v1/incidents                          # two isolation incidents
curl -s http://$NODE_IP:30081/v1/attestations/env/<aborted_env_id>  # created-attested-aborted-destroyed
curl -X POST http://$NODE_IP:30083/v1/orders/advance -d '{"match_id":"<id>","state":"provisioning"}'
curl -X POST http://$NODE_IP:30083/v1/orders/advance -d '{"match_id":"<id>","state":"fulfilled"}'   # one settlement

# Tom -> Priya: the systemic pattern becomes a cross-party case:
curl -s -X POST http://$NODE_IP:30086/v1/incidents -d '{"summary":"systemic isolation faults in region-a","from":"resource-ops","environment_ids":["<env1>","<env2>"]}'
curl -s http://$NODE_IP:30086/v1/incidents/<case_id>                # links both aborted lifecycles
```

**s005.attribution** — Marcel (agency) and Kai (creator) run the ad economy;
Maya's need matches Elena's offer boosted with Kai's creative, and attribution
splits between agency and creator without any buyer tracking. Fresh snapshot
recommended (settlement/attribution totals assume a clean ledger):

```bash
curl -sf -X POST http://$NODE_IP:30083/v1/offers -d '{"offer_id":"serving-set-01","tenant":"elena-atelier","title":"Ceramic serving set","category":"housewares","region":"region-a","price_cents":11000,"deliver_by_days":10,"auto_close":true}'
# Marcel: campaign + brief; Kai: asset; Marcel: activate (capture the ids):
CAMP=$(curl -sf -X POST http://$NODE_IP:30087/v1/campaigns -d '{"tenant":"elena-atelier","region":"region-a","category":"housewares","ad_cents_per_match":2000,"budget_cents":10000}')
curl -sf -X POST http://$NODE_IP:30087/v1/briefs -d '{"campaign_id":"<campaign_id>"}'
curl -sf http://$NODE_IP:30087/v1/briefs                              # Kai's demand queue
ASSET=$(curl -sf -X POST http://$NODE_IP:30087/v1/assets -d '{"campaign_id":"<campaign_id>","creator":"kai","creative":"summer-hero-01"}')
curl -sf -X POST http://$NODE_IP:30087/v1/campaigns/activate -d '{"campaign_id":"<campaign_id>","asset_id":"<asset_id>"}'
# Maya: her need's shortlist carries the creative; she accepts (no slot):
target/release/buyer-client campaign                                  # -> handle + boosted shortlist
target/release/buyer-client book <handle> serving-set-01             # -> boosted:true
curl -X POST http://$NODE_IP:30083/v1/orders/advance -d '{"match_id":"<id>","state":"provisioning"}'
curl -X POST http://$NODE_IP:30083/v1/orders/advance -d '{"match_id":"<id>","state":"fulfilled"}'
curl -s http://$NODE_IP:30081/v1/settlements/match/<id>              # agency 1200 + creator 800
curl -s http://$NODE_IP:30087/v1/attributions                        # aggregate agency/creator totals, no buyer data
```

**s006.mandate** — Maya delegates household buying to Pat under a scoped
mandate; in-scope closes on Pat's authority, over-cap routes to Maya, and
revocation is instant:

```bash
curl -sf -X POST http://$NODE_IP:30083/v1/offers -d '{"offer_id":"serving-set-01","tenant":"elena-atelier","title":"Ceramic serving set","category":"housewares","region":"region-a","price_cents":11000,"deliver_by_days":10,"auto_close":false}'
curl -sf -X POST http://$NODE_IP:30083/v1/offers -d '{"offer_id":"premium-vase-06","tenant":"elena-atelier","title":"Premium crystal vase","category":"housewares","region":"region-a","price_cents":18000,"deliver_by_days":10,"auto_close":false,"attributes":["premium"]}'
target/release/buyer-client grant-mandate pat housewares 14000        # Maya grants; per-item cap 14000
target/release/buyer-client workspace pat                             # Pat sees Maya as principal
target/release/buyer-client delegate-need pat housewares 12000        # under cap -> committed
target/release/buyer-client activity                                  # dual attribution on Maya's trail
target/release/buyer-client delegate-need pat housewares 20000 premium  # over cap -> held-for-approval
target/release/buyer-client approve <handle>                         # Maya approves -> committed
target/release/buyer-client delegate-need pat dresses 20000          # out of scope -> refused (no environment)
target/release/buyer-client revoke-mandate pat                       # revoke -> workspace clears, next attempt fails
```

**s007.inventory** — Alex (integration partner) connects Elena's ERP;
inventory truth governs matching, order state mirrors to the ERP, and the
credential scope is a hard ceiling:

```bash
PID=$(curl -sf -X POST http://$NODE_IP:30088/v1/partners -d '{"name":"alex-erp"}')    # sandbox only
curl -sf -X POST http://$NODE_IP:30088/v1/partners/certify -d '{"partner_id":"<partner_id>"}'
CRED=$(curl -sf -X POST http://$NODE_IP:30088/v1/grants -d '{"tenant":"elena-atelier","partner_id":"<partner_id>","scopes":["catalog","inventory","orders"]}')
curl -sf -X POST http://$NODE_IP:30088/v1/sync/catalog -d '{"credential":"<cred>","offers":[{"offer_id":"erp-lamp-01","tenant":"elena-atelier","title":"ERP table lamp","category":"housewares","region":"region-a","price_cents":8000,"deliver_by_days":5,"auto_close":true},{"offer_id":"erp-clock-02","tenant":"elena-atelier","title":"ERP wall clock","category":"housewares","region":"region-a","price_cents":9000,"deliver_by_days":5,"auto_close":true}]}'
curl -sf -X POST http://$NODE_IP:30088/v1/sync/inventory -d "{\"credential\":\"<cred>\",\"offer_id\":\"erp-lamp-01\",\"stock\":0,\"delta_ts\":$(date +%s)}"   # zero the cheaper lamp
target/release/buyer-client submit                                    # matches erp-clock-02 (in stock), not the zeroed lamp
curl -s http://$NODE_IP:30088/v1/erp/orders/<match_id>               # ERP mirror follows the order state
curl -s -X POST http://$NODE_IP:30088/v1/query -d '{"credential":"<cred>","resource":"settlement"}'  # 403: out of scope, logged
curl -s -X POST http://$NODE_IP:30088/v1/grants/revoke -d '{"credential":"<cred>"}'                  # revoke -> next sync 401
```

**s008.mediation** — a delivery dispute resolved without ever learning who
Maya is: a metadata-only case, a scoped time-boxed disclosure, a refund as
compensating ledger entries, and access that vanishes at expiry. Fresh
snapshot recommended:

```bash
# A settled order to dispute (as in s001):
curl -sf -X POST http://$NODE_IP:30083/v1/offers -d '{"offer_id":"serving-set-01","tenant":"elena-atelier","title":"Ceramic serving set","category":"housewares","region":"region-a","price_cents":11000,"deliver_by_days":10,"auto_close":true}'
target/release/buyer-client submit                                   # capture <match_id>
curl -X POST http://$NODE_IP:30083/v1/orders/advance -d '{"match_id":"<id>","state":"provisioning"}'
curl -X POST http://$NODE_IP:30083/v1/orders/advance -d '{"match_id":"<id>","state":"fulfilled"}'
# Maya reports non-delivery -> a case opens with metadata only (no identity):
curl -s -X POST http://$NODE_IP:30086/v1/support/cases -d '{"match_id":"<id>","metadata":{"order_state":"settled"}}'   # capture <case_id>
curl -s -X POST http://$NODE_IP:30086/v1/support/cases/disclosure/request -d '{"case_id":"<case_id>"}'
target/release/buyer-client disclose <case_id> delivery-photo-ref-77 4   # Maya grants, 4s TTL
curl -s http://$NODE_IP:30086/v1/support/cases/<case_id>/disclosure     # artifact readable now
curl -s -X POST http://$NODE_IP:30081/v1/settlements/adjust -d '{"match_id":"<id>","case_id":"<case_id>"}'   # refund: compensating entries
curl -s http://$NODE_IP:30081/v1/settlements/match/<id>                 # original untouched, net 0
sleep 5; curl -s -o /dev/null -w '%{http_code}\n' http://$NODE_IP:30086/v1/support/cases/<case_id>/disclosure   # 410: expired
```

**s009.suppression** — Dana publishes demand aggregates that suppress anything
below the anonymity threshold; Elena and Marcel read identical figures:

```bash
for i in 1 2 3 4 5 6; do curl -s -X POST http://$NODE_IP:30085/v1/insights/record -d '{"category":"housewares","region":"region-a","kind":"need"}'; done  # above threshold
curl -s -X POST http://$NODE_IP:30085/v1/insights/record -d '{"category":"housewares","region":"region-b","kind":"need"}'  # below threshold
curl -s http://$NODE_IP:30085/v1/workbench                            # region-a shown; region-b suppressed (absent)
curl -s -X POST http://$NODE_IP:30085/v1/outlooks -d '{"version":"2026-Q3"}'
curl -s http://$NODE_IP:30083/v1/demand-outlook/2026-Q3              # Elena's view
curl -s http://$NODE_IP:30087/v1/demand-view/2026-Q3                # Marcel's view (identical)
curl -s http://$NODE_IP:30085/v1/unmet-demand                        # gap flagged: category + region only
```

**s010.certification** — Ingrid independently certifies the evidence trail and
catches a tamper. This needs a corpus, so run the s010 script (it self-seeds a
completed match, an abort, consent, a mandate, and a disclosure+adjustment):

```bash
sudo project/poc/test/ubuntu.server.24/ubuntu.server.24.amisad-core.s010.certification.sh   # or, after it seeds:
curl -s -X POST http://$NODE_IP:30089/v1/certify                     # four dimensions, zero violations
curl -s http://$NODE_IP:30081/v1/attestations                        # fetch, tamper one payload, then:
curl -s -X POST http://$NODE_IP:30089/v1/certify/tamper --data-binary @tampered.json   # detected + localized
curl -s http://$NODE_IP:30089/v1/access-log                          # all GET: read-only, no personal data
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
