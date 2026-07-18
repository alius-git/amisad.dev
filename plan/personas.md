# AmisAd Personas

**Companion documents:** [applications.md](applications.md) — the application ecosystem these personas inhabit · [scenarios.md](scenarios.md) — the end-to-end verification sequences that exercise them.

AmisAd matches what a buyer needs with sellers who have it — in complete privacy. A buyer states a need once, in their own words; matching happens on their device or in a sealed slice of the network nearby; only offers that fit come back. Nothing about the buyer leaves. The value loop closes with everyone compensated: **buyer served, seller found, network rewarded, platform credited** — and not one secret spent.

This document defines the people in that loop. Every workflow named here maps to a capability in [applications.md](applications.md); the mapping table at the end makes the alignment explicit.

---

## Persona Roster

| # | Persona | Role | Primary application |
|---|---------|------|---------------------|
| 1 | Maya | The Buyer | AmisAd/buyer |
| 2 | Elena | The Seller | AmisAd/seller |
| 3 | Tom | The Telco Administrator | AmisAd/resource |
| 4 | Marcel | The Ad Agency Administrator | AmisAd/ads (campaign administration) |
| 5 | Kai | The Creative Partner (Content Creator) | AmisAd/ads (creative studio) |
| 6 | Priya | The Platform Operator | AmisAd/platform |
| 7 | Ingrid | The Trust Auditor | AmisAd/audit |
| 8 | Dana | The Demand Analyst | AmisAd/insights |
| 9 | Alex | The Integration Partner | AmisAd/connect |
| 10 | Sam | The Support Agent | AmisAd/platform (support desk) |
| 11 | Pat | The Buyer-Side Delegate | AmisAd/buyer (delegate mode) |

Personas 1–5 were defined by the founding product narrative. Personas 6–8 close operational gaps identified in the end-to-end review. Personas 9–11 are the formerly deferred edge-case roles, promoted to day-one scope so the system handles **enterprise integration, zero-knowledge support, and delegated authority** from the foundation up; see [Lifecycle Gap Analysis](#lifecycle-gap-analysis).

---

## 1. Maya — The Buyer

**Application:** AmisAd/buyer

**Who she is.** A private individual with real, time-bound needs — a wedding gift delivered to another city on budget and on time; a dress with a fitting nearby before she travels. She is done choosing between ads that don't know her and ads that know her too well.

**Core motivations**

- Get what she needs without hunting — and without being hunted afterward.
- Keep her life private, absolutely: nothing about her shared with anyone, ever.
- Stay in control: budget, timing, place, and taste are her terms, stated once.
- Hear silence when she needs nothing. No banners, no retargeting, no "gift ideas in October."

**Responsibilities within the ecosystem**

- Express needs and wants clearly: constraints, budget, deadline, location, preferences.
- Decide the closing policy per need — let routine purchases close automatically, or keep the final say.
- Review the shortlist of fitting offers and act on the ones she chooses.
- Track fulfillment of what she committed to: deliveries, appointments, confirmations.
- Manage her own consent: what participation means, and the right to withdraw it.
- Grant, scope, and revoke delegation mandates when someone acts on her behalf (see Pat).

**Primary interaction points**

- The private needs list — "my needs and wants" — where every request begins and is managed.
- The offer shortlist: only matches that satisfy every stated constraint.
- One-tap actions: book the fitting, accept the offer, confirm the delivery.
- Fulfillment tracking from commitment to completion.
- Consent and mandate controls: participation, delegation grants, and the activity trail of anyone acting for her.
- Quiet-by-default notifications: she hears from AmisAd only when something fits.

**Success looks like.** She states two needs, puts her phone away, and gets on with her life. By evening: a gift already on its way, three dresses that meet every wish, a fitting booked Thursday — and no trace of her anywhere.

---

## 2. Elena — The Seller

**Application:** AmisAd/seller

**Who she is.** Owner of a small dress atelier. She knows cut, fabric, and fit; what she never learned to love is paying for clicks from people three time zones away who were never going to walk into her shop.

**Core motivations**

- Meet real intent, not audiences: every match is a need her offer actually fills.
- Compete on what she offers, not on who can outbid giants for indifferent attention.
- Never touch anyone's data — no lists, no tracking, nothing to secure or disclose.
- See clearly what is sold, what is owed, and what is on its way.

**Responsibilities within the ecosystem**

- Define products and services in her own words: what she offers, and what makes it distinctive (same-week fittings, in person).
- Manage inventory and availability so matches reflect what she can actually deliver.
- Declare reach: regions served, delivery ranges, in-person capacity — so she only meets buyers she can serve.
- Set terms: prices, timing, standing deals that close automatically, or every sale a conversation.
- Track orders end to end and monitor provisioning and payment statuses.
- Authorize (and revoke) integration partners who connect her business systems (see Alex).

**Primary interaction points**

- The offer catalog: products, services, terms, and reach, kept current — by hand or by connected systems.
- Match notifications: a real need her offer fills, with exactly the context she requires — and nothing about who the buyer is.
- The order board: commitments, fulfillment steps, provisioning states.
- Payment and settlement view: what each match earned and when it settles.

**Success looks like.** A match arrives: someone nearby needs a midi dress with sleeves, anything but dusty blue, fitting before Friday. She has four dresses that qualify and an open slot Thursday. On Thursday a customer walks in — and the dress fits.

---

## 3. Tom — The Telco Administrator

**Application:** AmisAd/resource

**Who he is.** A network operations lead at a carrier. His network has carried people's calls and messages for decades; now it hosts their wishes — in isolated slices, close to the customer, inside the country, under its laws. He makes that hosting real, reliable, and profitable.

**Core motivations**

- Turn infrastructure the carrier already owns into recurring revenue — a share of every match.
- Keep the sovereignty promise operational: matches never leave the regulatory perimeter he administers.
- Run the platform's most sensitive workloads at carrier-grade reliability, because trust is the entire product.
- Prove that compliance is a moat, not a burden.

**Responsibilities within the ecosystem**

- Manage the network infrastructure that hosts matching: edge compute capacity, connectivity, isolation guarantees.
- Handle dynamic allocation of network slices — sealed, ephemeral spaces that exist for a match and are gone when it is done.
- Enforce residency and processing boundaries so every match runs where regulation says it must.
- Detect and resolve systemic incidents: capacity exhaustion, isolation faults, degraded match latency, slice failures.
- Monitor the carrier's earnings from hosted matches and reconcile them against hosting activity.

**Primary interaction points**

- The resource control plane: live view of slices, capacity, and match-hosting health across the network.
- Allocation policies: where slices may run, how much capacity each region commits, what gets priority.
- The incident queue: detection, diagnosis, resolution, and escalation of systemic faults.
- Settlement reporting: the network's share per match, reconciled and auditable.

**Success looks like.** When Maya asks for the dress, the match runs in an isolated slice near her, inside her country — allocated in milliseconds, destroyed on completion, revenue booked — and Tom's dashboards show green across the region.

---

## 4. Marcel — The Ad Agency Administrator

**Application:** AmisAd/ads — campaign administration mode

**Who he is.** A campaign lead at an ad agency. His craft was never surveillance — it was knowing what people want and saying it beautifully. AmisAd gives that craft a marketplace where the want is already real, and measures him on the only number that ever mattered: did it fit?

**Core motivations**

- Run campaigns that reach real needs instead of demographic guesses.
- Keep full credit for every match — attribution that survives the death of tracking, because it never needed tracking.
- Hold no one's secrets: campaigns with nothing to disclose, because nothing was taken.
- Put budgets where demand actually lives, seen only in aggregate.

**Responsibilities within the ecosystem**

- Plan and administer campaigns on behalf of sellers: objectives, offers promoted, duration.
- Manage budgets: allocation, pacing, spend tracking against match outcomes.
- Define targeting in aggregate terms — regions, need categories, timing — never individuals.
- Monitor campaign performance: matches produced, closings, credit earned per campaign.
- Commission creative work from Creative Partners and place it into campaigns.

**Primary interaction points**

- Campaign workspace: setup, budget controls, aggregate targeting, lifecycle management.
- Aggregate demand views (fed by AmisAd/insights): what neighborhoods need, so campaigns land where demand lives.
- Attribution and credit reporting: a clear trail of what each campaign earned, with no personal data attached.
- Creative pipeline: briefs out to Creative Partners, assets back in, approval and placement.

**Success looks like.** A campaign closes real sales in the neighborhoods that needed it, the credit trail shows exactly what his agency earned per match — and there is nothing to disclose, because nothing was taken.

---

## 5. Kai — The Creative Partner (Content Creator)

**Application:** AmisAd/ads — creative studio mode

**Who they are.** An independent content creator — art, video, copy — who produces creative assets for sellers and agencies. Kai is, in effect, a **seller of advertising services**: their inventory is talent and turnaround, their orders are creative briefs, their fulfillment is the delivered asset.

**Core motivations**

- A steady stream of real creative demand instead of speculative pitching.
- Clear briefs with clear terms: scope, deadline, price, usage rights.
- Proof that the work performs: which assets carried matches to a close.
- Recognition and repeat business built on measured results, not portfolio theater.

**Responsibilities within the ecosystem**

- Maintain a profile of creative services offered: formats, styles, capacity, terms.
- Track incoming creative demands — briefs from agencies and directly from sellers — and accept the ones that fit.
- Produce and deliver assets: art, video, copy, tuned to the offer and the medium.
- Manage revisions, approvals, and handoff into campaigns.
- Monitor the performance of delivered assets and the payment status of delivered work.

**Primary interaction points**

- The demand queue: open briefs matched to Kai's declared services and capacity.
- The production workspace: drafts, versions, review cycles, final delivery.
- Performance view: how each delivered asset performed in the campaigns that used it.
- Earnings view: fees per engagement, settlement status.

**Success looks like.** A brief arrives that fits Kai's style and calendar, the asset ships on time, the campaign closes matches — and the performance view proves it, bringing the next brief with it.

---

## 6. Priya — The Platform Operator

**Application:** AmisAd/platform

**Who she is.** An operations lead at AmisAd itself. Four parties profit from every match; Priya makes sure the machinery they share stays healthy, honest, and fair. She is the steward of the marketplace nobody else can see into — precisely because nobody can see into it.

**Core motivations**

- Keep the ecosystem trustworthy: every participant verified, every settlement correct, every dispute resolved.
- Detect abuse without surveillance — the platform must police itself using only the metadata it legitimately holds.
- Keep the loop running: when an incident spans buyer, seller, carrier, and agency, someone must own the whole thread.

**Responsibilities within the ecosystem**

- Onboard and verify participants: real sellers, real agencies, real creative partners, real carriers — and now real integration partners and delegates.
- Oversee settlement: the split of every match among seller, network, platform, and ad partners — computed correctly, paid on time.
- Operate trust and safety: fraud and abuse detection on operational metadata, never on match content.
- Coordinate cross-party incidents that no single participant can resolve alone.
- Administer platform policy: category rules, participation standards, suspension and appeal.
- Supervise the support function: policy actions and precedent-setting resolutions escalated by Support Agents (see Sam).

**Primary interaction points**

- The operations console: marketplace health, match volumes, settlement flows, exception queues.
- Participant registry: verification status, standing, history of every seller, agency, creator, carrier, integration partner, and delegate.
- The dispute desk: contested matches, failed fulfillments, settlement disagreements escalated beyond first-line support.
- Policy administration: rules of participation and their enforcement record.

**Success looks like.** The marketplace runs and nobody notices her — settlements land, disputes close quickly and fairly, bad actors never gain a foothold, and the privacy promise is never bent to make operations easier.

---

## 7. Ingrid — The Trust Auditor

**Application:** AmisAd/audit

**Who she is.** An independent auditor — working for a certification body or regulator — whose job is to verify AmisAd's central claim: *nothing about the buyer leaves. Not to the seller. Not to anyone.* A promise this absolute is worthless unverified; Ingrid is how it becomes bankable.

**Core motivations**

- Verify, independently and repeatably, that sealed matching environments leak nothing — not even to AmisAd.
- Give regulators evidence, not assurances: residency honored, consent respected, isolation intact.
- Protect the ecosystem's license to operate; privacy-first ventures die on the first broken promise.

**Responsibilities within the ecosystem**

- Examine attestation evidence that matching environments were isolated, ephemeral, and destroyed on completion.
- Verify that data residency and processing boundaries were honored for every jurisdiction in scope.
- Audit consent records: participation was informed, current, and revocable — and revocation was honored. This now includes delegation mandates and mediation disclosure grants.
- Certify compliance on a recurring cycle and produce reports for regulators and the public.
- Investigate suspected breaches of the privacy model, with findings binding on the platform.

**Primary interaction points**

- The attestation ledger: tamper-evident evidence of every sealed environment's lifecycle, in read-only form.
- Compliance reporting: certification runs, jurisdiction-by-jurisdiction findings, public summaries.
- Investigation workspace: evidence trails for specific incidents or complaints.

**Success looks like.** Certification is routine because the evidence is complete; regulators cite her reports when they say yes; and "compliant by design" is a finding on the record, not a marketing line.

---

## 8. Dana — The Demand Analyst

**Application:** AmisAd/insights

**Who they are.** An analyst serving sellers, agencies, and the platform itself. In a system where no individual is ever visible, Dana works the one window that exists: aggregate, anonymity-protected demand. They turn "what neighborhoods need" into decisions about inventory, campaigns, and capacity.

**Core motivations**

- Extract real market signal from aggregates alone — proving surveillance was never necessary for insight.
- Help sellers stock what will be needed and agencies spend where demand lives.
- Help the platform and carriers anticipate load: where matching capacity will be needed next.

**Responsibilities within the ecosystem**

- Analyze aggregate demand: what need categories are rising, where, and when — always above anonymity thresholds.
- Publish demand outlooks to sellers (what to stock, where to expand reach) and agencies (where campaigns will land).
- Track ecosystem health metrics: match rates, fulfillment quality, unmet demand by category and region.
- Flag unmet demand — needs going unmatched — as the ecosystem's clearest growth signal.

**Primary interaction points**

- The insights workbench: aggregate demand by category, geography, and time.
- Published dashboards and outlooks consumed inside AmisAd/seller and AmisAd/ads.
- Ecosystem health reporting shared with the Platform Operator and carriers.

**Success looks like.** Elena stocks for August because Dana saw summer-dress demand rising three neighborhoods over; Marcel's campaign lands where the need already was; and no individual was visible at any point in the analysis.

---

## 9. Alex — The Integration Partner *(promoted from deferred — see gap analysis)*

**Application:** AmisAd/connect

**Who they are.** A third-party developer or enterprise IT engineer connecting external business systems — ERPs, inventory management, CRMs, points of sale — to AmisAd on behalf of seller tenants. Alex's customers are sellers like Elena who outgrow hand-maintained catalogs; Alex's product is a connector that makes AmisAd reflect the seller's systems of record, automatically and safely.

**Core motivations**

- Build against stable, versioned contracts — integrations that survive platform evolution.
- Hold the least privilege that does the job: scoped access to exactly the tenants and capabilities granted, nothing more.
- Keep the seller's existing systems authoritative: AmisAd mirrors the ERP's truth, never forks it.
- Prove the connector works in a sandbox before a single live order depends on it.

**Responsibilities within the ecosystem**

- Build and operate connectors that sync catalogs, inventory, availability, and pricing from external systems into AmisAd/seller tenants.
- Consume order-lifecycle events back into the seller's ERP or fulfillment system so both sides agree on every order's state.
- Manage integration credentials responsibly: request minimal scopes, rotate on schedule, revoke on offboarding.
- Monitor connector health — sync lag, failed deliveries, schema drift — and repair before sellers notice.
- Pass partner verification (identity and standing) before touching any production tenant.

**Primary interaction points**

- The developer workspace: versioned contract documentation, schema mappings, integration lifecycle.
- Sandbox tenants with synthetic data: build and certify against realistic behavior with nothing real at stake.
- Credential management: issuance, scoping, rotation, and revocation per tenant and capability.
- Connector health dashboards: sync status, event delivery, replay of failures.

**Success looks like.** Elena's stockroom sells a dress at the counter; minutes later AmisAd stops matching it. An order closes on AmisAd; it appears in her ERP without anyone retyping it. Alex's connector did both — and could never have read a buyer's anything, because no such surface exists.

---

## 10. Sam — The Support Agent *(promoted from deferred — see gap analysis)*

**Application:** AmisAd/platform — support desk mode

**Who they are.** A first-line support and mediation agent handling the moments when the loop stumbles: a billing anomaly, a delivery that never arrived, a settlement both sides read differently. Sam works **zero-knowledge**: mediating from operational metadata alone, never seeing buyer identity or need content — unless the data's owner grants a minimal, time-boxed disclosure for exactly this case.

**Core motivations**

- Resolve disputes fairly and fast — without ever becoming the hole in the privacy promise.
- Make "support" and "surveillance" permanently different things: the toolset itself must make snooping impossible, not merely forbidden.
- Turn recurring anomalies into signals the platform can fix at the root.

**Responsibilities within the ecosystem**

- Triage incoming cases: billing anomalies, delivery disputes, fulfillment failures, settlement disagreements.
- Mediate between parties using operational metadata only: order states, timestamps, settlement entries, delivery confirmations.
- When metadata cannot resolve a case, request a **consented disclosure** from the data owner: minimal in scope, time-boxed, logged immutably, and visible to the auditor.
- Propose settlement adjustments — compensating entries, refunds, released holds — for execution through the settlement ledger.
- Escalate policy questions and precedent-setting cases to the Platform Operator; document every resolution.

**Primary interaction points**

- The support case queue: open disputes and anomalies with their metadata evidence attached.
- The consented-disclosure request flow: ask, receive only what was granted, watch it expire.
- Settlement adjustment proposals: drafted in the case, executed on the ledger, visible to both parties.
- Resolution records: outcome, rationale, and the evidence trail that supports both.

**Success looks like.** Maya's gift shows delivered but never arrived. Sam sees the carrier confirmation conflict, mediates a refund with Elena's agreement, posts the adjustment — and closes the case without ever learning who Maya is. Both parties accept the outcome; the auditor can replay every step.

---

## 11. Pat — The Buyer-Side Delegate *(promoted from deferred — see gap analysis)*

**Application:** AmisAd/buyer — delegate mode

**Who they are.** An authorized person acting on a buyer's behalf: a guardian managing needs for a parent, an assistant handling a principal's errands, a corporate proxy executing procurement for an organization. Pat holds no account-wide power — only an explicit **mandate** from the principal: which need categories, what budget cap, what closing authority, until when.

**Core motivations**

- Act efficiently for the principal without friction on every step — that is the point of delegation.
- Operate inside crisp boundaries: what the mandate allows is unambiguous, and so is what it doesn't.
- Keep the principal genuinely in charge: full visibility of every delegated action, instant revocation, no surprises.
- Carry no liability beyond the mandate: every action attributed to Pat *as delegate*, under a recorded grant.

**Responsibilities within the ecosystem**

- Accept and manage mandates: scope (need categories), limits (budget caps), authority (may close automatically, or propose for the principal's approval), and expiry.
- State and manage needs on the principal's behalf within the mandate — Maya's "needs and wants," executed by Pat.
- Respect approval boundaries: closings beyond the delegated authority route to the principal for confirmation.
- Keep the principal informed: the activity trail is the principal's window into everything done in their name.
- Hand mandates back cleanly on expiry or role change; request renewal explicitly, never assume it.

**Primary interaction points**

- The delegate workspace: one view per principal, strictly separated — Pat's own needs and each principal's never mix.
- The mandate view: exactly what is permitted, what remains of the budget cap, and when authority expires.
- Delegated needs and shortlists: stating needs, reviewing matches, closing within authority.
- Approval handoffs: proposed closings that await the principal's confirmation.

**Success looks like.** Maya grants Pat a three-month mandate for household procurement under a monthly cap. Pat keeps it all running — matched, closed, fulfilled — while Maya sees every action in her trail, confirms the one purchase above the cap, and revokes nothing because nothing ever exceeded what she granted.

---

## Lifecycle Gap Analysis

The five founding personas cover demand (Maya), supply (Elena, Kai), infrastructure (Tom), and campaign administration (Marcel). Two review passes completed the roster.

**Pass one — operational cycle.** Walking need → match → fulfillment → settlement → audit exposed three gaps, closed by personas 6–8:

1. **Nobody operated the marketplace itself.** Every match settles value across four parties, and disputes, fraud, and participant verification belong to no founding persona. **Priya (Platform Operator)** owns marketplace stewardship: onboarding, settlement oversight, trust and safety, cross-party incident coordination.
2. **Nobody verified the promise.** The entire ecosystem rests on a claim — nothing about the buyer leaves — that must be provable to regulators and the public, by someone independent of the platform. **Ingrid (Trust Auditor)** owns verification: attestation review, residency and consent audit, certification.
3. **Nobody turned aggregates into decisions.** The system's only legitimate analytical window — privacy-thresholded aggregate demand — had producers and consumers but no analyst. **Dana (Demand Analyst)** owns it: demand outlooks for sellers and agencies, health metrics for the platform, unmet demand as the growth signal.

**Pass two — trust boundaries.** Three roles initially deferred are now promoted to day-one scope (personas 9–11), because each one changes a **shared foundation contract**, and foundation contracts are cheap to design in and expensive to retrofit:

4. **Enterprise integration was assumed but unowned.** Sellers beyond a certain size will not hand-maintain catalogs; external systems must become first-class actors. **Alex (Integration Partner)** requires workload identity, scoped credentials, and versioned contracts in the Identity & Verification foundation — decisions that must precede the first API, not follow it.
5. **Support was absorbed into operations — and support is where privacy promises quietly die.** A support function bolted on later would inevitably demand "just a little" visibility. **Sam (Support Agent)** forces the zero-knowledge mediation model — metadata-first evidence and consented, time-boxed disclosure grants in the Consent Ledger — to exist from the start.
6. **Every buyer was assumed to act alone.** Guardianship, assistance, and corporate procurement are not edge cases; they are how much of the world buys. **Pat (Buyer-Side Delegate)** requires delegation mandates — scoped, capped, expiring, revocable — as a native Consent Ledger record, with delegate attribution running through matching, settlement, and audit.

**No roles remain deferred.** This roster is the complete day-one persona set; future additions (e.g., specialized regulator liaisons, franchise or multi-location seller managers) should be proposed against this baseline.

---

## Persona ↔ Application Map

| Persona | Primary application | Also touches |
|---------|--------------------|--------------|
| Maya — Buyer | AmisAd/buyer | Grants mandates and disclosure consents via the Consent Ledger |
| Elena — Seller | AmisAd/seller | Insights published from AmisAd/insights; grants tenant access via AmisAd/connect |
| Tom — Telco Administrator | AmisAd/resource | Settlement data from AmisAd/platform |
| Marcel — Ad Agency Administrator | AmisAd/ads (campaign administration) | Aggregate views from AmisAd/insights |
| Kai — Creative Partner | AmisAd/ads (creative studio) | — |
| Priya — Platform Operator | AmisAd/platform | Escalations from AmisAd/resource and the support desk; findings from AmisAd/audit |
| Ingrid — Trust Auditor | AmisAd/audit | Read-only evidence from platform foundations, including mandates and disclosure grants |
| Dana — Demand Analyst | AmisAd/insights | Publishes into AmisAd/seller and AmisAd/ads |
| Alex — Integration Partner | AmisAd/connect | Syncs into AmisAd/seller tenants under seller-granted scopes |
| Sam — Support Agent | AmisAd/platform (support desk) | Adjustments via the Settlement Ledger; disclosures via the Consent Ledger |
| Pat — Buyer-Side Delegate | AmisAd/buyer (delegate mode) | Acts under mandates recorded in the Consent Ledger |

Every workflow above maps to an application capability defined in [applications.md](applications.md); the alignment matrix there provides the workflow-level trace, and [scenarios.md](scenarios.md) proves each one end to end.
