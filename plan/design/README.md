# AmisAd design diagrams

These source-derived views show the AmisAd proof of concept's blocks, lab topology, application services, and verification scenarios.

The [master POC design](../design.md) states the decisions these pages draw;
they link to it and do not restate it. Every page starts with a one-sentence
purpose line and a See line naming the documents it traces to, and each
application page's POC notes describe the code under [poc/](../../poc/README.md).

## Components and topology

- [POC overview](01-overview.md) -- The seven top-level blocks and the lab
  topology: dev host, build, core, two edge regions, stash, and device.
- [AmisAd/buyer](02-buyer.md) -- The buyer clients: needs, closing policy,
  delegate mode, and consent, all sent through the fabric coordinator.
- [AmisAd/seller](03-seller.md) -- seller-svc: catalog and inventory, the order
  state machine from committed to settled, and the demand-outlook view.
- [AmisAd/resource](04-resource.md) -- resource-svc: edge registry, allocation
  policy and placement per match, and the telemetry that raises incidents.
- [AmisAd/ads](05-ads.md) -- ads-svc: campaign workspace, creative studio,
  attribution credit from closed boosted matches, and the demand view.
- [AmisAd/insights](06-insights.md) -- insights-svc: aggregate ingest, the
  anonymity threshold gate, the workbench, and versioned outlooks.
- [AmisAd/platform](07-platform.md) -- platform-svc: cross-party incident cases
  and the support case desk, with refunds as compensating ledger entries.
- [AmisAd/audit](08-audit.md) -- audit-svc: chain verification over read-only
  ledger evidence, the four dimension checks, and certification.
- [AmisAd/connect](09-connect.md) -- connect-svc: versioned contracts, scoped
  connector credentials, the scope-enforcing gateway, and the order mirror.

## Scenario sequences

- [s001.fulfillment](seq.s001.fulfillment.md) -- A private need auto-closes in a
  sealed edge environment and settles across all four parties.
- [s002.fitting](seq.s002.fitting.md) -- A constraint-rich need returns a fitting
  shortlist, and nothing commits until the buyer books.
- [s003.silence](seq.s003.silence.md) -- Paused consent stops matching at the
  consent check, while committed orders still complete.
- [s004.failover](seq.s004.failover.md) -- Jurisdiction picks the compliant region,
  and an isolation fault aborts safely and retries clean.
- [s005.attribution](seq.s005.attribution.md) -- Creative rides into the sealed
  environment, and closing yields agency and creator credit.
- [s006.mandate](seq.s006.mandate.md) -- A scoped mandate lets a delegate close
  within its cap, and the principal must approve a closing over it.
- [s007.inventory](seq.s007.inventory.md) -- A certified connector syncs ERP truth
  into matching and is refused beyond its scope.
- [s008.mediation](seq.s008.mediation.md) -- A dispute resolves on metadata and one
  consented disclosure, with the refund as compensating entries.
- [s009.suppression](seq.s009.suppression.md) -- The threshold gate suppresses the
  small region, and one outlook drives stocking and campaigns.
- [s010.certification](seq.s010.certification.md) -- The auditor recomputes every
  chain, catches an injected tamper, and certifies on evidence.

## Reading the views

The overview names the blocks and places them on the lab network; each
application page opens one application, and each sequence page shows the
components exchanging messages in the order of its scenario in
[scenarios.md](../scenarios.md), from the seeded preconditions to the
Target Verification Point Yuruna asserts. A service named in a sequence either
has its own application page or appears under the same name as a box in one.

Every diagram holds at most seven boxes, counting subgraph frames and the boxes
for other services, and every sequence at most seven lifelines, actors included.
Where a service has more parts, they share a named box or are left undrawn, and
the page's See line says which; where a scenario has more parties, one is folded
into another or left out, and that page's See line says so. The topology draws
one box per lab node, with the stash service as the seventh. In the flowcharts,
dashed edges and boxes mark what is designed but not built, and solid means the
code does exactly that. In a sequence, a dotted arrow is a reply, and a step
that is designed but not built is named in the page's See line.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.

[Design](../design.md) | [Design overview](README.md)
