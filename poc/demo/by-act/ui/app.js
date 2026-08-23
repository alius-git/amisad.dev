// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// AmisAd demo console. One dropdown switches the persona; each scenario
// panel lists its steps in demo order with the acting persona on each row --
// only the selected persona's buttons are live, which is what walks the
// operator through the switches. Every button is a real API call against the
// deployed topology, sent through serve-by-act.ps1's same-origin proxy
// (/api/core/<nodeport>/..., /api/edge-a/...). Request bodies mirror
// poc/demo.md and buyer-client, with demo- prefixed ids and demo-only
// categories so the walkthrough is deterministic on top of whatever durable
// state the amisad.end-to-end.yml run left behind (no snapshot restore
// needed mid-demo).

"use strict";

// --- personas -----------------------------------------------------------

const PERSONAS = {
  maya:   { name: "Maya",   role: "The Buyer",                  app: "AmisAd/buyer",
            blurb: "States a need once, in her own words. Nothing about her leaves -- not to the seller, not to anyone." },
  elena:  { name: "Elena",  role: "The Seller",                 app: "AmisAd/seller",
            blurb: "A dress atelier meeting real intent, not audiences. She never touches anyone's data." },
  tom:    { name: "Tom",    role: "The Telco Administrator",    app: "AmisAd/resource",
            blurb: "Runs the sealed slices close to the buyer, inside the law -- and books the network's share." },
  marcel: { name: "Marcel", role: "The Ad Agency Administrator", app: "AmisAd/ads",
            blurb: "Campaigns that reach real needs, measured on the only number that matters: did it fit?" },
  kai:    { name: "Kai",    role: "The Creative Partner",       app: "AmisAd/ads (studio)",
            blurb: "Sells creative talent: briefs in, assets out, and proof the work performed." },
  priya:  { name: "Priya",  role: "The Platform Operator",      app: "AmisAd/platform",
            blurb: "Steward of the marketplace nobody can see into -- precisely because nobody can see into it." },
  ingrid: { name: "Ingrid", role: "The Trust Auditor",          app: "AmisAd/audit",
            blurb: "Independently verifies the central claim: nothing about the buyer leaves. Evidence, not assurances." },
  dana:   { name: "Dana",   role: "The Demand Analyst",         app: "AmisAd/insights",
            blurb: "Works the one window that exists: aggregate demand above the anonymity threshold." },
  alex:   { name: "Alex",   role: "The Integration Partner",    app: "AmisAd/connect",
            blurb: "Connects the seller's ERP so external truth governs matching -- under scopes that are a hard ceiling." },
  sam:    { name: "Sam",    role: "The Support Agent",          app: "AmisAd/platform (support)",
            blurb: "Mediates from metadata alone. Support and surveillance stay permanently different things." },
  pat:    { name: "Pat",    role: "The Buyer-Side Delegate",    app: "AmisAd/buyer (delegate)",
            blurb: "Acts for Maya under a scoped, capped, expiring mandate -- every action on her trail." },
};

// --- state --------------------------------------------------------------

const load = (k, d) => { try { return JSON.parse(localStorage.getItem(k)) ?? d; } catch { return d; } };
const state = load("amisad-demo-state", {});
const done = load("amisad-demo-done", {});
const save = () => {
  localStorage.setItem("amisad-demo-state", JSON.stringify(state));
  localStorage.setItem("amisad-demo-done", JSON.stringify(done));
};

const NOTEBOOK = {
  s001_handle: "s001 handle", s001_match: "s001 match",
  s002_handle: "s002 handle", s002_match: "s002 match",
  s003_handle: "s003 handle",
  s005_campaign: "campaign", s005_asset: "asset", s005_handle: "s005 handle", s005_match: "s005 match",
  s006_held: "held handle",
  s007_partner: "partner", s007_cred: "credential", s007_match: "s007 match",
  s009_version: "outlook",
  s004_match: "s004 match", s004_envs: "aborted envs", s004_case: "ops case",
  s008_case: "support case", s008_expiry: "disclosure expiry",
};

let topo = { core: "", edgeA: "", edgeB: "" };
let currentPersona = "";

// --- plumbing -----------------------------------------------------------

function deepFind(node, key) {
  if (node === null || typeof node !== "object") return undefined;
  if (!Array.isArray(node) && key in node && typeof node[key] !== "object") return node[key];
  for (const v of Object.values(node)) {
    const hit = deepFind(v, key);
    if (hit !== undefined) return hit;
  }
  return undefined;
}
function deepFindAll(node, key, out = []) {
  if (node === null || typeof node !== "object") return out;
  if (!Array.isArray(node) && key in node && typeof node[key] !== "object") out.push(node[key]);
  for (const v of Object.values(node)) deepFindAll(v, key, out);
  return [...new Set(out)];
}

async function call(method, url, body) {
  const res = await fetch("/api/" + url, {
    method,
    headers: body !== undefined ? { "Content-Type": "application/json" } : undefined,
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let data;
  try { data = JSON.parse(text); } catch { data = text; }
  logLine(method, url, res.status);
  return { status: res.status, data };
}
const post = (url, body) => call("POST", url, body ?? {});
const get = (url) => call("GET", url);

// identity-mock token, minted fresh per step (matches buyer-client).
async function token(actor) {
  const r = await post("core/30084/v1/tokens", { actor, class: "person" });
  if (r.status !== 201 || !r.data.token) throw new Error("token mint failed (" + r.status + ")");
  return r.data.token;
}

// One result row per API call a step makes.
const mk = (label, r) => ({ label, status: r.status, data: r.data });

// The buyer's signup grants are a PRECONDITION of every need she submits: the
// coordinator's consent gate refuses POST /v1/needs with 403 "participation
// revoked" whenever the newest consent entry for her pseudonymous subject is a
// revoke. The consent ledger is durable PostgreSQL, so a revoke left behind by
// an earlier run (s003.silence's pause, s010.certification's corpus seeding)
// survives into the console and would 403 Maya's very first step. Each
// scenario script seeds the same grants with `buyer-client resume` before it
// asserts anything; this is the console's equivalent.
//
// Repair only what actually reads "revoked": an unconditional grant would
// prepend noise to the grant -> revoke -> re-grant history s003 puts on screen.
async function ensureBuyerConsents() {
  const st = await post("core/30080/v1/consents/state", { token: await token("maya") });
  if (st.status !== 200) return { ok: false, note: "consent state unavailable (" + st.status + ")" };
  const stale = ["participation", "contribution"].filter((g) => st.data[g] === "revoked");
  if (!stale.length) return { ok: true, note: "" };
  for (const grant of stale) {
    const r = await post("core/30080/v1/consents",
      { token: await token("maya"), grant_type: grant, action: "grant" });
    if (r.status !== 201) return { ok: false, note: "re-granting " + grant + " failed (" + r.status + ")" };
  }
  return { ok: true, note: "re-granted Maya's " + stale.join(" + ") + " (left revoked by an earlier run)" };
}

function offer(id, title, category, price, extra) {
  return Object.assign({
    offer_id: id, tenant: "elena-atelier", title, category,
    region: "region-a", price_cents: price, deliver_by_days: 10, auto_close: true,
  }, extra || {});
}

// --- the script: scenarios and steps ------------------------------------
// Order = demo order. `persona` is who clicks; `needs` lists notebook keys
// the step consumes (button disabled until captured); `refusal` marks steps
// whose PASS is a 4xx from the platform.

const ACTS = {
  I: "Act I -- The Buyer Loop",
  II: "Act II -- The Economy",
  III: "Act III -- Trust & Operations",
};

const SCENARIOS = [
  { id: "s001", act: "I", name: "s001.fulfillment -- The gift",
    tagline: "Maya's auto-close happy path: matched in a sealed slice, settled four ways, delivered -- and no trace of her anywhere." },
  { id: "s002", act: "I", name: "s002.fitting -- The dress",
    tagline: "Manual control: a shortlist that honors every constraint, nothing commits until she books." },
  { id: "s003", act: "I", name: "s003.silence -- The kill switch",
    tagline: "Pause participation and a perfect offer produces nothing; commitments made before still complete." },
  { id: "s005", act: "II", name: "s005.attribution -- The campaign",
    tagline: "Advertising without surveillance: the boost happens inside the sealed environment; credit needs no tracking." },
  { id: "s006", act: "II", name: "s006.mandate -- The delegate",
    tagline: "Pat acts for Maya under a scoped, capped mandate; over-cap routes back to Maya." },
  { id: "s007", act: "II", name: "s007.inventory -- The stockroom",
    tagline: "Alex's connector makes the ERP the truth; a zeroed item silently leaves the matchable catalog." },
  { id: "s009", act: "II", name: "s009.suppression -- The forecast",
    tagline: "Dana publishes demand; anything below the anonymity threshold is indistinguishable from nothing." },
  { id: "s004", act: "III", name: "s004.failover -- The sovereign slice",
    tagline: "Policy pins the match to the compliant region; injected faults abort BEFORE the envelope opens." },
  { id: "s008", act: "III", name: "s008.mediation -- The dispute",
    tagline: "Sam refunds Maya's gift without ever learning who she is; access to the evidence expires." },
  { id: "s010", act: "III", name: "s010.certification -- The audit",
    tagline: "Ingrid certifies the very demo you just watched -- and catches a deliberate tamper." },
];

const STEPS = [
  // --- s001.fulfillment -------------------------------------------------
  { scenario: "s001", persona: "elena", label: "Publish the standing offer",
    explain: "Ceramic serving set, standing terms, closes automatically -- Elena's catalog, her words.",
    run: async () => [mk("publish offer", await post("core/30083/v1/offers",
      offer("demo-serving-set-01", "Ceramic serving set", "giftware", 11000)))] },
  { scenario: "s001", persona: "maya", label: "Submit the gift need",
    explain: "The need travels as an opaque envelope; only the sealed environment opens it. Note: no name, no address, nothing about Maya.",
    run: async () => [mk("submit need", await post("core/30080/v1/needs", {
      token: await token("maya"), jurisdiction: "region-a",
      envelope: JSON.stringify({ category: "giftware", budget_cents: 12000, region: "region-a",
        deadline_days: 14, auto_close: true,
        context: "Wedding gift from the couple's wish list, deliver to their city" }),
    }))],
    capture: (rs) => { state.s001_handle = deepFind(rs, "handle"); state.s001_match = deepFind(rs, "match_id"); } },
  { scenario: "s001", persona: "elena", label: "Ship it (provisioning)", needs: ["s001_match"],
    explain: "Elena's order board: a match that fits, an appointment-free delivery -- and no buyer identity anywhere on it.",
    run: async () => [mk("advance", await post("core/30083/v1/orders/advance",
      { match_id: state.s001_match, state: "provisioning" }))] },
  { scenario: "s001", persona: "elena", label: "Confirm fulfilled -> settled", needs: ["s001_match"],
    explain: "Fulfillment triggers the four-way settlement: seller, network, platform, ad partners.",
    run: async () => [mk("advance", await post("core/30083/v1/orders/advance",
      { match_id: state.s001_match, state: "fulfilled" }))] },
  { scenario: "s001", persona: "maya", label: "Check delivery", needs: ["s001_handle"],
    explain: "Maya's only surface: her handle. Status: delivered.",
    run: async () => [mk("order status", await get("core/30080/v1/orders/" + state.s001_handle))] },
  { scenario: "s001", persona: "maya", label: "Proof: the receipt is a hash chain",
    explain: "Both ledgers verify end to end -- the receipt survives restarts and cannot be quietly edited.",
    run: async () => [mk("ledger verify", await get("core/30081/v1/verify"))] },

  // --- s002.fitting -----------------------------------------------------
  { scenario: "s002", persona: "elena", label: "Publish the dress rack",
    explain: "Five dresses across two sellers -- one dusty blue, one missing attributes, one past deadline, one out of region.",
    run: async () => {
      const dress = (id, tenant, title, price, days, attrs, slots, region) => ({
        offer_id: id, tenant, title, category: "dresses", region: region || "region-a",
        price_cents: price, deliver_by_days: days, auto_close: false,
        attributes: attrs, fitting_slots: slots });
      const bodies = [
        dress("demo-linen-midi-04", "elena-atelier", "Linen midi dress", 18000, 3,
          ["midi", "sleeves", "warm-fabric"],
          [{ slot_id: "thu-1", day: "thursday", day_ordinal: 4 }, { slot_id: "sat-1", day: "saturday", day_ordinal: 6 }]),
        dress("demo-dusty-blue-02", "elena-atelier", "Dusty blue midi dress", 16000, 3,
          ["midi", "sleeves", "warm-fabric", "dusty-blue"], [{ slot_id: "thu-2", day: "thursday", day_ordinal: 4 }]),
        dress("demo-silk-slip-03", "elena-atelier", "Silk slip dress", 15000, 3,
          ["midi", "sleeveless"], [{ slot_id: "thu-3", day: "thursday", day_ordinal: 4 }]),
        dress("demo-wool-midi-07", "brisa-outlet", "Wool midi dress", 14000, 30,
          ["midi", "sleeves", "warm-fabric"], [{ slot_id: "wed-7", day: "wednesday", day_ordinal: 3 }]),
        dress("demo-linen-wrap-08", "brisa-outlet", "Linen wrap dress", 13000, 2,
          ["midi", "sleeves", "warm-fabric"], [{ slot_id: "thu-8", day: "thursday", day_ordinal: 4 }], "region-b"),
      ];
      const out = [];
      for (const b of bodies) out.push(mk(b.offer_id, await post("core/30083/v1/offers", b)));
      return out;
    } },
  { scenario: "s002", persona: "maya", label: "Ask for the shortlist",
    explain: "Manual policy: sleeves, warm fabric, anything but dusty blue, fitting before Friday. Only the one dress that fits everything comes back.",
    run: async () => [mk("submit manual need", await post("core/30080/v1/needs", {
      token: await token("maya"), jurisdiction: "region-a",
      envelope: JSON.stringify({ category: "dresses", budget_cents: 20000, region: "region-a",
        deadline_days: 4, auto_close: false,
        attributes: ["midi", "sleeves", "warm-fabric"], exclusions: ["dusty-blue"],
        fitting_before_ordinal: 5,
        context: "Midi dress with sleeves in a warm-weather fabric; fitting near the office before Friday" }),
    }))],
    capture: (rs) => { state.s002_handle = deepFind(rs, "handle"); } },
  { scenario: "s002", persona: "maya", label: "Book the Thursday fitting", needs: ["s002_handle"],
    explain: "Her explicit choice is the commitment -- the appointment is a slot id and a day, never a person.",
    run: async () => [mk("book", await post("core/30080/v1/bookings",
      { handle: state.s002_handle, offer_id: "demo-linen-midi-04", slot_id: "thu-1" }))],
    capture: (rs) => { state.s002_match = deepFind(rs, "match_id"); } },
  { scenario: "s002", persona: "maya", label: "Notifications: exactly two", needs: ["s002_handle"],
    explain: "Quiet by default -- the shortlist and the booking confirmation. Nothing else, ever.",
    run: async () => [mk("notifications", await get("core/30080/v1/notifications/" + state.s002_handle))] },
  { scenario: "s002", persona: "elena", label: "Fulfill the fitting order", needs: ["s002_match"], optional: true,
    explain: "Advancing to fulfilled settles the split exactly as in s001.",
    run: async () => [
      mk("provisioning", await post("core/30083/v1/orders/advance", { match_id: state.s002_match, state: "provisioning" })),
      mk("fulfilled", await post("core/30083/v1/orders/advance", { match_id: state.s002_match, state: "fulfilled" })),
    ] },

  // --- s003.silence -----------------------------------------------------
  { scenario: "s003", persona: "maya", label: "Sign up (consent grants)",
    explain: "Participation and contribution, granted on the consent ledger under a pseudonymous subject -- never a name.",
    run: async () => [
      mk("grant contribution", await post("core/30080/v1/consents",
        { token: await token("maya"), grant_type: "contribution", action: "grant" })),
      mk("grant participation", await post("core/30080/v1/consents",
        { token: await token("maya"), grant_type: "participation", action: "grant" })),
    ] },
  { scenario: "s003", persona: "maya", label: "Open a need nothing fits yet",
    explain: "A crystal decanter, modest budget. No offer fits -- the need stays open on the coordinator.",
    run: async () => [mk("open need", await post("core/30080/v1/needs", {
      token: await token("maya"), jurisdiction: "region-a",
      envelope: JSON.stringify({ category: "glassware", budget_cents: 9000, region: "region-a",
        deadline_days: 21, auto_close: true,
        context: "Crystal decanter for an anniversary, modest budget" }),
    }))],
    capture: (rs) => { state.s003_handle = deepFind(rs, "handle"); } },
  { scenario: "s003", persona: "maya", label: "Pause participation",
    explain: "One revocation on the consent ledger. From this instant the network is silent for Maya.",
    run: async () => [mk("revoke participation", await post("core/30080/v1/consents",
      { token: await token("maya"), grant_type: "participation", action: "revoke" }))] },
  { scenario: "s003", persona: "elena", label: "Publish a PERFECT decanter offer",
    explain: "Fits the open need on every axis. Publishing re-runs matching over open needs -- watch what does not happen.",
    run: async () => [mk("publish offer", await post("core/30083/v1/offers",
      offer("demo-crystal-decanter-09", "Crystal decanter", "glassware", 8500, { deliver_by_days: 5 })))] },
  { scenario: "s003", persona: "maya", label: "...silence", needs: ["s003_handle"],
    explain: "No environment, no match, no notification. The consent gate sits inside the matching cycle itself.",
    run: async () => [mk("notifications", await get("core/30080/v1/notifications/" + state.s003_handle))],
    check: (rs) => (Array.isArray(rs[0].data) && rs[0].data.length === 0)
      ? { ok: true, note: "Empty -- a perfect offer produced nothing." }
      : { ok: false, note: "Expected an empty notification list." } },
  { scenario: "s003", persona: "maya", label: "Resume -- served immediately",
    explain: "Re-granting brings the open needs back to life; the decanter matches now (look for \"rematched\").",
    run: async () => [
      mk("grant contribution", await post("core/30080/v1/consents",
        { token: await token("maya"), grant_type: "contribution", action: "grant" })),
      mk("grant participation", await post("core/30080/v1/consents",
        { token: await token("maya"), grant_type: "participation", action: "grant" })),
    ] },
  { scenario: "s003", persona: "maya", label: "Consent history: grant -> revoke -> re-grant",
    explain: "The full history on the verifying consent chain -- revocation is recorded, honored, and auditable.",
    run: async () => [mk("consent state", await post("core/30080/v1/consents/state",
      { token: await token("maya") }))] },

  // --- s005.attribution -------------------------------------------------
  { scenario: "s005", persona: "marcel", label: "Create the campaign",
    explain: "Aggregate targeting only: a region and a need category. 2000c committed per match on top of the price.",
    run: async () => [mk("create campaign", await post("core/30087/v1/campaigns",
      { tenant: "elena-atelier", region: "region-a", category: "tableware",
        ad_cents_per_match: 2000, budget_cents: 10000 }))],
    capture: (rs) => { state.s005_campaign = deepFind(rs, "campaign_id"); } },
  { scenario: "s005", persona: "marcel", label: "Send the creative brief", needs: ["s005_campaign"],
    explain: "The brief goes out to Creative Partners with scope and terms.",
    run: async () => [mk("brief", await post("core/30087/v1/briefs", { campaign_id: state.s005_campaign }))] },
  { scenario: "s005", persona: "kai", label: "Check the demand queue",
    explain: "Kai's inventory is talent and turnaround; the brief is a real order, not a pitch.",
    run: async () => [mk("briefs", await get("core/30087/v1/briefs"))] },
  { scenario: "s005", persona: "kai", label: "Deliver the asset", needs: ["s005_campaign"],
    explain: "\"summer-hero-01\" ships, approved and ready for placement.",
    run: async () => [mk("asset", await post("core/30087/v1/assets",
      { campaign_id: state.s005_campaign, creator: "kai", creative: "summer-hero-01" }))],
    capture: (rs) => { state.s005_asset = deepFind(rs, "asset_id"); } },
  { scenario: "s005", persona: "marcel", label: "Activate the campaign", needs: ["s005_campaign", "s005_asset"],
    explain: "Live in region-a for tableware needs. No individual was targetable at any point.",
    run: async () => [mk("activate", await post("core/30087/v1/campaigns/activate",
      { campaign_id: state.s005_campaign, asset_id: state.s005_asset }))] },
  { scenario: "s005", persona: "elena", label: "Publish the summer offer",
    explain: "The offer the campaign will boost -- Elena's price is untouched by the ad economics.",
    run: async () => [mk("publish offer", await post("core/30083/v1/offers",
      offer("demo-summer-set-02", "Summer entertaining set", "tableware", 11000,
        { deliver_by_days: 14, auto_close: false })))] },
  { scenario: "s005", persona: "maya", label: "State the summer need",
    explain: "The boost happens INSIDE the sealed environment -- the creative renders in the shortlist, never outside.",
    run: async () => [mk("submit manual need", await post("core/30080/v1/needs", {
      token: await token("maya"), jurisdiction: "region-a",
      envelope: JSON.stringify({ category: "tableware", budget_cents: 20000, region: "region-a",
        deadline_days: 14, auto_close: false,
        context: "Summer entertaining set for the season" }),
    }))],
    capture: (rs) => { state.s005_handle = deepFind(rs, "handle"); } },
  { scenario: "s005", persona: "maya", label: "Accept the boosted offer", needs: ["s005_handle"],
    explain: "Look for \"boosted\": true -- and remember the campaign never saw her.",
    run: async () => [mk("accept", await post("core/30080/v1/bookings",
      { handle: state.s005_handle, offer_id: "demo-summer-set-02" }))],
    capture: (rs) => { state.s005_match = deepFind(rs, "match_id"); } },
  { scenario: "s005", persona: "elena", label: "Fulfill the order", needs: ["s005_match"],
    explain: "Provisioning, then fulfilled -- the settlement fires on completion.",
    run: async () => [
      mk("provisioning", await post("core/30083/v1/orders/advance", { match_id: state.s005_match, state: "provisioning" })),
      mk("fulfilled", await post("core/30083/v1/orders/advance", { match_id: state.s005_match, state: "fulfilled" })),
    ] },
  { scenario: "s005", persona: "marcel", label: "The five-way split", needs: ["s005_match"],
    explain: "Seller, network, platform from the price -- agency and creator credit on top, funded by the campaign.",
    run: async () => [mk("settlement", await get("core/30081/v1/settlements/match/" + state.s005_match))] },
  { scenario: "s005", persona: "kai", label: "Performance view: credit without tracking",
    explain: "Aggregate attribution referencing campaign and asset ids -- zero buyer signal on the campaign side.",
    run: async () => [mk("attributions", await get("core/30087/v1/attributions"))] },

  // --- s006.mandate -----------------------------------------------------
  { scenario: "s006", persona: "elena", label: "Publish the household offers",
    explain: "A stock pot under Pat's coming cap, and a premium vase over it.",
    run: async () => [
      mk("stock pot", await post("core/30083/v1/offers",
        offer("demo-stock-pot-05", "Enameled stock pot", "homegoods", 12000, { auto_close: false }))),
      mk("premium vase", await post("core/30083/v1/offers",
        offer("demo-crystal-vase-06", "Premium crystal vase", "homegoods", 18000,
          { auto_close: false, attributes: ["premium"] }))),
    ] },
  { scenario: "s006", persona: "maya", label: "Grant Pat a scoped mandate",
    explain: "Category: homegoods. Per-item cap: 140.00. Recorded on the consent ledger as a mandate grant.",
    run: async () => [mk("grant mandate", await post("core/30080/v1/mandates",
      { token: await token("maya"), delegate: "pat", category: "homegoods", per_item_cents: 14000 }))] },
  { scenario: "s006", persona: "pat", label: "Open the delegate workspace",
    explain: "One view per principal, strictly separated -- Pat sees Maya, the scope, and what remains of the cap.",
    run: async () => [mk("workspace", await post("core/30080/v1/delegate/workspace",
      { token: await token("pat") }))] },
  { scenario: "s006", persona: "pat", label: "Buy under the cap",
    explain: "In scope, under cap -- closes on Pat's authority with dual attribution: actor Pat, principal Maya.",
    run: async () => [mk("delegated need", await post("core/30080/v1/delegate/needs", {
      token: await token("pat"), principal: "maya", category: "homegoods", jurisdiction: "region-a",
      envelope: JSON.stringify({ category: "homegoods", budget_cents: 12000, region: "region-a",
        deadline_days: 30, auto_close: false, context: "Delegated household purchase" }),
    }))] },
  { scenario: "s006", persona: "pat", label: "Try the premium vase (over cap)",
    explain: "Over the cap: the closing is HELD -- it will exist only after Maya's recorded approval.",
    run: async () => [mk("delegated need (premium)", await post("core/30080/v1/delegate/needs", {
      token: await token("pat"), principal: "maya", category: "homegoods", jurisdiction: "region-a",
      envelope: JSON.stringify({ category: "homegoods", budget_cents: 20000, region: "region-a",
        deadline_days: 30, auto_close: false, attributes: ["premium"],
        context: "Delegated household purchase" }),
    }))],
    capture: (rs) => { state.s006_held = deepFind(rs, "handle"); } },
  { scenario: "s006", persona: "maya", label: "Approve the held closing", needs: ["s006_held"],
    explain: "The principal's confirmation -- now, and only now, the commitment exists.",
    run: async () => [mk("approve", await post("core/30080/v1/mandates/approve",
      { token: await token("maya"), handle: state.s006_held }))] },
  { scenario: "s006", persona: "maya", label: "Her activity trail",
    explain: "Everything done in her name, attributed to Pat as delegate under the recorded grant.",
    run: async () => [mk("activity", await post("core/30080/v1/activity",
      { token: await token("maya") }))] },
  { scenario: "s006", persona: "pat", label: "Try out of scope (dresses)", optional: true, refusal: true,
    explain: "Scope is fabric-enforceable: refused before any environment exists. The refusal IS the pass.",
    run: async () => [mk("out-of-scope need", await post("core/30080/v1/delegate/needs", {
      token: await token("pat"), principal: "maya", category: "dresses", jurisdiction: "region-a",
      envelope: JSON.stringify({ category: "dresses", budget_cents: 20000, region: "region-a",
        deadline_days: 30, auto_close: false, context: "Delegated household purchase" }),
    }))] },
  { scenario: "s006", persona: "maya", label: "Revoke the mandate", optional: true,
    explain: "Instant: the workspace clears and every subsequent delegated attempt fails.",
    run: async () => [mk("revoke", await post("core/30080/v1/mandates/revoke",
      { token: await token("maya"), delegate: "pat" }))] },

  // --- s007.inventory ---------------------------------------------------
  { scenario: "s007", persona: "alex", label: "Register + certify the connector",
    explain: "Sandbox first -- no production tenant before partner verification.",
    run: async () => {
      const reg = await post("core/30088/v1/partners", { name: "alex-erp" });
      state.s007_partner = deepFind(reg.data, "partner_id");
      const cert = await post("core/30088/v1/partners/certify", { partner_id: state.s007_partner });
      return [mk("register", reg), mk("certify", cert)];
    } },
  { scenario: "s007", persona: "elena", label: "Grant scoped credentials", needs: ["s007_partner"],
    explain: "Elena grants exactly catalog + inventory + orders. The scope is a hard ceiling, not a suggestion.",
    run: async () => [mk("grant", await post("core/30088/v1/grants",
      { tenant: "elena-atelier", partner_id: state.s007_partner,
        scopes: ["catalog", "inventory", "orders"] }))],
    capture: (rs) => { state.s007_cred = deepFind(rs, "credential"); } },
  { scenario: "s007", persona: "alex", label: "Sync the ERP catalog", needs: ["s007_cred"],
    explain: "Two lamps from the ERP become matchable offers in Elena's tenant -- nobody retypes anything.",
    run: async () => [mk("sync catalog", await post("core/30088/v1/sync/catalog", {
      credential: state.s007_cred,
      offers: [
        offer("demo-erp-lamp-01", "ERP table lamp", "lighting", 8000, { deliver_by_days: 5 }),
        offer("demo-erp-clock-02", "ERP wall clock", "lighting", 9000, { deliver_by_days: 5 }),
      ] }))] },
  { scenario: "s007", persona: "alex", label: "Stockroom sells the last lamp", needs: ["s007_cred"],
    explain: "An inventory delta zeroes the cheaper lamp. It silently leaves the matchable catalog.",
    run: async () => [mk("sync inventory", await post("core/30088/v1/sync/inventory",
      { credential: state.s007_cred, offer_id: "demo-erp-lamp-01", stock: 0,
        delta_ts: Math.floor(Date.now() / 1000) }))] },
  { scenario: "s007", persona: "maya", label: "Need a lamp",
    explain: "The match lands on the in-stock clock -- not the cheaper lamp the ERP says is gone.",
    run: async () => [mk("submit need", await post("core/30080/v1/needs", {
      token: await token("maya"), jurisdiction: "region-a",
      envelope: JSON.stringify({ category: "lighting", budget_cents: 10000, region: "region-a",
        deadline_days: 7, auto_close: true, context: "A reading lamp for the study" }),
    }))],
    capture: (rs) => { state.s007_match = deepFind(rs, "match_id"); } },
  { scenario: "s007", persona: "alex", label: "The ERP mirror agrees", needs: ["s007_match"],
    explain: "Order lifecycle mirrored back idempotently -- both sides agree on every order's state.",
    run: async () => [mk("erp order", await get("core/30088/v1/erp/orders/" + state.s007_match))] },
  { scenario: "s007", persona: "alex", label: "Try an out-of-scope query", needs: ["s007_cred"],
    optional: true, refusal: true,
    explain: "Settlement data is not in the grant: refused on credential scope, logged, nothing returned.",
    run: async () => [mk("query settlement", await post("core/30088/v1/query",
      { credential: state.s007_cred, resource: "settlement" }))] },

  // --- s009.suppression -------------------------------------------------
  { scenario: "s009", persona: "dana", label: "Record the week's demand",
    explain: "Six picnicware needs in region-a, one in region-b -- counts, never content.",
    run: async () => {
      const out = [];
      for (let i = 0; i < 6; i++) out.push(mk("record region-a #" + (i + 1),
        await post("core/30085/v1/insights/record", { category: "picnicware", region: "region-a", kind: "need" })));
      out.push(mk("record region-b", await post("core/30085/v1/insights/record",
        { category: "picnicware", region: "region-b", kind: "need" })));
      return out;
    } },
  { scenario: "s009", persona: "dana", label: "The workbench suppresses",
    explain: "region-a shows. region-b, below the anonymity threshold, is ABSENT -- not zeroed, absent.",
    run: async () => [mk("workbench", await get("core/30085/v1/workbench"))] },
  { scenario: "s009", persona: "dana", label: "Publish the outlook",
    explain: "An immutable, versioned publication -- every downstream view reads this exact version.",
    run: async () => {
      state.s009_version = "demo-" + new Date().toISOString().slice(0, 16).replace(/[-:T]/g, "");
      return [mk("publish " + state.s009_version,
        await post("core/30085/v1/outlooks", { version: state.s009_version }))];
    } },
  { scenario: "s009", persona: "elena", label: "Elena's demand outlook", needs: ["s009_version"], optional: true,
    explain: "What to stock, where to expand -- identical by construction to what agencies see.",
    run: async () => [mk("seller outlook", await get("core/30083/v1/demand-outlook/" + state.s009_version))] },
  { scenario: "s009", persona: "marcel", label: "Marcel's demand view", needs: ["s009_version"], optional: true,
    explain: "Same version, same figures -- campaigns land where the need already was.",
    run: async () => [mk("ads view", await get("core/30087/v1/demand-view/" + state.s009_version))] },

  // --- s004.failover ----------------------------------------------------
  { scenario: "s004", persona: "tom", label: "Register both regions",
    explain: "region-a: capacity 2 (sovereign). region-b: capacity 10 (roomier). Both slices attest a region identity.",
    run: async () => [
      mk("region-a", await post("core/30082/v1/edges",
        { region: "region-a", endpoint: "http://" + topo.edgeA + ":8080", capacity: 2 })),
      mk("region-b", await post("core/30082/v1/edges",
        { region: "region-b", endpoint: "http://" + topo.edgeB + ":8080", capacity: 10 })),
    ] },
  { scenario: "s004", persona: "tom", label: "Unrestricted placement -> region-b",
    explain: "Capacity-greedy by default: with no policy, the roomier region wins. Remember this answer.",
    run: async () => [mk("placement (anywhere)", await post("core/30082/v1/placements",
      { jurisdiction: "anywhere" }))] },
  { scenario: "s004", persona: "tom", label: "Pin sovereignty -> region-a",
    explain: "The jurisdiction policy is the ONLY thing excluding region-b -- and now placement answers region-a.",
    run: async () => [
      mk("set policy", await post("core/30082/v1/policies",
        { jurisdiction: "region-a", regions: ["region-a"] })),
      mk("placement (region-a)", await post("core/30082/v1/placements",
        { jurisdiction: "region-a" })),
    ] },
  { scenario: "s004", persona: "elena", label: "Publish the ceramics offer",
    explain: "The offer the sovereign match will land on.",
    run: async () => [mk("publish offer", await post("core/30083/v1/offers",
      offer("demo-glaze-set-03", "Hand-glazed ceramic set", "ceramics", 11000)))] },
  { scenario: "s004", persona: "tom", label: "Arm two isolation faults (harness hat)",
    explain: "The next two environments on the compliant slice will self-terminate BEFORE the envelope is opened.",
    run: async () => [mk("arm faults", await post("edge-a/v1/faults", { mode: "isolation", count: 2 }))] },
  { scenario: "s004", persona: "maya", label: "Submit the ceramics need",
    explain: "Abort, abort, then the clean match -- three attempts, same compliant placement, exactly one settlement.",
    run: async () => [mk("submit need", await post("core/30080/v1/needs", {
      token: await token("maya"), jurisdiction: "region-a",
      envelope: JSON.stringify({ category: "ceramics", budget_cents: 12000, region: "region-a",
        deadline_days: 10, auto_close: true, context: "Hand-glazed ceramic set for the new kitchen" }),
    }))],
    capture: (rs) => { state.s004_match = deepFind(rs, "match_id"); } },
  { scenario: "s004", persona: "tom", label: "The incident queue",
    explain: "Two isolation incidents, raised by abort telemetry -- fault reason attested, nothing need-derived.",
    run: async () => [mk("incidents", await get("core/30082/v1/incidents"))],
    capture: (rs) => { state.s004_envs = deepFindAll(rs, "environment_id").slice(-2); } },
  { scenario: "s004", persona: "tom", label: "An aborted environment's attestation", needs: ["s004_envs"],
    explain: "created -> attested -> aborted -> destroyed. No match record; the abort trail contains nothing need-derived.",
    run: async () => [mk("attestation trail",
      await get("core/30081/v1/attestations/env/" + state.s004_envs[0]))] },
  { scenario: "s004", persona: "tom", label: "Escalate the systemic pattern", needs: ["s004_envs"],
    explain: "Tom hands Priya a cross-party case linking both aborted lifecycles -- by environment id only.",
    run: async () => [mk("escalate", await post("core/30086/v1/incidents",
      { summary: "systemic isolation faults in region-a", from: "resource-ops",
        environment_ids: state.s004_envs }))],
    capture: (rs) => { state.s004_case = deepFind(rs, "case_id"); } },
  { scenario: "s004", persona: "priya", label: "The cross-party case", needs: ["s004_case"],
    explain: "Priya owns the whole thread: both aborted lifecycles, one case, no single participant could resolve it alone.",
    run: async () => [mk("case", await get("core/30086/v1/incidents/" + state.s004_case))] },

  // --- s008.mediation ---------------------------------------------------
  { scenario: "s008", persona: "sam", label: "Open the case (metadata only)", needs: ["s001_match"],
    explain: "Maya reports the Act I gift never arrived. The case carries order state and settlement -- no identity ever reaches it.",
    run: async () => [mk("open case", await post("core/30086/v1/support/cases",
      { match_id: state.s001_match, metadata: { order_state: "settled" } }))],
    capture: (rs) => { state.s008_case = deepFind(rs, "case_id"); } },
  { scenario: "s008", persona: "sam", label: "Request a consented disclosure", needs: ["s008_case"],
    explain: "Metadata cannot resolve it. Sam asks; only the data's owner can answer.",
    run: async () => [mk("request disclosure", await post("core/30086/v1/support/cases/disclosure/request",
      { case_id: state.s008_case }))] },
  { scenario: "s008", persona: "maya", label: "Grant it -- minimal and time-boxed", needs: ["s008_case"],
    explain: "One artifact, 20 seconds, logged immutably on the consent ledger under her pseudonym. The countdown starts now.",
    run: async () => {
      const r = await post("core/30080/v1/disclosures",
        { token: await token("maya"), case_id: state.s008_case,
          artifact: "delivery-photo-ref-77", ttl_secs: 20 });
      state.s008_expiry = Date.now() + 20000;
      return [mk("grant disclosure", r)];
    } },
  { scenario: "s008", persona: "sam", label: "Read exactly what was granted", needs: ["s008_case"],
    explain: "The artifact is readable in the case -- for as long as the grant lives, and not a second more.",
    run: async () => [mk("disclosure", await get("core/30086/v1/support/cases/" + state.s008_case + "/disclosure"))] },
  { scenario: "s008", persona: "sam", label: "Post the refund", needs: ["s001_match", "s008_case"],
    explain: "Compensating entries referencing the case -- history is never edited, the chains still verify, the net reflects the refund.",
    run: async () => [
      mk("adjust", await post("core/30081/v1/settlements/adjust",
        { match_id: state.s001_match, case_id: state.s008_case })),
      mk("settlement after", await get("core/30081/v1/settlements/match/" + state.s001_match)),
    ] },
  { scenario: "s008", persona: "sam", label: "After expiry: 410", needs: ["s008_case"], refusal: true,
    explain: "Wait for the notebook countdown to hit zero, then click -- the access path itself is gone.",
    run: async () => [mk("disclosure after expiry",
      await get("core/30086/v1/support/cases/" + state.s008_case + "/disclosure"))] },

  // --- s010.certification -----------------------------------------------
  { scenario: "s010", persona: "ingrid", label: "Certify the evidence trail",
    explain: "Four dimensions over everything this demo just did -- attestation continuity, residency, consent, settlement conservation -- recomputing the chains from raw dumps, trusting no self-report.",
    run: async () => [mk("certify", await post("core/30089/v1/certify"))] },
  { scenario: "s010", persona: "ingrid", label: "Tamper with one record -- get caught",
    explain: "We fetch the attestation dump, flip one lifecycle field, and resubmit. Certification localizes the exact modified record.",
    run: async () => {
      const dump = await get("core/30081/v1/attestations");
      const tampered = JSON.parse(JSON.stringify(dump.data));
      const flip = (node) => {
        if (node === null || typeof node !== "object") return false;
        if (!Array.isArray(node) && typeof node.lifecycle === "string") {
          node.lifecycle += "-TAMPERED";
          return true;
        }
        for (const v of Object.values(node)) if (flip(v)) return true;
        return false;
      };
      if (!flip(tampered)) throw new Error("no lifecycle field found in the attestation dump");
      const verdict = await post("core/30089/v1/certify/tamper", tampered);
      return [mk("fetch dump", dump), mk("certify tampered dump", verdict)];
    } },
  { scenario: "s010", persona: "ingrid", label: "The auditor's own access log",
    explain: "Every certification access was a read. No writes, no personal-data scope -- verified about the verifier.",
    run: async () => [mk("access log", await get("core/30089/v1/access-log"))] },
];

STEPS.forEach((s, i) => { s.id = s.scenario + "-" + i; });

// --- rendering ----------------------------------------------------------

const $ = (sel) => document.querySelector(sel);
let personaSecrets = {};
const stepResults = {}; // step.id -> { results, verdict } (session only)

function logLine(method, url, status) {
  const el = document.createElement("div");
  el.className = "s" + String(status)[0];
  el.textContent = new Date().toTimeString().slice(0, 8) + "  " + method + " " + url + " -> " + status;
  const log = $("#log");
  log.prepend(el);
  while (log.childElementCount > 200) log.lastChild.remove();
}

function renderNotebook() {
  const nb = $("#notebook");
  nb.innerHTML = "";
  for (const [key, label] of Object.entries(NOTEBOOK)) {
    let v = state[key];
    if (v === undefined || v === null || (Array.isArray(v) && !v.length)) continue;
    if (key === "s008_expiry") {
      const left = Math.ceil((v - Date.now()) / 1000);
      v = left > 0 ? left + "s left" : "expired";
    }
    if (Array.isArray(v)) v = v.join(", ");
    v = String(v);
    if (v.length > 26) v = v.slice(0, 12) + "..." + v.slice(-10);
    const chip = document.createElement("span");
    chip.className = "chip";
    chip.innerHTML = "<b>" + label + "</b> " + v;
    nb.appendChild(chip);
  }
  if (!nb.childElementCount) nb.innerHTML = '<span class="hint">Nothing captured yet.</span>';
}
setInterval(() => { if (state.s008_expiry) renderNotebook(); }, 1000);

function avatar(p, small) {
  return '<span class="avatar"' + (small ? ' style="width:34px;height:34px;font-size:1rem"' : "") + ">" +
    PERSONAS[p].name[0] + "</span>";
}

function renderIdentity() {
  const box = $("#identity");
  if (!currentPersona) {
    box.innerHTML = '<div class="card"><h2>Overview</h2><p class="blurb">Pick a persona to act as them. ' +
      "The slides (top right) drive the order; each scenario panel shows every step with who performs it -- " +
      "only the selected persona's buttons are live.</p></div>";
    return;
  }
  const p = PERSONAS[currentPersona];
  const pw = personaSecrets[currentPersona];
  box.innerHTML =
    '<div class="card">' + avatar(currentPersona) +
    "<h2>" + p.name + '</h2><div class="role">' + p.role + '</div>' +
    '<div class="app">' + p.app + "</div>" +
    '<p class="blurb">' + p.blurb + "</p>" +
    '<div class="cred"><span>console login</span></div>' +
    '<div class="cred"><b>' + currentPersona + "</b><span>-</span>" +
    '<span id="pw" data-shown="0">********</span>' +
    '<button id="pw-toggle" title="show/hide vault password">o</button></div>' +
    '<p class="hint">Password from the host authentication vault -- the same one the VM account was provisioned with.</p>' +
    "</div>";
  $("#pw-toggle").onclick = () => {
    const el = $("#pw");
    const shown = el.dataset.shown === "1";
    el.textContent = shown ? "********" : (pw ?? "<unavailable>");
    el.dataset.shown = shown ? "0" : "1";
  };
}

function verdictFor(step, results) {
  const last = results[results.length - 1];
  if (step.check) return step.check(results);
  if (step.refusal) {
    return last.status >= 400 && last.status < 500
      ? { ok: true, note: "Refused (" + last.status + ") -- the boundary held. That IS the pass." }
      : { ok: false, note: "Expected a 4xx refusal, got " + last.status + "." };
  }
  const bad = results.find((r) => r.status >= 400);
  return bad
    ? { ok: false, note: bad.label + " returned " + bad.status + "." }
    : { ok: true, note: "" };
}

async function runStep(step, btn) {
  btn.disabled = true;
  btn.classList.add("busy");
  btn.textContent = "...";
  try {
    const results = await step.run();
    if (step.capture) step.capture(results.map((r) => r.data));
    const verdict = verdictFor(step, results);
    stepResults[step.id] = { results, verdict };
    if (verdict.ok) done[step.id] = true;
    save();
  } catch (e) {
    stepResults[step.id] = { results: [], verdict: { ok: false, note: String(e.message || e) } };
  }
  render();
}

function renderStep(step, idx) {
  const row = document.createElement("div");
  row.className = "step" + (step.optional ? " optional" : "");
  const active = step.persona === currentPersona;
  const missing = (step.needs || []).filter((k) => {
    const v = k === "s004_envs" ? (state[k] || []).length : state[k];
    return !v;
  });
  const res = stepResults[step.id];

  row.innerHTML =
    '<span class="num">' + idx + "</span>" +
    '<span class="who' + (active ? " active" : "") + '">' + PERSONAS[step.persona].name + "</span>" +
    '<span class="what"><span class="label">' + step.label +
    (done[step.id] ? '<span class="done">[OK]</span>' : "") + "</span>" +
    '<div class="explain">' + step.explain + "</div>" +
    (missing.length && active
      ? '<div class="missing">needs: ' + missing.map((k) => NOTEBOOK[k] || k).join(", ") + "</div>" : "") +
    "</span>";

  const btn = document.createElement("button");
  btn.className = "run";
  btn.textContent = "Run";
  if (!active) { btn.disabled = true; btn.title = "Switch persona to " + PERSONAS[step.persona].name; }
  else if (missing.length) { btn.disabled = true; btn.title = "Run the earlier step that captures: " + missing.join(", "); }
  btn.onclick = () => runStep(step, btn);
  row.appendChild(btn);

  if (res) {
    const box = document.createElement("div");
    box.className = "results";
    for (const r of res.results) {
      const cls = r.status < 300 ? "ok" : r.status < 500 ? "warn" : "bad";
      const line = document.createElement("div");
      line.className = "result-line";
      line.innerHTML = '<span class="status ' + cls + '">' + r.status + "</span> " + r.label;
      box.appendChild(line);
      const det = document.createElement("details");
      det.innerHTML = "<summary>response</summary>";
      const pre = document.createElement("pre");
      pre.textContent = typeof r.data === "string" ? r.data : JSON.stringify(r.data, null, 2);
      det.appendChild(pre);
      box.appendChild(det);
    }
    if (res.verdict.note) {
      const v = document.createElement("div");
      v.className = "verdict " + (res.verdict.ok ? "ok" : "bad");
      v.textContent = (res.verdict.ok ? "[OK] " : "[X] ") + res.verdict.note;
      box.appendChild(v);
    }
    row.appendChild(box);
  }
  return row;
}

function renderSteps() {
  const host = $("#steps");
  host.innerHTML = "";
  if (!currentPersona) {
    const card = document.createElement("div");
    card.className = "card";
    card.innerHTML = "<h2>The cast</h2><p class='hint'>Eleven personas, ten scenarios, one loop: " +
      "buyer served, seller found, network rewarded, platform credited.</p>";
    const grid = document.createElement("div");
    grid.className = "cast";
    for (const [key, p] of Object.entries(PERSONAS)) {
      const m = document.createElement("div");
      m.className = "member";
      m.innerHTML = avatar(key, true) + '<span><div class="m-name">' + p.name +
        '</div><div class="m-role">' + p.role + "</div></span>";
      m.onclick = () => { $("#persona-select").value = key; selectPersona(key); };
      grid.appendChild(m);
    }
    card.appendChild(grid);
    host.appendChild(card);
    return;
  }
  let lastAct = "";
  for (const sc of SCENARIOS) {
    const steps = STEPS.filter((s) => s.scenario === sc.id);
    if (!steps.some((s) => s.persona === currentPersona)) continue;
    const panel = document.createElement("div");
    panel.className = "panel scenario";
    const actLabel = sc.act !== lastAct ? ACTS[sc.act] + " - " : "";
    lastAct = sc.act;
    panel.innerHTML = '<div class="act">' + actLabel + "scenario</div><h2>" + sc.name +
      '</h2><p class="tagline">' + sc.tagline + "</p>";
    steps.forEach((s, i) => panel.appendChild(renderStep(s, i + 1)));
    host.appendChild(panel);
  }
}

function render() {
  renderIdentity();
  renderSteps();
  renderNotebook();
}

function selectPersona(p) {
  currentPersona = p;
  render();
}

// --- boot ---------------------------------------------------------------

async function boot() {
  const sel = $("#persona-select");
  for (const [key, p] of Object.entries(PERSONAS)) {
    const opt = document.createElement("option");
    opt.value = key;
    opt.textContent = p.name + " -- " + p.role;
    sel.appendChild(opt);
  }
  sel.onchange = () => selectPersona(sel.value);
  $("#reset-state").onclick = () => {
    if (!confirm("Forget captured ids and check-marks? (The lab itself is untouched.)")) return;
    for (const k of Object.keys(state)) delete state[k];
    for (const k of Object.keys(done)) delete done[k];
    save();
    render();
  };
  try {
    const t = await (await fetch("/api/topology")).json();
    topo = t;
    const el = $("#topology");
    if (t.core) {
      el.textContent = "core " + t.core + " - edge-a " + (t.edgeA || "?") + " - edge-b " + (t.edgeB || "?");
    } else {
      el.textContent = "amisad-core unresolved -- restart serve-by-act.ps1 with -CoreIp";
      el.classList.add("bad");
    }
  } catch {
    $("#topology").textContent = "topology unavailable";
    $("#topology").classList.add("bad");
  }
  try {
    const list = await (await fetch("/api/personas")).json();
    for (const e of list) personaSecrets[e.username] = e.password;
  } catch {
    /* card shows <unavailable>; the API steps still work */
  }
  if (topo.core) {
    const el = $("#consents");
    try {
      const r = await ensureBuyerConsents();
      el.textContent = r.note;
      if (!r.ok) el.classList.add("bad");
    } catch (e) {
      el.textContent = "consent preflight failed: " + (e.message || e);
      el.classList.add("bad");
    }
  }
  render();
}
boot();
