# AmisAd Application Ecosystem

**Companion documents:** [personas.md](personas.md) — the people these applications serve · [scenarios.md](scenarios.md) — the end-to-end verification sequences that exercise them.

AmisAd is a privacy-first matching ecosystem: buyers state needs privately, sellers post offers openly, and the match is computed where the buyer is — on their device or in a sealed, ephemeral slice of the network nearby. The introduction travels; the buyer's life stays home. Every match compensates four parties — seller, network, platform, and ad partners — from value created, not data extracted.

This document defines each application required to run that ecosystem: its business objective, its core user-facing functionality, and the architectural paradigms suited to the job. It deliberately avoids specific frameworks and vendors; it names the *shape* of each system, not its parts list.

---

## Design Principles

Every application below inherits six commitments:

1. **The data never travels; the computation does.** Personal needs are matched on the buyer's device or in sealed network environments close to them. No application outside the buyer's own ever holds an individual's needs, identity, or history.
2. **Sovereignty by design.** Matches run inside the buyer's regulatory perimeter. Residency is not a compliance chore bolted on; it is where the workload physically runs.
3. **Aggregate is the only analytical window.** Any insight that leaves the sealed environment is aggregated above anonymity thresholds. There is no individual-level reporting anywhere in the ecosystem — including internally.
4. **Everyone in the loop is paid from the match.** Settlement — buyer served, seller found, network rewarded, platform credited — is a first-class platform function with an auditable trail.
5. **Silence by default.** Applications speak to their users when something fits or something needs a decision. No engagement mechanics, no attention harvesting.
6. **Authority is explicit, scoped, and revocable.** Anyone acting for someone else — a delegate for a buyer, a connector for a seller, a support agent for a case — acts under a recorded grant: minimal in scope, bounded in time, revocable at will, and attributable forever. No implied authority, anywhere.

---

## Ecosystem at a Glance

| Application | Primary personas | One-line objective |
|-------------|------------------|--------------------|
| AmisAd/buyer | Maya, Pat (delegate mode) | Let a person state needs privately and get only offers that fit |
| AmisAd/seller | Elena | Let a seller meet real intent and run the resulting business |
| AmisAd/resource | Tom | Let carriers host sealed matching profitably, at carrier grade |
| AmisAd/ads | Marcel, Kai | Run campaigns on real demand and supply the creative that serves them |
| AmisAd/insights | Dana (feeds Elena, Marcel) | Turn aggregate demand into decisions without seeing anyone |
| AmisAd/platform | Priya, Sam (support desk) | Keep the marketplace verified, settled, supported, and fair |
| AmisAd/audit | Ingrid | Prove the privacy promise, independently and repeatably |
| AmisAd/connect | Alex | Let external business systems act for sellers — safely, under scoped grants |

Beneath the applications sit four **shared platform foundations** — the matching fabric, identity and verification, the consent ledger, and the settlement ledger — defined [at the end](#shared-platform-foundations).

---

## AmisAd/buyer

**Business objective.** Give individuals a third way between ads that don't know them and ads that know them too well: state a need once, in private, and receive only offers that fit — with fulfillment tracked to completion and absolute silence otherwise. This application is the source of the ecosystem's entire supply of genuine intent; its trustworthiness is the business.

**Core user-facing functionality**

- **Needs and wants list** — capture a need in the buyer's own words with constraints that matter: budget, deadline, place, taste, exclusions ("anything but dusty blue").
- **Private matching** — the need is matched against seller offers without ever leaving the buyer's control; only fitting offers return.
- **Offer shortlist and decisions** — review matches that satisfy every constraint; accept, decline, or book with one tap.
- **Closing policies** — per need, choose automatic closing for routine purchases or explicit approval for considered ones.
- **Fulfillment tracking** — follow every commitment from acceptance through delivery, appointment, or completion.
- **Consent and participation controls** — see exactly what participation means; pause or withdraw entirely at any time.
- **Delegate mode (Pat)** — a principal grants a mandate: need categories, budget cap, closing authority, expiry. The delegate manages needs per principal in strictly separated workspaces; closings beyond the delegated authority route to the principal for approval; the principal sees a complete activity trail and can revoke instantly.

**Architectural paradigms**

- **Personal data vault, device-resident** — the buyer's needs, history, and preferences live with the buyer; the application is the sole custodian of individual data in the entire ecosystem.
- **Edge-local computation** — matching executes on-device where possible, otherwise in a sealed, attested environment at the network edge (see [Private Matching Fabric](#shared-platform-foundations)); offers travel in, results travel out, the need never leaves.
- **Offline-first mobile experience** — needs are captured and managed regardless of connectivity; matching resumes when the edge is reachable.
- **Policy engine for autonomous closing** — user-authored rules evaluated locally decide what closes without a tap.
- **Capability-scoped delegated authorization** — a mandate is a first-class Consent Ledger record, not a shared login: every delegate action carries dual attribution (actor + principal + mandate), is checked against scope, cap, and expiry at execution time, and dies the moment the mandate does. Delegates never gain access to the principal's vault beyond the mandated categories.
- **Event-driven, silence-preserving notifications** — the application initiates contact only on a fitting match, a fulfillment milestone, or an approval request from a delegate.

---

## AmisAd/seller

**Business objective.** Replace paying-to-be-ignored with meeting real intent: let sellers describe what they offer, where, and on what terms, then run the resulting orders, provisioning, and payments — without ever touching a buyer's data. The seller sees the need and nothing about the person, and that is enough to do business.

**Core user-facing functionality**

- **Offer catalog** — products and services in the seller's own words, structured enough to match: attributes, variants, what makes the offer distinctive.
- **Inventory and availability** — stock levels, service capacity, appointment slots — so matches reflect deliverable reality; maintained by hand or synced from connected systems.
- **Reach definition** — regions served, delivery ranges, in-person availability; the seller only meets buyers they can actually serve.
- **Terms and standing deals** — prices, timing, offers that close automatically when a need fits, or conversation-first selling.
- **Order and fulfillment board** — every match that became a commitment, tracked through provisioning, delivery, and completion.
- **Payments and settlement view** — what each match earned, fees deducted, settlement status and history.
- **Demand outlooks** — aggregate signals published from AmisAd/insights: what nearby demand is rising, with no individuals visible.
- **Integration grants** — the seller authorizes an integration partner to act on specific capabilities of their tenant (catalog, inventory, orders), sees everything connectors change, and revokes access at will (see AmisAd/connect).

**Architectural paradigms**

- **Multi-tenant business workspace** — thousands of independent sellers, each with isolated data, on shared infrastructure scaled from a sole proprietor to a chain.
- **Structured, matchable offer model** — catalog entries expressed so the matching fabric can evaluate them against private needs without human interpretation.
- **Event-driven order lifecycle** — orders as explicit state machines (matched → committed → provisioning → fulfilled → settled), advanced by events, with every transition visible to the seller — and mirrored outward to connected systems.
- **Open integration surface, realized through AmisAd/connect** — catalog, inventory, availability, and the order lifecycle exposed as versioned contracts so external ERPs, inventory systems, and points of sale remain the systems of record. The surface exists solely on the supply side: no integration contract exposes anything about any buyer.

---

## AmisAd/resource

**Business objective.** Let network operators turn infrastructure they already own into recurring match-hosting revenue — while making the sovereignty promise (matches stay close, stay in-country, stay sealed) an operational reality rather than a policy statement. This application is how "compliance is the moat" gets run day to day.

**Core user-facing functionality**

- **Resource control plane** — live inventory of edge capacity, active sealed slices, and match-hosting health across regions.
- **Dynamic slice allocation** — policies governing where sealed matching environments may run, how much capacity each site commits, priorities under contention; allocation itself is automatic and ephemeral.
- **Sovereignty boundary management** — residency and processing rules expressed as enforced constraints: which matches may run where, by jurisdiction.
- **Incident management** — detection, diagnosis, and resolution of systemic faults: capacity exhaustion, isolation failures, latency degradation; escalation to platform operations when incidents cross party lines.
- **Settlement reporting** — the carrier's share of every hosted match, reconciled against hosting activity, exportable for finance.

**Architectural paradigms**

- **Real-time telemetry streaming** — slice health, capacity, and latency as continuous event streams feeding live operational views and automated alerting.
- **Declarative, desired-state orchestration** — operators declare policy (where, how much, what priority); the system continuously reconciles actual allocation to that intent and reports drift. Slices are provisioned on demand, attested, and destroyed on completion — ephemerality is the security model.
- **Policy-as-enforced-constraint for sovereignty** — jurisdictional rules evaluated at allocation time, not audited after the fact.
- **Carrier-grade observability and incident workflow** — the matching fabric is treated as network infrastructure: SLO-driven monitoring, structured incident lifecycle, post-incident review.

---

## AmisAd/ads

**Business objective.** Give the advertising side of the economy — agencies and the creators who supply them — a marketplace built on real demand: campaigns that land where need already exists, creative measured by whether it fit, and attribution that survives the death of tracking because it never needed tracking. One application, two role-scoped modes.

### Campaign administration mode (Marcel)

**Core user-facing functionality**

- **Campaign workspace** — objectives, promoted offers, flight dates, full lifecycle from draft to closed.
- **Budget management** — allocation, pacing, and spend tracked against match outcomes rather than impressions.
- **Aggregate targeting** — regions, need categories, and timing; never individuals, never segments built from personal data.
- **Attribution and credit reporting** — a clear, auditable trail of matches and closings each campaign contributed to, with the agency's earned credit — and no personal data attached.
- **Creative pipeline** — briefs issued to Creative Partners, assets received, reviewed, approved, and placed.

### Creative studio mode (Kai)

**Core user-facing functionality**

- **Service profile** — formats, styles, capacity, and terms the creator offers; the creator's own "offer catalog" for advertising services.
- **Demand queue** — open creative briefs from agencies and sellers, matched to the creator's declared services and capacity.
- **Production workspace** — drafts, versions, revision cycles, approvals, and final delivery.
- **Performance view** — how each delivered asset performed in the campaigns that used it, in aggregate terms.
- **Earnings view** — fees per engagement and settlement status.

**Architectural paradigms**

- **Multi-tenant workspace with role-scoped modes** — one platform, two coherent experiences, strict separation between agency tenants and creator accounts; the same marketplace mechanics that match buyers to sellers match creative demand to creative supply.
- **Aggregate-only analytics** — every report in the application is built from privacy-thresholded aggregates; there is no individual-level view to build.
- **Privacy-preserving attribution** — credit assignment computed inside the sealed matching fabric; only the credit outcome, never the underlying behavior, reaches the dashboard.
- **Asset pipeline with versioning and review workflow** — creative work as versioned artifacts moving through a brief → draft → review → approved → placed lifecycle; approved creative is delivered into sealed matching environments for rendering, so personalization happens where the need lives and nowhere else.

---

## AmisAd/insights

**Business objective.** Prove that insight never required surveillance. Turn the ecosystem's only legitimate analytical window — aggregate, anonymity-protected demand — into decisions: what sellers should stock, where campaigns should land, where matching capacity will be needed next, and where unmet demand signals growth.

**Core user-facing functionality**

- **Insights workbench** — aggregate demand explored by need category, geography, and time.
- **Demand outlooks** — published views consumed inside AmisAd/seller ("what nearby demand is rising") and AmisAd/ads ("where campaigns will land").
- **Ecosystem health metrics** — match rates, fulfillment quality, time-to-match, settlement timeliness.
- **Unmet demand surfacing** — needs going unmatched by category and region: the clearest signal of where the ecosystem should grow.

**Architectural paradigms**

- **Privacy-thresholded aggregation pipeline** — all inputs arrive as aggregates from the sealed matching fabric; results are released only above anonymity thresholds, enforced in the pipeline rather than by analyst discipline.
- **Streaming plus periodic aggregation** — near-real-time demand signals for operational views, longer-window analysis for outlooks and trends.
- **Publish-subscribe distribution** — insights are products published into the seller and ads applications, versioned and dated, rather than ad-hoc queries against raw data (there is no raw data to query).

---

## AmisAd/platform

**Business objective.** Keep the marketplace worthy of the trust every other application spends: participants verified, settlements correct and punctual, disputes resolved fairly — at first line by zero-knowledge support, at last line by platform stewardship — abuse detected without surveillance, and cross-party incidents owned end to end. One application, two role-scoped modes.

### Operations mode (Priya)

**Core user-facing functionality**

- **Operations console** — marketplace health at a glance: match volumes, settlement flows, exception queues, incident status.
- **Participant registry** — onboarding and verification of sellers, agencies, creative partners, carriers, integration partners, and delegates; standing, history, and status for each.
- **Settlement oversight** — the split of every match across seller, network, platform, and ad partners: computation, execution, exceptions, and reconciliation.
- **Trust and safety** — fraud and abuse detection operating exclusively on operational metadata (match rates, settlement anomalies, complaint patterns) — never on match content, which the platform cannot see by design.
- **Dispute desk** — contested matches, failed fulfillments, and settlement disagreements escalated beyond first-line support, worked to resolution with all parties.
- **Policy administration** — rules of participation, category standards, suspension and appeal, with an enforcement record.

### Support desk mode (Sam)

**Core user-facing functionality**

- **Case queue** — billing anomalies, delivery disputes, fulfillment failures, and settlement disagreements, triaged with their operational metadata attached.
- **Zero-knowledge case handling** — mediation from order states, timestamps, settlement entries, and delivery confirmations; buyer identity and need content are structurally absent from the toolset.
- **Consented-disclosure requests** — when metadata cannot resolve a case: a request to the data owner, minimal in scope, time-boxed, immutably logged, delivering only what was granted and expiring automatically.
- **Settlement adjustment proposals** — refunds, compensating entries, and released holds drafted in the case and executed on the settlement ledger, visible to both parties.
- **Resolution records** — outcome, rationale, and evidence trail for every closed case; escalation of policy questions to operations mode.

**Architectural paradigms**

- **Administrative control plane** — a privileged, heavily audited application: every operator and support action logged, least-privilege by role, no path from operations or support tooling into match content.
- **Zero-knowledge mediation workflow** — a tiered evidence model built into the toolset: operational metadata by default; anything beyond it requires an explicit disclosure grant from the data owner, delivered read-only, logged in the Consent Ledger, and expiring on schedule. Snooping is impossible, not just forbidden.
- **Append-only settlement ledger with compensating entries** — every match outcome and its value split recorded immutably; balances derived, never edited; disputes resolve as compensating adjustments that reference their case, never as changes to history.
- **Anomaly detection on metadata** — statistical and pattern-based detection over operational signals, explicitly designed to function without individual behavioral data.
- **Case-management workflow** — disputes and incidents as structured cases with parties, evidence, deadlines, and outcomes.

---

## AmisAd/audit

**Business objective.** Make the privacy promise bankable. "Nothing about the buyer leaves" is the entire foundation of the ecosystem; this application exists so an independent auditor can verify it with evidence — repeatably, jurisdiction by jurisdiction — and so regulators can say yes on the record.

**Core user-facing functionality**

- **Attestation ledger access** — read-only, tamper-evident evidence of every sealed environment's lifecycle: created, attested, executed, destroyed.
- **Residency verification** — evidence that each match ran inside the jurisdiction its rules required.
- **Consent audit** — verification that participation was informed, current, and revocable — and that revocation was honored. Covers all three grant types: participation consent, delegation mandates, and mediation disclosure grants.
- **Certification runs** — recurring, structured compliance assessments producing findings and certificates.
- **Investigation workspace** — evidence trails assembled for specific incidents or complaints, with findings binding on the platform.
- **Regulator-facing reporting** — jurisdiction-scoped reports and public summaries.

**Architectural paradigms**

- **Verifiable, append-only evidence log** — attestation records written once at the moment of the event by the matching fabric itself, cryptographically chained so tampering is evident, verifiable without trusting the platform's word.
- **Strict read-only isolation** — the audit application can prove what happened but can alter nothing and see no personal data; independence is architectural, not contractual.
- **Evidence-first reporting** — every finding links to the underlying records; certification is a reproducible computation over evidence, not an attestation of good intentions.

---

## AmisAd/connect

**Business objective.** Let the systems sellers already run — ERPs, inventory management, CRMs, points of sale — become first-class, safely bounded actors in the ecosystem. Sellers keep their systems of record; integration partners build against stable contracts; matching always reflects external truth. And the integration surface, by construction, can never touch a buyer.

**Core user-facing functionality**

- **Developer workspace** — versioned contract documentation, integration lifecycle management, and schema mapping between external models and AmisAd's offer, inventory, and order structures.
- **Sandbox tenants** — synthetic-data environments that behave like production, where a connector is built and certified before any live order depends on it.
- **Credential management** — issuance, scoping, rotation, and revocation of integration credentials, per tenant and per capability; the seller's grant defines the ceiling, and the partner can request less, never more.
- **Connector health** — sync status, event-delivery monitoring, failure alerts, and replay of missed or failed deliveries.
- **Order-lifecycle webhooks** — subscriptions that carry order state transitions back into the seller's systems so both sides agree on every order, without polling.
- **Partner onboarding** — identity and standing verification through the platform's participant registry before any production access exists.

**Architectural paradigms**

- **Contract-first, versioned API surface behind a gateway** — published contracts with explicit versioning and deprecation windows; partners build against the contract, not the implementation.
- **Least-privilege workload identity** — connectors authenticate as non-human actors with credentials scoped to specific tenants and capabilities, rotated on schedule, dying instantly on revocation. A partner sees exactly the tenants that granted it access, and nothing else exists as far as it can tell.
- **Event-driven synchronization with idempotent replay** — inbound inventory and catalog deltas and outbound order events delivered as ordered, replayable streams; a connector that was down for an hour converges to the same state as one that never blinked.
- **Sandbox-first promotion path** — the same contracts, mechanically verified in a synthetic tenant, gate promotion to production.
- **Supply-side-only by construction** — the privacy constraint as architecture: no buyer identity, need content, or match detail appears in any contract, so no integration, however privileged, can leak what it never receives.

---

## Shared Platform Foundations

Four capabilities sit beneath the applications. They are system components, not user-facing products; every application above consumes them.

### Private Matching Fabric
The sealed execution environments where a buyer's need meets sellers' offers. Environments are **ephemeral** (created per match, destroyed on completion), **attested** (their isolation is provable, feeding the audit evidence log), and **located by sovereignty rules** (on the buyer's device or at the network edge within jurisdiction). Offers and creative travel in; match results, settlement records, and threshold-protected aggregates travel out; the need itself never does. For delegated needs, the fabric enforces the mandate at match time — category scope, budget cap, closing authority — and stamps the match record with delegate attribution (actor, principal, mandate) for settlement and audit. Hosted on carrier infrastructure administered through AmisAd/resource.

### Identity & Verification
Network-anchored proof that every participant is real — without behavioral profiling. Four actor classes: **people** (subscriber-anchored: a carrier knows a real subscriber from a fake better than any browser), **organizations** (sellers, agencies, carriers — business verification at onboarding), **delegates** (verified people bound to a principal through a mandate), and **workloads** (integration connectors — non-human credentials, scoped and rotated, attributable to a verified partner). Surfaced through AmisAd/platform onboarding and AmisAd/connect credentialing; consumed by every application.

### Consent Ledger
The authoritative, revocable record of every grant of authority over personal participation. Three grant types: **participation consent** (what matching and aggregate contribution the buyer permits, with the standing right to withdraw), **delegation mandates** (principal → delegate: categories, caps, closing authority, expiry, instant revocation), and **disclosure grants** (data owner → support case: minimal scope, time-boxed, single-purpose). All three are enforced at execution time by the fabric and the platform — not checked after the fact — and every grant, use, and revocation is immutably recorded and auditable through AmisAd/audit.

### Settlement & Attribution Ledger
The append-only record of every match outcome and its value distribution — seller revenue, network share, platform fee, ad-partner credit — plus the attribution trail of who contributed to the match, including delegate attribution when a mandate was in play. Disputes resolve as **compensating entries** that reference their support case; history is never edited. One ledger, five views: seller payments (AmisAd/seller), carrier earnings (AmisAd/resource), agency and creator credit (AmisAd/ads), platform oversight and adjustments (AmisAd/platform), and audit evidence (AmisAd/audit).

---

## Workflow Alignment Matrix

Every persona workflow from [personas.md](personas.md) traced to the capability that serves it:

| Persona workflow | Application capability |
|------------------|------------------------|
| Maya states a need with constraints | AmisAd/buyer — needs and wants list |
| Maya's need is matched without leaving her side | AmisAd/buyer — private matching, on the Private Matching Fabric |
| Maya lets routine purchases close automatically | AmisAd/buyer — closing policies (local policy engine) |
| Maya books a fitting with one tap | AmisAd/buyer — offer shortlist and decisions |
| Maya tracks the gift to the couple's door | AmisAd/buyer — fulfillment tracking |
| Maya pauses her participation | AmisAd/buyer — consent controls, enforced via Consent Ledger |
| Maya grants Pat a scoped mandate | AmisAd/buyer — consent and mandate controls (Consent Ledger: delegation mandate) |
| Maya reviews everything done in her name | AmisAd/buyer — delegate activity trail |
| Elena posts her summer collection and terms | AmisAd/seller — offer catalog, terms and standing deals |
| Elena declares neighborhoods served and fitting slots | AmisAd/seller — reach definition, inventory and availability |
| Elena tracks orders, provisioning, and payments | AmisAd/seller — order board and settlement view (Settlement Ledger) |
| Elena stocks for rising demand | AmisAd/seller — demand outlooks, published by AmisAd/insights |
| Elena authorizes a connector for her tenant | AmisAd/seller — integration grants, credentialed via AmisAd/connect |
| Tom allocates and prioritizes network slices | AmisAd/resource — dynamic slice allocation (desired-state orchestration) |
| Tom keeps matches inside the regulatory perimeter | AmisAd/resource — sovereignty boundary management |
| Tom resolves a systemic isolation fault | AmisAd/resource — incident management; escalates to AmisAd/platform |
| Tom reconciles the carrier's match revenue | AmisAd/resource — settlement reporting (Settlement Ledger) |
| Marcel plans budgets and aggregate targeting | AmisAd/ads — campaign workspace, budget management |
| Marcel places spend where demand lives | AmisAd/ads — aggregate demand views from AmisAd/insights |
| Marcel claims credit for every match | AmisAd/ads — attribution reporting (Settlement & Attribution Ledger) |
| Marcel commissions creative | AmisAd/ads — creative pipeline (campaign mode → studio mode) |
| Kai tracks incoming creative demand | AmisAd/ads — demand queue (creative studio) |
| Kai delivers and revises assets | AmisAd/ads — production workspace |
| Kai proves the work performed | AmisAd/ads — performance view (aggregate-only) |
| Priya verifies a new seller, partner, or delegate | AmisAd/platform — participant registry, with Identity & Verification |
| Priya oversees the four-way settlement split | AmisAd/platform — settlement oversight |
| Priya investigates a fraud pattern | AmisAd/platform — trust and safety (metadata-only anomaly detection) |
| Priya resolves an escalated cross-party dispute | AmisAd/platform — dispute desk (operations mode) |
| Ingrid verifies vaults were sealed and destroyed | AmisAd/audit — attestation ledger access |
| Ingrid audits mandates and disclosure grants | AmisAd/audit — consent audit (all three grant types) |
| Ingrid certifies a jurisdiction | AmisAd/audit — certification runs, regulator-facing reporting |
| Dana maps rising demand by neighborhood | AmisAd/insights — insights workbench |
| Dana flags unmet demand as a growth signal | AmisAd/insights — unmet demand surfacing |
| Alex builds and certifies a connector in sandbox | AmisAd/connect — sandbox tenants, developer workspace |
| Alex keeps inventory truth synced | AmisAd/connect — event-driven sync into AmisAd/seller inventory |
| Alex receives order events into the ERP | AmisAd/connect — order-lifecycle webhooks |
| Alex rotates and scopes credentials | AmisAd/connect — credential management (workload identity) |
| Sam mediates a dispute on metadata alone | AmisAd/platform — zero-knowledge case handling (support desk) |
| Sam requests a minimal, consented disclosure | AmisAd/platform — consented-disclosure requests (Consent Ledger: disclosure grant) |
| Sam posts a refund as a compensating entry | AmisAd/platform — settlement adjustment proposals (Settlement Ledger) |
| Pat accepts a mandate and its boundaries | AmisAd/buyer — delegate mode, mandate view |
| Pat procures within scope and cap | AmisAd/buyer — delegated needs; mandate enforced by the Private Matching Fabric |
| Pat routes an over-cap closing for approval | AmisAd/buyer — approval handoffs (delegate → principal) |

No persona workflow lacks a serving capability, and no application capability exists without a persona who needs it. [scenarios.md](scenarios.md) exercises every row end to end.

---

LICENSEURI https://yuruna.link/license

Copyright (c) 2026 alius-git
