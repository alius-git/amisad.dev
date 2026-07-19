# AmisAd Verification Scenarios

**Companion documents:** [personas.md](personas.md) — the actors in these sequences · [applications.md](applications.md) — the applications and shared foundations they traverse · [design.md](design.md) — the POC design that implements them, with one sequence diagram per scenario under [design/](design/).

This document is the functional blueprint for the end-to-end automated system demo, executed on the **Yuruna** verification framework. Yuruna asserts that resources are configured to verify components against anticipated workloads; each scenario below is one discoverable test **sequence**, written in structured natural language — the narrative contract a Yuruna sequence implements, not the script itself.

**Conventions**

- **Actors** are the personas defined in [personas.md](personas.md); **applications** and **shared foundations** are as defined in [applications.md](applications.md).
- **Execution environment.** Sequences may span web, local, or mobile application interfaces — whatever surface each application presents. Scenarios describe the end-to-end user and system journey only; current temporary guest-environment limitations within the Yuruna framework are explicitly out of scope for this design.
- **Priorities.** `P0` — the core value loop and the privacy promise; nothing else matters if these fail. `P1` — the trust-boundary and economic expansions that make the ecosystem viable at scale. `P2` — governance and insight capstones that consume the evidence the rest produce. Scenarios are ordered by rank; within a rank, by dependency.
- **Target Verification Point.** The desired state (and, where applicable, cryptographic proof) Yuruna must assert to declare the sequence successful. Every assertion names observable state — ledger entries, application views, attestation records — never internal implementation detail.

---

## SCENARIO-001: Intent-Driven Edge Match and Automated Fulfillment

**Objective & Priority.** Validate the golden path — the complete value loop of a private need auto-closing against a standing offer, fulfilled and settled across all four parties. **Priority: P0, ranked first** — this is the product: if a need cannot privately become a delivered, settled order, no other scenario has meaning.

**Cross-Refs:** *Personas:* Maya, Elena, Tom · *Applications:* AmisAd/buyer, AmisAd/seller, AmisAd/resource · *Foundations:* Private Matching Fabric, Identity & Verification, Consent Ledger, Settlement & Attribution Ledger · *Sequence diagram:* [seq-001](design/seq-001.md)

**Step-by-Step Sequence**

1. Maya (verified subscriber, active participation consent) states a need in AmisAd/buyer: a wish-list gift, budget cap, delivery city, delivery deadline — and sets the closing policy to automatic.
2. Elena's AmisAd/seller tenant holds a matching catalog item with a standing deal: price under Maya's cap, delivery range covering the target city, auto-close enabled.
3. The buyer application requests matching → the Private Matching Fabric acquires a sealed slice from carrier capacity governed by Tom's allocation policies in AmisAd/resource; the environment is created, attested, and jurisdiction-checked.
4. Offers travel into the sealed environment; Maya's need does not leave it → the match is computed; need and standing deal satisfy each other; both auto-close policies permit closing.
5. The match closes inside the environment → a match record (with settlement instruction) exits; the environment is destroyed; its lifecycle is written to the attestation log.
6. Elena's order board shows a new committed order (need context only, no buyer identity) → she ships; order state advances matched → committed → provisioning → fulfilled, mirrored to Maya's fulfillment tracking.
7. On fulfillment confirmation, the Settlement & Attribution Ledger records the four-way split: seller revenue, network share, platform fee, ad-partner credit (zero in this campaign-free run).
8. Maya's tracker shows the gift delivered; Tom's settlement report shows the carrier's share for hosting this match.

**Target Verification Point.** Desired state: exactly one settlement record for the match whose splits sum precisely to the match value; buyer-side order state `Delivered` and seller-side order state `Settled` referencing the same match ID; an attestation chain entry proving the sealed environment was created, attested, executed, and destroyed; and the environment egress log containing **zero** need-content or buyer-identity payloads — only the match record.

---

## SCENARIO-002: Considered Purchase, Constraint Fidelity, and In-Person Booking

**Objective & Priority.** Validate matching correctness under rich constraints (including exclusions) and the human-decision path: shortlist, explicit choice, one-tap booking of an in-person service. **Priority: P0, ranked second** — this is the flagship user story (Maya's dress); it proves matches *fit* and that the buyer keeps the final say.

**Cross-Refs:** *Personas:* Maya, Elena · *Applications:* AmisAd/buyer, AmisAd/seller · *Foundations:* Private Matching Fabric, Consent Ledger, Settlement & Attribution Ledger · *Sequence diagram:* [seq-002](design/seq-002.md)

**Step-by-Step Sequence**

1. Maya states a need with layered constraints: midi dress, with sleeves, warm-weather fabric, explicit exclusion ("not dusty blue"), fitting available near her office before Friday — closing policy: manual.
2. Elena's catalog holds several candidate dresses — some qualifying, at least one dusty blue — plus bookable fitting slots including Thursday; a second seeded seller offers dresses that violate the deadline or range.
3. Matching runs in a sealed environment → only offers satisfying **every** constraint return; the dusty blue dress and the out-of-range seller's offers are absent from the shortlist.
4. Maya reviews the shortlist in AmisAd/buyer → nothing has closed automatically; system state shows zero commitments.
5. Maya selects one dress and taps to book the Thursday fitting → the booking commits; Elena's order board shows a fitting appointment with the need context (dress requirements) and nothing about who is coming.
6. Maya attends; Elena marks the fitting fulfilled and the sale closed → the order advances to settled; the ledger records the split.
7. Throughout, Maya receives exactly two notifications: the shortlist and the booking confirmation — nothing else.

**Target Verification Point.** Desired state: the shortlist contains only offers satisfying all stated constraints (assert the excluded color and out-of-range offers are absent); no commitment exists before the buyer's explicit action; after booking, buyer and seller hold consistent appointment records referencing the same match ID with the seller-side record containing no buyer identity; notification log length is exactly two.

---

## SCENARIO-003: Consent Revocation and the Right to Silence

**Objective & Priority.** Validate the kill switch: pausing participation stops matching instantly, withdrawal is honored everywhere, and committed obligations still complete. **Priority: P0, ranked third** — "nothing about you leaves, and you can leave" is the license to operate; a privacy promise that cannot be revoked is not a promise.

**Cross-Refs:** *Personas:* Maya, Elena · *Applications:* AmisAd/buyer, AmisAd/seller · *Foundations:* Consent Ledger, Private Matching Fabric, Settlement & Attribution Ledger · *Sequence diagram:* [seq-003](design/seq-003.md)

**Step-by-Step Sequence**

1. Maya has one order in flight (committed, not yet delivered) and two open needs still matching.
2. Maya pauses participation in AmisAd/buyer's consent controls → the Consent Ledger records the revocation with a timestamp; enforcement is immediate, not queued.
3. A matching cycle is triggered for her open needs → the fabric refuses: consent check fails at execution time; no sealed environment is created for her needs.
4. A seeded seller publishes a new offer that would perfectly fit one of Maya's open needs → nothing happens; no match, no notification; Maya hears silence.
5. The in-flight order proceeds → Elena fulfills; the order settles normally; commitments made before revocation are honored.
6. Maya withdraws entirely → her aggregate-contribution permission ends; subsequent insight aggregation cycles run without any contribution derived from her needs.
7. Maya later resumes participation → the Consent Ledger records the new grant; the next matching cycle serves her open needs again.

**Target Verification Point.** Desired state: zero match events and zero created environments for the buyer between the revocation and resumption timestamps (assert against the attestation log's time range); the in-flight order reaches `Settled` normally; the Consent Ledger holds the full immutable grant → revoke → re-grant history; and no notification was delivered to the buyer during the paused window.

---

## SCENARIO-004: Sovereign Slice Allocation, Isolation Fault, and Attested Failover

**Objective & Priority.** Validate the infrastructure story: slices allocate where sovereignty rules demand, an isolation fault destroys the environment rather than risking it, the match retries cleanly, and the incident escalates across party lines. **Priority: P1, ranked fourth** — the P0 scenarios assume the fabric works; this proves it fails *safe*, which is what regulators and carriers actually buy.

**Cross-Refs:** *Personas:* Tom, Priya · *Applications:* AmisAd/resource, AmisAd/platform · *Foundations:* Private Matching Fabric, Settlement & Attribution Ledger · *Sequence diagram:* [seq-004](design/seq-004.md)

**Step-by-Step Sequence**

1. Tom configures allocation policy in AmisAd/resource: two regions with capacity, one jurisdiction-restricted; a seeded buyer's needs carry the restricted jurisdiction.
2. A matching request arrives → the fabric allocates a slice; jurisdictional constraint evaluated at allocation time places it in the compliant region only, even though the other region has more free capacity.
3. Mid-match, the harness injects an isolation fault into the active slice → the environment self-terminates immediately; partial state is destroyed with it; the abort is written to the attestation log with the fault reason.
4. Tom's incident queue raises the fault → telemetry shows the slice terminated; no match record was emitted from the aborted environment.
5. The matching request retries automatically → a fresh slice allocates in the same compliant region; the match completes; settlement records normally.
6. Because the fault pattern is systemic (harness injects a repeat), Tom escalates the incident to Priya → AmisAd/platform opens a cross-party incident case linked to both attestation entries.
7. Tom's settlement report shows hosting revenue for the completed match only — no compensation for the aborted environment.

**Target Verification Point.** Desired state: every allocation for the restricted-jurisdiction buyer resides in the compliant region (assert zero out-of-region attestation entries); the aborted environment's attestation record shows `created → attested → aborted → destroyed` with no egress; exactly one settlement record exists (the successful retry); and the platform incident case references both environment lifecycles.

---

## SCENARIO-005: Campaign-Boosted Match, Edge Creative Serving, and Attribution Credit

**Objective & Priority.** Validate the advertising economy end to end: brief → creative → campaign → aggregate targeting → creative rendered only inside the sealed environment → match → attribution credit for agency and creator. **Priority: P1, ranked fifth** — this is the revenue engine for the ad-partner side and the proof that attribution survives without tracking.

**Cross-Refs:** *Personas:* Marcel, Kai, Elena, Maya · *Applications:* AmisAd/ads, AmisAd/seller, AmisAd/buyer, AmisAd/insights · *Foundations:* Private Matching Fabric, Settlement & Attribution Ledger · *Sequence diagram:* [seq-005](design/seq-005.md)

**Step-by-Step Sequence**

1. Marcel, in AmisAd/ads campaign mode, consults the aggregate demand view (published by AmisAd/insights) and creates a campaign for Elena's summer collection: region, need category, budget, flight dates.
2. Marcel issues a creative brief → it appears in Kai's demand queue in creative studio mode; Kai accepts, produces the asset, and submits it through revision to approval.
3. Marcel places the approved asset into the campaign → campaign state becomes active; budget pacing begins.
4. A seeded buyer (Maya) states a need in the campaign's category and region → matching runs in a sealed environment; the campaign qualifies Elena's offer for boosted presentation; the creative asset travels **into** the environment and is rendered there, with the offer.
5. Maya's shortlist shows Elena's offer carrying Kai's creative → she accepts; the match closes; the environment is destroyed.
6. Attribution is computed inside the fabric before destruction → the match record carries credit assignments: campaign contribution (Marcel's agency) and creative contribution (Kai).
7. The Settlement & Attribution Ledger distributes the split, now including ad-partner credit → Marcel's attribution report shows one closed match against campaign spend; Kai's performance view shows the asset's contribution; neither view contains any buyer-level data.
8. Campaign budget decrements by the match outcome, not by impressions.

**Target Verification Point.** Desired state: the settlement record for the match includes non-zero ad-partner credit split between agency and creator, referencing campaign and asset IDs; agency and creator dashboards show aggregate-only figures consistent with the ledger; the creative asset appears in the environment ingress log and **no buyer signal** appears in any campaign-side view or egress record; budget ledger decrement equals the campaign's per-match commitment.

---

## SCENARIO-006: Delegated Procurement Under a Scoped Mandate

**Objective & Priority.** Validate delegated authority end to end: mandate grant, in-scope autonomous action, over-cap approval routing, principal visibility, and instant revocation. **Priority: P1, ranked sixth** — delegation is a day-one trust boundary; a mandate that leaks scope or survives revocation would be a privacy breach with the principal's own name on it.

**Cross-Refs:** *Personas:* Maya, Pat, Elena · *Applications:* AmisAd/buyer (delegate mode), AmisAd/seller · *Foundations:* Consent Ledger, Identity & Verification, Private Matching Fabric, Settlement & Attribution Ledger · *Sequence diagram:* [seq-006](design/seq-006.md)

**Step-by-Step Sequence**

1. Maya grants Pat a mandate in AmisAd/buyer: household-goods category, monthly budget cap, closing authority below a per-item limit, three-month expiry → the Consent Ledger records the mandate; Identity & Verification confirms Pat as a verified delegate bound to Maya.
2. Pat's delegate workspace now shows Maya as a principal, with the mandate's scope, remaining cap, and expiry visible.
3. Pat states an in-scope need under the per-item limit → matching runs; the fabric checks the mandate at match time; the match closes on Pat's authority against Elena's standing offer.
4. The match record carries dual attribution (actor: Pat; principal: Maya; mandate reference) → Maya's activity trail shows the action within moments.
5. Pat states a second in-scope need whose best match exceeds the per-item limit → the fabric permits the match but not the closing; an approval handoff routes to Maya.
6. Maya approves → the closing completes, attributed to Maya-via-approval; the trail shows both the request and the decision.
7. Pat attempts an out-of-scope need (outside the mandated category) → the delegate workspace refuses at submission: no environment is created, nothing reaches matching.
8. Maya revokes the mandate → the Consent Ledger records revocation; Pat's workspace loses the principal view immediately; a subsequent delegated attempt fails the mandate check.

**Target Verification Point.** Desired state: every delegated match record carries complete dual attribution resolving to a mandate that was valid at execution time; the over-cap closing exists only after the principal's recorded approval; the out-of-scope attempt produced zero environments and zero ledger entries; and no delegated action of any kind exists after the revocation timestamp.

---

## SCENARIO-007: Enterprise Integration Onboarding and Inventory-Truth Matching

**Objective & Priority.** Validate the integration lifecycle: partner verification, sandbox certification, seller-granted scoped credentials, live inventory sync driving matching, and order events returning to the external system. **Priority: P1, ranked seventh** — matching against stale inventory poisons buyer trust one disappointment at a time; this proves external truth governs matching.

**Cross-Refs:** *Personas:* Alex, Elena, Priya · *Applications:* AmisAd/connect, AmisAd/seller, AmisAd/platform · *Foundations:* Identity & Verification, Private Matching Fabric, Settlement & Attribution Ledger · *Sequence diagram:* [seq-007](design/seq-007.md)

**Step-by-Step Sequence**

1. Alex registers as an integration partner → Priya's participant registry verifies identity and standing; Alex gains sandbox access only.
2. Alex builds a connector in a sandbox tenant against the versioned contracts: catalog sync in, inventory deltas in, order-lifecycle webhooks out → certification checks pass in the sandbox.
3. Elena grants Alex's connector access to her production tenant, scoped to catalog, inventory, and orders → AmisAd/connect issues credentials with exactly that ceiling.
4. The connector syncs Elena's ERP catalog into her tenant → offers become matchable; a seeded external sale (at the shop counter) emits an inventory delta → the last unit of one item goes to zero in AmisAd within the sync window.
5. A seeded buyer states a need fitting the now-out-of-stock item → matching returns no offer for it (assert), while an in-stock alternative from the same catalog matches normally.
6. The in-stock match closes → the order-lifecycle webhook delivers each state transition to the ERP; both systems show the same order state at each step, through settlement.
7. The connector attempts an out-of-scope call (e.g., settlement history beyond orders) → the gateway refuses on credential scope; the attempt is logged.
8. The harness replays a dropped webhook delivery → the connector converges to the same order state; no duplicate order effects appear (idempotency).
9. Elena revokes the integration grant → credentials die; the next sync attempt fails authentication; her catalog remains intact and hand-editable.

**Target Verification Point.** Desired state: no match ever references inventory the external system had already zeroed (assert against delta timestamps); order states in the ERP mirror and AmisAd/seller are identical at every transition; the out-of-scope call is refused and logged with no data returned; replayed deliveries produce no duplicate state; and zero buyer identity or need content appears anywhere in the integration surface's logs or payloads.

---

## SCENARIO-008: Zero-Knowledge Dispute Mediation and Settlement Adjustment

**Objective & Priority.** Validate support that cannot become surveillance: a delivery dispute resolved from metadata, a minimal consented disclosure when metadata is not enough, and a refund posted as a compensating entry — with the buyer anonymous throughout. **Priority: P1, ranked eighth** — support is where privacy promises historically die; this proves the mediation model holds under a real dispute.

**Cross-Refs:** *Personas:* Maya, Sam, Elena, Priya · *Applications:* AmisAd/platform (support desk), AmisAd/buyer, AmisAd/seller · *Foundations:* Consent Ledger, Settlement & Attribution Ledger · *Sequence diagram:* [seq-008](design/seq-008.md)

**Step-by-Step Sequence**

1. From a settled order (seeded like SCENARIO-001's), Maya reports non-delivery in AmisAd/buyer → a support case opens in Sam's queue carrying operational metadata only: order states, timestamps, carrier confirmation, settlement entries.
2. Sam reviews the metadata → the delivery confirmation conflicts with the buyer's report; the case cannot close on metadata alone.
3. Sam requests a consented disclosure from Maya: the delivery address's confirmation photo reference, scoped to this case, time-boxed → the request is recorded in the Consent Ledger.
4. Maya grants it → Sam receives exactly the granted artifact, read-only; the grant, delivery, and expiry are all logged; Maya's identity remains withheld from the case.
5. The evidence supports Maya → Sam proposes a refund adjustment; Elena reviews the proposal in AmisAd/seller and accepts.
6. The Settlement & Attribution Ledger posts compensating entries reversing the appropriate splits, referencing the case ID → both parties' settlement views reflect the adjustment; history remains unedited.
7. Sam records the resolution and closes the case; a recurring-pattern note escalates to Priya's operations queue for root-cause review.
8. The disclosure grant expires → the artifact is no longer accessible from the case; the harness asserts the access path is gone.

**Target Verification Point.** Desired state: the case record contains no buyer identity at any point; the disclosure grant in the Consent Ledger shows request → grant → delivery → expiry with scope never exceeded; the adjustment exists solely as compensating entries referencing the case, with original settlement records untouched; and post-expiry access to the disclosed artifact fails.

---

## SCENARIO-009: Aggregate Insight Publication and the Demand-Planning Loop

**Objective & Priority.** Validate the ecosystem's only analytical window: demand aggregates released solely above anonymity thresholds, published as versioned outlooks that inform seller stocking and campaign planning. **Priority: P2, ranked ninth** — insight is the growth flywheel, but it must be proven *after* the privacy machinery it depends on, because its central assertion is a suppression, not a feature.

**Cross-Refs:** *Personas:* Dana, Elena, Marcel · *Applications:* AmisAd/insights, AmisAd/seller, AmisAd/ads · *Foundations:* Private Matching Fabric, Settlement & Attribution Ledger · *Sequence diagram:* [seq-009](design/seq-009.md)

**Step-by-Step Sequence**

1. The harness seeds match activity across two regions: one with need volume well above the anonymity threshold in a category, one with volume deliberately below it.
2. Sealed environments emit threshold-protected aggregate contributions as they complete → the aggregation pipeline accumulates per category, region, and time window.
3. Dana opens the insights workbench → the high-volume region shows rising demand in the category; the below-threshold region shows **no figure at all** — suppressed, not zeroed, indistinguishable from absent.
4. Dana publishes a demand outlook → it appears, versioned and dated, in Elena's AmisAd/seller demand-outlook view and Marcel's AmisAd/ads aggregate demand view.
5. Elena adjusts stock for the rising category; Marcel scopes a campaign to the high-demand region → both act on identical published figures.
6. Dana reviews ecosystem health metrics → unmet-demand surfacing flags the seeded gap where needs outnumber offers; the flag carries category and region only.
7. The harness queries every published view for any figure derived from the below-threshold region → none exists anywhere downstream.

**Target Verification Point.** Desired state: every published aggregate anywhere in the ecosystem satisfies the anonymity threshold (assert the below-threshold region appears in no workbench, outlook, seller view, or campaign view); outlook figures are identical across all consuming applications for the same version; and no query path from any insights surface returns individual-level or below-threshold data.

---

## SCENARIO-010: Independent Certification of the Full Evidence Trail

**Objective & Priority.** Validate that the entire system is *provable*: the auditor independently verifies attestation continuity, residency, consent (all three grant types), and settlement conservation across everything scenarios 001–009 produced — and detects deliberate tampering. **Priority: P2, ranked last by dependency, first by consequence** — it consumes the evidence of every other scenario; it is the capstone that turns nine passing tests into a certifiable system.

**Cross-Refs:** *Personas:* Ingrid, Priya · *Applications:* AmisAd/audit, AmisAd/platform · *Foundations:* Private Matching Fabric (attestation evidence), Identity & Verification, Consent Ledger, Settlement & Attribution Ledger · *Sequence diagram:* [seq-010](design/seq-010.md)

**Step-by-Step Sequence**

1. With the artifacts of scenarios 001–009 in place, Ingrid opens AmisAd/audit and starts a certification run scoped to the demo jurisdiction and time range.
2. Attestation continuity → the run walks the cryptographically chained evidence log end to end: every environment shows a complete lifecycle (created → attested → executed/aborted → destroyed), including SCENARIO-004's aborted slice; chain verification requires no trust in the platform's word.
3. Residency → every environment's location satisfies the jurisdiction rules in force at its allocation time, including the restricted-jurisdiction allocations of SCENARIO-004.
4. Consent → every match maps to a valid participation consent at execution time; SCENARIO-003's revocation window contains zero matching activity; SCENARIO-006's mandate history and SCENARIO-008's disclosure grant each show grant → use-within-scope → termination honored.
5. Settlement conservation → for every match, splits sum exactly to match value; every adjustment consists of compensating entries referencing a support case; derived balances equal the sum of history; nothing was edited.
6. Tamper check → the harness injects a modification into a copy of one attestation record → chain verification flags exactly that record; Ingrid's investigation workspace isolates it and its dependents.
7. Ingrid issues the certification: findings per dimension, the tamper detection documented, the regulator-facing report generated → Priya receives the findings record in AmisAd/platform.
8. Throughout, the audit application performed no write to any ledger and accessed no personal data — its own access log proves it.

**Target Verification Point.** Desired state: the certification run completes with all four dimensions (attestation, residency, consent, settlement) reporting zero unexplained violations across the full scenario corpus; the injected tamper is detected and localized to the modified record; and the audit application's access log shows read-only operations exclusively, with no personal-data scope ever exercised.

---

## Traceability Assurance

Every persona, application, and shared foundation is exercised by at least one core sequence. No orphan components, no unverified workflows.

### Personas × Scenarios

| Persona | Exercised in |
|---------|--------------|
| Maya — Buyer | 001, 002, 003, 005, 006, 008 |
| Elena — Seller | 001, 002, 003, 005, 006, 007, 008, 009 |
| Tom — Telco Administrator | 001, 004 |
| Marcel — Ad Agency Administrator | 005, 009 |
| Kai — Creative Partner | 005 |
| Priya — Platform Operator | 004, 007, 008, 010 |
| Ingrid — Trust Auditor | 010 |
| Dana — Demand Analyst | 009 |
| Alex — Integration Partner | 007 |
| Sam — Support Agent | 008 |
| Pat — Buyer-Side Delegate | 006 |

### Applications × Scenarios

| Application | Exercised in |
|-------------|--------------|
| AmisAd/buyer | 001, 002, 003, 005, 006, 008 |
| AmisAd/seller | 001, 002, 003, 005, 006, 007, 008, 009 |
| AmisAd/resource | 001, 004 |
| AmisAd/ads | 005, 009 |
| AmisAd/insights | 005 (demand view), 009 |
| AmisAd/platform | 004, 007, 008, 010 |
| AmisAd/audit | 010 |
| AmisAd/connect | 007 |

### Shared Foundations × Scenarios

| Foundation | Exercised in |
|------------|--------------|
| Private Matching Fabric | 001, 002, 003, 004, 005, 006, 007, 009, 010 (evidence) |
| Identity & Verification | 001 (subscriber), 006 (delegate), 007 (workload, partner), 010 (audit) |
| Consent Ledger | 001, 002, 003 (revocation), 006 (mandate), 008 (disclosure grant), 010 (audit) |
| Settlement & Attribution Ledger | 001, 002, 003, 004, 005 (ad credit), 006, 007, 008 (adjustment), 009, 010 (conservation) |

**Coverage statement.** All 11 personas, all 8 applications, and all 4 shared foundations appear in at least one sequence; the three P0 sequences alone cover the complete core value loop plus the privacy kill switch; and SCENARIO-010 closes the loop by independently certifying the evidence produced by every sequence before it.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 by Alisson Sol et al.
