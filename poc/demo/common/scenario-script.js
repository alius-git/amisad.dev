// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 42a5e2c2-183a-4d9b-8831-48f64d177816
// The AmisAd demo script both consoles run: the persona cast, the acts and
// scenarios, the notebook of ids a run captures, and every step with the API
// calls it makes. by-act/ui/app.js and data-view/ui/shared.js load it from
// /common/scenario-script.js and render it. Loaded as a plain script (no
// modules) and written to the data-view's Safari 13.1 / iPadOS 13 baseline:
// optional chaining and ?? are fine, replaceAll / Array.at / structuredClone
// are not.
//
// Requests carry demo- prefixed ids and demo-only categories, so a run is
// deterministic on top of whatever durable state the automated end-to-end run
// left behind - no snapshot restore needed mid-demo.

"use strict";

var AmisAdScript = (function () {

  // --- REGION: cast
  var PERSONAS = {
    maya:   { name: "Maya",   role: "The Buyer",                   app: "AmisAd/buyer",
              blurb: "States a need once, in her own words. Nothing about her leaves -- not to the seller, not to anyone." },
    elena:  { name: "Elena",  role: "The Seller",                  app: "AmisAd/seller",
              blurb: "A dress atelier meeting real intent, not audiences. She never touches anyone's data." },
    tom:    { name: "Tom",    role: "The Telco Administrator",     app: "AmisAd/resource",
              blurb: "Runs the sealed slices close to the buyer, inside the law -- and books the network's share." },
    marcel: { name: "Marcel", role: "The Ad Agency Administrator", app: "AmisAd/ads",
              blurb: "Campaigns that reach real needs, measured on the only number that matters: did it fit?" },
    kai:    { name: "Kai",    role: "The Creative Partner",        app: "AmisAd/ads (studio)",
              blurb: "Sells creative talent: briefs in, assets out, and proof the work performed." },
    priya:  { name: "Priya",  role: "The Platform Operator",       app: "AmisAd/platform",
              blurb: "Steward of the marketplace nobody can see into -- precisely because nobody can see into it." },
    ingrid: { name: "Ingrid", role: "The Trust Auditor",           app: "AmisAd/audit",
              blurb: "Independently verifies the central claim: nothing about the buyer leaves. Evidence, not assurances." },
    dana:   { name: "Dana",   role: "The Demand Analyst",          app: "AmisAd/insights",
              blurb: "Works the one window that exists: aggregate demand above the anonymity threshold." },
    alex:   { name: "Alex",   role: "The Integration Partner",     app: "AmisAd/connect",
              blurb: "Connects the seller's ERP so external truth governs matching -- under scopes that are a hard ceiling." },
    sam:    { name: "Sam",    role: "The Support Agent",           app: "AmisAd/platform (support)",
              blurb: "Mediates from metadata alone. Support and surveillance stay permanently different things." },
    pat:    { name: "Pat",    role: "The Buyer-Side Delegate",     app: "AmisAd/buyer (delegate)",
              blurb: "Acts for Maya under a scoped, capped, expiring mandate -- every action on her trail." }
  };
  var PERSONA_ORDER = ["maya", "elena", "tom", "marcel", "kai", "priya", "ingrid", "dana", "alex", "sam", "pat"];

  var ACTS = {
    I: "Act I -- The Buyer Loop",
    II: "Act II -- The Economy",
    III: "Act III -- Trust & Operations"
  };

  var SCENARIOS = [
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
      tagline: "Ingrid certifies the very demo you just watched -- and catches a deliberate tamper." }
  ];

  // --- REGION: notebook
  // The ids a run captures, under the labels the notebook shows them with.
  var NOTEBOOK = {
    s001_handle: "s001 handle", s001_match: "s001 match",
    s002_handle: "s002 handle", s002_match: "s002 match",
    s003_handle: "s003 handle",
    s005_campaign: "campaign", s005_asset: "asset", s005_handle: "s005 handle", s005_match: "s005 match",
    s006_held: "held handle",
    s007_partner: "partner", s007_cred: "credential", s007_match: "s007 match",
    s009_version: "outlook",
    s004_match: "s004 match", s004_envs: "aborted envs", s004_case: "ops case",
    s008_case: "support case", s008_expiry: "disclosure expiry"
  };

  // --- REGION: plumbing
  function deepFind(node, key) {
    if (node === null || typeof node !== "object") return undefined;
    if (!Array.isArray(node) && key in node && typeof node[key] !== "object") return node[key];
    var vals = Object.values(node);
    for (var i = 0; i < vals.length; i++) {
      var hit = deepFind(vals[i], key);
      if (hit !== undefined) return hit;
    }
    return undefined;
  }
  function deepFindAll(node, key, out) {
    out = out || [];
    function visit(value) {
      if (value === null || typeof value !== "object") return;
      if (!Array.isArray(value) && key in value && typeof value[key] !== "object") out.push(value[key]);
      var vals = Object.values(value);
      for (var i = 0; i < vals.length; i++) visit(vals[i]);
    }
    visit(node);
    var seen = new Set();
    return out.filter(function (value) {
      // NaN is unequal to itself, so retain each occurrence.
      if (value !== value) return true;
      if (seen.has(value)) return false;
      seen.add(value);
      return true;
    });
  }

  // One result row per API call a step makes.
  function mk(label, r) { return { label: label, status: r.status, data: r.data }; }

  function offer(id, title, category, price, extra) {
    return Object.assign({
      offer_id: id, tenant: "elena-atelier", title: title, category: category,
      region: "region-a", price_cents: price, deliver_by_days: 10, auto_close: true
    }, extra || {});
  }

  // --- REGION: the script
  // Array order is presentation order. `persona` is who acts; `needs` lists
  // the notebook ids a step consumes, so a console holds the step until they
  // are captured; `refusal` marks a step whose pass is a 4xx from the platform.
  // `touches` names the data-view boxes a step can actually change: the data
  // window fast-polls exactly those and stamps them with who caused the
  // change. Steps that only read touch nothing. The list is deliberately
  // conservative - a box that changes without a hint is still caught by the
  // regular sweep within a few seconds.
  //
  // api is the console's own side of a run: its notebook state, its topology
  // and its transport (post, get, token). Each console calls this once and
  // runs the steps through its own proxy and storage.
  function steps(api) {
    var state = api.state, post = api.post, get = api.get, token = api.token, topo = api.topo;
    var STEPS = [
      // --- REGION: s001.fulfillment
      { scenario: "s001", persona: "elena", label: "Publish the standing offer",
        explain: "Ceramic serving set, standing terms, closes automatically -- Elena's catalog, her words.",
        touches: ["seller.catalog.a"],
        run: async function () {
          return [mk("publish offer", await post("core/30083/v1/offers",
            offer("demo-serving-set-01", "Ceramic serving set", "giftware", 11000)))];
        } },
      { scenario: "s001", persona: "maya", label: "Submit the gift need",
        explain: "The need travels as an opaque envelope; only the sealed environment opens it. Note: no name, no address, nothing about Maya.",
        touches: ["seller.orders", "ledger.verify", "resource.telemetry", "edge-a.egress", "ledger.settlement.last"],
        run: async function () {
          return [mk("submit need", await post("core/30080/v1/needs", {
            token: await token("maya"), jurisdiction: "region-a",
            envelope: JSON.stringify({ category: "giftware", budget_cents: 12000, region: "region-a",
              deadline_days: 14, auto_close: true,
              context: "Wedding gift from the couple's wish list, deliver to their city" })
          }))];
        },
        capture: function (rs) { state.s001_handle = deepFind(rs, "handle"); state.s001_match = deepFind(rs, "match_id"); } },
      { scenario: "s001", persona: "elena", label: "Ship it (provisioning)", needs: ["s001_match"],
        explain: "Elena's order board: a match that fits, an appointment-free delivery -- and no buyer identity anywhere on it.",
        touches: ["seller.orders"],
        run: async function () {
          return [mk("advance", await post("core/30083/v1/orders/advance",
            { match_id: state.s001_match, state: "provisioning" }))];
        } },
      { scenario: "s001", persona: "elena", label: "Confirm fulfilled -> settled", needs: ["s001_match"],
        explain: "Fulfillment triggers the four-way settlement: seller, network, platform, ad partners.",
        touches: ["seller.orders", "ledger.verify", "ledger.settlement.last"],
        run: async function () {
          return [mk("advance", await post("core/30083/v1/orders/advance",
            { match_id: state.s001_match, state: "fulfilled" }))];
        } },
      { scenario: "s001", persona: "maya", label: "Check delivery", needs: ["s001_handle"],
        explain: "Maya's only surface: her handle. Status: delivered.",
        touches: [],
        run: async function () {
          return [mk("order status", await get("core/30080/v1/orders/" + state.s001_handle))];
        } },
      { scenario: "s001", persona: "maya", label: "Proof: the receipt is a hash chain",
        explain: "Both ledgers verify end to end -- the receipt survives restarts and cannot be quietly edited.",
        touches: [],
        run: async function () { return [mk("ledger verify", await get("core/30081/v1/verify"))]; } },

      // --- REGION: s002.fitting
      { scenario: "s002", persona: "elena", label: "Publish the dress rack",
        explain: "Five dresses across two sellers -- one dusty blue, one missing attributes, one past deadline, one out of region.",
        touches: ["seller.catalog.a", "seller.catalog.b"],
        run: async function () {
          var dress = function (id, tenant, title, price, days, attrs, slots, region) {
            return { offer_id: id, tenant: tenant, title: title, category: "dresses",
              region: region || "region-a", price_cents: price, deliver_by_days: days,
              auto_close: false, attributes: attrs, fitting_slots: slots };
          };
          var bodies = [
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
              ["midi", "sleeves", "warm-fabric"], [{ slot_id: "thu-8", day: "thursday", day_ordinal: 4 }], "region-b")
          ];
          var out = [];
          for (var i = 0; i < bodies.length; i++) {
            out.push(mk(bodies[i].offer_id, await post("core/30083/v1/offers", bodies[i])));
          }
          return out;
        } },
      { scenario: "s002", persona: "maya", label: "Ask for the shortlist",
        explain: "Manual policy: sleeves, warm fabric, anything but dusty blue, fitting before Friday. Only the one dress that fits everything comes back.",
        touches: ["ledger.verify", "resource.telemetry", "edge-a.egress"],
        run: async function () {
          return [mk("submit manual need", await post("core/30080/v1/needs", {
            token: await token("maya"), jurisdiction: "region-a",
            envelope: JSON.stringify({ category: "dresses", budget_cents: 20000, region: "region-a",
              deadline_days: 4, auto_close: false,
              attributes: ["midi", "sleeves", "warm-fabric"], exclusions: ["dusty-blue"],
              fitting_before_ordinal: 5,
              context: "Midi dress with sleeves in a warm-weather fabric; fitting near the office before Friday" })
          }))];
        },
        capture: function (rs) { state.s002_handle = deepFind(rs, "handle"); } },
      { scenario: "s002", persona: "maya", label: "Book the Thursday fitting", needs: ["s002_handle"],
        explain: "Her explicit choice is the commitment -- the appointment is a slot id and a day, never a person.",
        touches: ["seller.orders"],
        run: async function () {
          return [mk("book", await post("core/30080/v1/bookings",
            { handle: state.s002_handle, offer_id: "demo-linen-midi-04", slot_id: "thu-1" }))];
        },
        capture: function (rs) { state.s002_match = deepFind(rs, "match_id"); } },
      { scenario: "s002", persona: "maya", label: "Notifications: exactly two", needs: ["s002_handle"],
        explain: "Quiet by default -- the shortlist and the booking confirmation. Nothing else, ever.",
        touches: [],
        run: async function () {
          return [mk("notifications", await get("core/30080/v1/notifications/" + state.s002_handle))];
        } },
      { scenario: "s002", persona: "elena", label: "Fulfill the fitting order", needs: ["s002_match"], optional: true,
        explain: "Advancing to fulfilled settles the split exactly as in s001.",
        touches: ["seller.orders", "ledger.verify", "ledger.settlement.last"],
        run: async function () {
          return [
            mk("provisioning", await post("core/30083/v1/orders/advance", { match_id: state.s002_match, state: "provisioning" })),
            mk("fulfilled", await post("core/30083/v1/orders/advance", { match_id: state.s002_match, state: "fulfilled" }))
          ];
        } },

      // --- REGION: s003.silence
      { scenario: "s003", persona: "maya", label: "Sign up (consent grants)",
        explain: "Participation and contribution, granted on the consent ledger under a pseudonymous subject -- never a name.",
        touches: ["ledger.consent.maya", "ledger.verify"],
        run: async function () {
          return [
            mk("grant contribution", await post("core/30080/v1/consents",
              { token: await token("maya"), grant_type: "contribution", action: "grant" })),
            mk("grant participation", await post("core/30080/v1/consents",
              { token: await token("maya"), grant_type: "participation", action: "grant" }))
          ];
        } },
      { scenario: "s003", persona: "maya", label: "Open a need nothing fits yet",
        explain: "A crystal decanter, modest budget. No offer fits -- the need stays open on the coordinator.",
        touches: ["coordinator.contributions", "ledger.verify", "resource.telemetry", "edge-a.egress"],
        run: async function () {
          return [mk("open need", await post("core/30080/v1/needs", {
            token: await token("maya"), jurisdiction: "region-a",
            envelope: JSON.stringify({ category: "glassware", budget_cents: 9000, region: "region-a",
              deadline_days: 21, auto_close: true,
              context: "Crystal decanter for an anniversary, modest budget" })
          }))];
        },
        capture: function (rs) { state.s003_handle = deepFind(rs, "handle"); } },
      { scenario: "s003", persona: "maya", label: "Pause participation",
        explain: "One revocation on the consent ledger. From this instant the network is silent for Maya.",
        touches: ["ledger.consent.maya", "ledger.verify"],
        run: async function () {
          return [mk("revoke participation", await post("core/30080/v1/consents",
            { token: await token("maya"), grant_type: "participation", action: "revoke" }))];
        } },
      { scenario: "s003", persona: "elena", label: "Publish a PERFECT decanter offer",
        explain: "Fits the open need on every axis. Publishing re-runs matching over open needs -- watch what does not happen.",
        touches: ["seller.catalog.a"],
        run: async function () {
          return [mk("publish offer", await post("core/30083/v1/offers",
            offer("demo-crystal-decanter-09", "Crystal decanter", "glassware", 8500, { deliver_by_days: 5 })))];
        } },
      { scenario: "s003", persona: "maya", label: "...silence", needs: ["s003_handle"],
        explain: "No environment, no match, no notification. The consent gate sits inside the matching cycle itself.",
        touches: [],
        run: async function () {
          return [mk("notifications", await get("core/30080/v1/notifications/" + state.s003_handle))];
        },
        check: function (rs) {
          var d = rs[0].data;
          var list = d && d.notifications ? d.notifications : d;
          return (Array.isArray(list) && list.length === 0)
            ? { ok: true, note: "Empty -- a perfect offer produced nothing." }
            : { ok: false, note: "Expected an empty notification list." };
        } },
      { scenario: "s003", persona: "maya", label: "Resume -- served immediately",
        explain: "Re-granting brings the open needs back to life; the decanter matches now (look for \"rematched\").",
        touches: ["ledger.consent.maya", "ledger.verify", "seller.orders", "coordinator.contributions", "resource.telemetry", "edge-a.egress"],
        run: async function () {
          return [
            mk("grant contribution", await post("core/30080/v1/consents",
              { token: await token("maya"), grant_type: "contribution", action: "grant" })),
            mk("grant participation", await post("core/30080/v1/consents",
              { token: await token("maya"), grant_type: "participation", action: "grant" }))
          ];
        } },
      { scenario: "s003", persona: "maya", label: "Consent history: grant -> revoke -> re-grant",
        explain: "The full history on the verifying consent chain -- revocation is recorded, honored, and auditable.",
        touches: [],
        run: async function () {
          return [mk("consent state", await post("core/30080/v1/consents/state",
            { token: await token("maya") }))];
        } },

      // --- REGION: s005.attribution
      { scenario: "s005", persona: "marcel", label: "Create the campaign",
        explain: "Aggregate targeting only: a region and a need category. 2000c committed per match on top of the price.",
        touches: ["ads.campaign"],
        run: async function () {
          return [mk("create campaign", await post("core/30087/v1/campaigns",
            { tenant: "elena-atelier", region: "region-a", category: "tableware",
              ad_cents_per_match: 2000, budget_cents: 10000 }))];
        },
        capture: function (rs) { state.s005_campaign = deepFind(rs, "campaign_id"); } },
      { scenario: "s005", persona: "marcel", label: "Send the creative brief", needs: ["s005_campaign"],
        explain: "The brief goes out to Creative Partners with scope and terms.",
        touches: ["ads.briefs"],
        run: async function () {
          return [mk("brief", await post("core/30087/v1/briefs", { campaign_id: state.s005_campaign }))];
        } },
      { scenario: "s005", persona: "kai", label: "Check the demand queue",
        explain: "Kai's inventory is talent and turnaround; the brief is a real order, not a pitch.",
        touches: [],
        run: async function () { return [mk("briefs", await get("core/30087/v1/briefs"))]; } },
      { scenario: "s005", persona: "kai", label: "Deliver the asset", needs: ["s005_campaign"],
        explain: "\"summer-hero-01\" ships, approved and ready for placement. The asset itself stays private until the campaign places it.",
        touches: [],
        run: async function () {
          return [mk("asset", await post("core/30087/v1/assets",
            { campaign_id: state.s005_campaign, creator: "kai", creative: "summer-hero-01" }))];
        },
        capture: function (rs) { state.s005_asset = deepFind(rs, "asset_id"); } },
      { scenario: "s005", persona: "marcel", label: "Activate the campaign", needs: ["s005_campaign", "s005_asset"],
        explain: "Live in region-a for tableware needs. No individual was targetable at any point.",
        touches: ["ads.campaign"],
        run: async function () {
          return [mk("activate", await post("core/30087/v1/campaigns/activate",
            { campaign_id: state.s005_campaign, asset_id: state.s005_asset }))];
        } },
      { scenario: "s005", persona: "elena", label: "Publish the summer offer",
        explain: "The offer the campaign will boost -- Elena's price is untouched by the ad economics.",
        touches: ["seller.catalog.a"],
        run: async function () {
          return [mk("publish offer", await post("core/30083/v1/offers",
            offer("demo-summer-set-02", "Summer entertaining set", "tableware", 11000,
              { deliver_by_days: 14, auto_close: false })))];
        } },
      { scenario: "s005", persona: "maya", label: "State the summer need",
        explain: "The boost happens INSIDE the sealed environment -- the creative renders in the shortlist, never outside.",
        touches: ["ledger.verify", "resource.telemetry", "edge-a.ingress", "edge-a.egress"],
        run: async function () {
          return [mk("submit manual need", await post("core/30080/v1/needs", {
            token: await token("maya"), jurisdiction: "region-a",
            envelope: JSON.stringify({ category: "tableware", budget_cents: 20000, region: "region-a",
              deadline_days: 14, auto_close: false,
              context: "Summer entertaining set for the season" })
          }))];
        },
        capture: function (rs) { state.s005_handle = deepFind(rs, "handle"); } },
      { scenario: "s005", persona: "maya", label: "Accept the boosted offer", needs: ["s005_handle"],
        explain: "Look for \"boosted\": true -- and remember the campaign never saw her.",
        touches: ["seller.orders"],
        run: async function () {
          return [mk("accept", await post("core/30080/v1/bookings",
            { handle: state.s005_handle, offer_id: "demo-summer-set-02" }))];
        },
        capture: function (rs) { state.s005_match = deepFind(rs, "match_id"); } },
      { scenario: "s005", persona: "elena", label: "Fulfill the order", needs: ["s005_match"],
        explain: "Provisioning, then fulfilled -- the settlement fires on completion.",
        touches: ["seller.orders", "ledger.verify", "ledger.settlement.last", "ads.attributions", "ads.campaign"],
        run: async function () {
          return [
            mk("provisioning", await post("core/30083/v1/orders/advance", { match_id: state.s005_match, state: "provisioning" })),
            mk("fulfilled", await post("core/30083/v1/orders/advance", { match_id: state.s005_match, state: "fulfilled" }))
          ];
        } },
      { scenario: "s005", persona: "marcel", label: "The five-way split", needs: ["s005_match"],
        explain: "Seller, network, platform from the price -- agency and creator credit on top, funded by the campaign.",
        touches: [],
        run: async function () {
          return [mk("settlement", await get("core/30081/v1/settlements/match/" + state.s005_match))];
        } },
      { scenario: "s005", persona: "kai", label: "Performance view: credit without tracking",
        explain: "Aggregate attribution referencing campaign and asset ids -- zero buyer signal on the campaign side.",
        touches: [],
        run: async function () { return [mk("attributions", await get("core/30087/v1/attributions"))]; } },

      // --- REGION: s006.mandate
      { scenario: "s006", persona: "elena", label: "Publish the household offers",
        explain: "A stock pot under Pat's coming cap, and a premium vase over it.",
        touches: ["seller.catalog.a"],
        run: async function () {
          return [
            mk("stock pot", await post("core/30083/v1/offers",
              offer("demo-stock-pot-05", "Enameled stock pot", "homegoods", 12000, { auto_close: false }))),
            mk("premium vase", await post("core/30083/v1/offers",
              offer("demo-crystal-vase-06", "Premium crystal vase", "homegoods", 18000,
                { auto_close: false, attributes: ["premium"] })))
          ];
        } },
      { scenario: "s006", persona: "maya", label: "Grant Pat a scoped mandate",
        explain: "Category: homegoods. Per-item cap: 140.00. Recorded on the consent ledger as a mandate grant -- the scope itself stays private.",
        touches: ["ledger.consent.maya", "ledger.verify"],
        run: async function () {
          return [mk("grant mandate", await post("core/30080/v1/mandates",
            { token: await token("maya"), delegate: "pat", category: "homegoods", per_item_cents: 14000 }))];
        } },
      { scenario: "s006", persona: "pat", label: "Open the delegate workspace",
        explain: "One view per principal, strictly separated -- Pat sees Maya, the scope, and what remains of the cap.",
        touches: [],
        run: async function () {
          return [mk("workspace", await post("core/30080/v1/delegate/workspace",
            { token: await token("pat") }))];
        } },
      { scenario: "s006", persona: "pat", label: "Buy under the cap",
        explain: "In scope, under cap -- closes on Pat's authority with dual attribution: actor Pat, principal Maya.",
        touches: ["seller.orders", "ledger.verify", "resource.telemetry", "edge-a.egress"],
        run: async function () {
          return [mk("delegated need", await post("core/30080/v1/delegate/needs", {
            token: await token("pat"), principal: "maya", category: "homegoods", jurisdiction: "region-a",
            envelope: JSON.stringify({ category: "homegoods", budget_cents: 12000, region: "region-a",
              deadline_days: 30, auto_close: false, context: "Delegated household purchase" })
          }))];
        } },
      { scenario: "s006", persona: "pat", label: "Try the premium vase (over cap)",
        explain: "Over the cap: the closing is HELD -- it will exist only after Maya's recorded approval.",
        touches: ["ledger.verify", "resource.telemetry", "edge-a.egress"],
        run: async function () {
          return [mk("delegated need (premium)", await post("core/30080/v1/delegate/needs", {
            token: await token("pat"), principal: "maya", category: "homegoods", jurisdiction: "region-a",
            envelope: JSON.stringify({ category: "homegoods", budget_cents: 20000, region: "region-a",
              deadline_days: 30, auto_close: false, attributes: ["premium"],
              context: "Delegated household purchase" })
          }))];
        },
        capture: function (rs) { state.s006_held = deepFind(rs, "handle"); } },
      { scenario: "s006", persona: "maya", label: "Approve the held closing", needs: ["s006_held"],
        explain: "The principal's confirmation -- now, and only now, the commitment exists.",
        touches: ["seller.orders"],
        run: async function () {
          return [mk("approve", await post("core/30080/v1/mandates/approve",
            { token: await token("maya"), handle: state.s006_held }))];
        } },
      { scenario: "s006", persona: "maya", label: "Her activity trail",
        explain: "Everything done in her name, attributed to Pat as delegate under the recorded grant.",
        touches: [],
        run: async function () {
          return [mk("activity", await post("core/30080/v1/activity", { token: await token("maya") }))];
        } },
      { scenario: "s006", persona: "pat", label: "Try out of scope (dresses)", optional: true, refusal: true,
        explain: "Scope is fabric-enforceable: refused before any environment exists. The refusal IS the pass.",
        touches: [],
        run: async function () {
          return [mk("out-of-scope need", await post("core/30080/v1/delegate/needs", {
            token: await token("pat"), principal: "maya", category: "dresses", jurisdiction: "region-a",
            envelope: JSON.stringify({ category: "dresses", budget_cents: 20000, region: "region-a",
              deadline_days: 30, auto_close: false, context: "Delegated household purchase" })
          }))];
        } },
      { scenario: "s006", persona: "maya", label: "Revoke the mandate", optional: true,
        explain: "Instant: the workspace clears and every subsequent delegated attempt fails.",
        touches: ["ledger.consent.maya", "ledger.verify"],
        run: async function () {
          return [mk("revoke", await post("core/30080/v1/mandates/revoke",
            { token: await token("maya"), delegate: "pat" }))];
        } },

      // --- REGION: s007.inventory
      { scenario: "s007", persona: "alex", label: "Register + certify the connector",
        explain: "Sandbox first -- no production tenant before partner verification. Partner records stay private: no endpoint lists them.",
        touches: [],
        run: async function () {
          var reg = await post("core/30088/v1/partners", { name: "alex-erp" });
          state.s007_partner = deepFind(reg.data, "partner_id");
          var cert = await post("core/30088/v1/partners/certify", { partner_id: state.s007_partner });
          return [mk("register", reg), mk("certify", cert)];
        } },
      { scenario: "s007", persona: "elena", label: "Grant scoped credentials", needs: ["s007_partner"],
        explain: "Elena grants exactly catalog + inventory + orders. The scope is a hard ceiling, not a suggestion.",
        touches: [],
        run: async function () {
          return [mk("grant", await post("core/30088/v1/grants",
            { tenant: "elena-atelier", partner_id: state.s007_partner,
              scopes: ["catalog", "inventory", "orders"] }))];
        },
        capture: function (rs) { state.s007_cred = deepFind(rs, "credential"); } },
      { scenario: "s007", persona: "alex", label: "Sync the ERP catalog", needs: ["s007_cred"],
        explain: "Two lamps from the ERP become matchable offers in Elena's tenant -- nobody retypes anything.",
        touches: ["seller.catalog.a"],
        run: async function () {
          return [mk("sync catalog", await post("core/30088/v1/sync/catalog", {
            credential: state.s007_cred,
            offers: [
              offer("demo-erp-lamp-01", "ERP table lamp", "lighting", 8000, { deliver_by_days: 5 }),
              offer("demo-erp-clock-02", "ERP wall clock", "lighting", 9000, { deliver_by_days: 5 })
            ] }))];
        } },
      { scenario: "s007", persona: "alex", label: "Stockroom sells the last lamp", needs: ["s007_cred"],
        explain: "An inventory delta zeroes the cheaper lamp. It silently leaves the matchable catalog.",
        touches: ["seller.catalog.a", "connect.deltas"],
        run: async function () {
          return [mk("sync inventory", await post("core/30088/v1/sync/inventory",
            { credential: state.s007_cred, offer_id: "demo-erp-lamp-01", stock: 0,
              delta_ts: Math.floor(Date.now() / 1000) }))];
        } },
      { scenario: "s007", persona: "maya", label: "Need a lamp",
        explain: "The match lands on the in-stock clock -- not the cheaper lamp the ERP says is gone.",
        touches: ["seller.orders", "ledger.verify", "resource.telemetry", "edge-a.egress", "connect.erp"],
        run: async function () {
          return [mk("submit need", await post("core/30080/v1/needs", {
            token: await token("maya"), jurisdiction: "region-a",
            envelope: JSON.stringify({ category: "lighting", budget_cents: 10000, region: "region-a",
              deadline_days: 7, auto_close: true, context: "A reading lamp for the study" })
          }))];
        },
        capture: function (rs) { state.s007_match = deepFind(rs, "match_id"); } },
      { scenario: "s007", persona: "alex", label: "The ERP mirror agrees", needs: ["s007_match"],
        explain: "Order lifecycle mirrored back idempotently -- both sides agree on every order's state.",
        touches: [],
        run: async function () {
          return [mk("erp order", await get("core/30088/v1/erp/orders/" + state.s007_match))];
        } },
      { scenario: "s007", persona: "alex", label: "Try an out-of-scope query", needs: ["s007_cred"],
        optional: true, refusal: true,
        explain: "Settlement data is not in the grant: refused on credential scope, logged, nothing returned.",
        touches: ["connect.audit"],
        run: async function () {
          return [mk("query settlement", await post("core/30088/v1/query",
            { credential: state.s007_cred, resource: "settlement" }))];
        } },

      // --- REGION: s009.suppression
      { scenario: "s009", persona: "dana", label: "Record the week's demand",
        explain: "Six picnicware needs in region-a, one in region-b -- counts, never content.",
        touches: ["insights.workbench", "insights.unmet"],
        run: async function () {
          var out = [];
          for (var i = 0; i < 6; i++) {
            out.push(mk("record region-a #" + (i + 1),
              await post("core/30085/v1/insights/record", { category: "picnicware", region: "region-a", kind: "need" })));
          }
          out.push(mk("record region-b", await post("core/30085/v1/insights/record",
            { category: "picnicware", region: "region-b", kind: "need" })));
          return out;
        } },
      { scenario: "s009", persona: "dana", label: "The workbench suppresses",
        explain: "region-a shows. region-b, below the anonymity threshold, is ABSENT -- not zeroed, absent.",
        touches: [],
        run: async function () { return [mk("workbench", await get("core/30085/v1/workbench"))]; } },
      { scenario: "s009", persona: "dana", label: "Publish the outlook",
        explain: "An immutable, versioned publication -- every downstream view reads this exact version.",
        touches: [],
        run: async function () {
          state.s009_version = "demo-" + new Date().toISOString().slice(0, 16).replace(/[-:T]/g, "");
          return [mk("publish " + state.s009_version,
            await post("core/30085/v1/outlooks", { version: state.s009_version }))];
        } },
      { scenario: "s009", persona: "elena", label: "Elena's demand outlook", needs: ["s009_version"], optional: true,
        explain: "What to stock, where to expand -- identical by construction to what agencies see.",
        touches: [],
        run: async function () {
          return [mk("seller outlook", await get("core/30083/v1/demand-outlook/" + state.s009_version))];
        } },
      { scenario: "s009", persona: "marcel", label: "Marcel's demand view", needs: ["s009_version"], optional: true,
        explain: "Same version, same figures -- campaigns land where the need already was.",
        touches: [],
        run: async function () {
          return [mk("ads view", await get("core/30087/v1/demand-view/" + state.s009_version))];
        } },

      // --- REGION: s004.failover
      { scenario: "s004", persona: "tom", label: "Register both regions",
        explain: "region-a: capacity 2 (sovereign). region-b: capacity 10 (roomier). Both slices attest a region identity.",
        touches: ["resource.edges"],
        run: async function () {
          return [
            mk("region-a", await post("core/30082/v1/edges",
              { region: "region-a", endpoint: "http://" + topo.edgeA + ":8080", capacity: 2 })),
            mk("region-b", await post("core/30082/v1/edges",
              { region: "region-b", endpoint: "http://" + topo.edgeB + ":8080", capacity: 10 }))
          ];
        } },
      { scenario: "s004", persona: "tom", label: "Unrestricted placement -> region-b",
        explain: "Capacity-greedy by default: with no policy, the roomier region wins. Remember this answer.",
        touches: [],
        run: async function () {
          return [mk("placement (anywhere)", await post("core/30082/v1/placements",
            { jurisdiction: "anywhere" }))];
        } },
      { scenario: "s004", persona: "tom", label: "Pin sovereignty -> region-a",
        explain: "The jurisdiction policy is the ONLY thing excluding region-b -- and now placement answers region-a.",
        touches: [],
        run: async function () {
          return [
            mk("set policy", await post("core/30082/v1/policies",
              { jurisdiction: "region-a", regions: ["region-a"] })),
            mk("placement (region-a)", await post("core/30082/v1/placements",
              { jurisdiction: "region-a" }))
          ];
        } },
      { scenario: "s004", persona: "elena", label: "Publish the ceramics offer",
        explain: "The offer the sovereign match will land on.",
        touches: ["seller.catalog.a"],
        run: async function () {
          return [mk("publish offer", await post("core/30083/v1/offers",
            offer("demo-glaze-set-03", "Hand-glazed ceramic set", "ceramics", 11000)))];
        } },
      { scenario: "s004", persona: "tom", label: "Arm two isolation faults (harness hat)",
        explain: "The next two environments on the compliant slice will self-terminate BEFORE the envelope is opened.",
        touches: [],
        run: async function () {
          return [mk("arm faults", await post("edge-a/v1/faults", { mode: "isolation", count: 2 }))];
        } },
      { scenario: "s004", persona: "maya", label: "Submit the ceramics need",
        explain: "Abort, abort, then the clean match -- three attempts, same compliant placement, exactly one settlement.",
        touches: ["resource.incidents", "resource.telemetry", "ledger.verify", "seller.orders", "edge-a.egress"],
        run: async function () {
          return [mk("submit need", await post("core/30080/v1/needs", {
            token: await token("maya"), jurisdiction: "region-a",
            envelope: JSON.stringify({ category: "ceramics", budget_cents: 12000, region: "region-a",
              deadline_days: 10, auto_close: true, context: "Hand-glazed ceramic set for the new kitchen" })
          }))];
        },
        capture: function (rs) { state.s004_match = deepFind(rs, "match_id"); } },
      { scenario: "s004", persona: "tom", label: "The incident queue",
        explain: "Two isolation incidents, raised by abort telemetry -- fault reason attested, nothing need-derived.",
        touches: [],
        run: async function () { return [mk("incidents", await get("core/30082/v1/incidents"))]; },
        capture: function (rs) { state.s004_envs = deepFindAll(rs, "environment_id").slice(-2); } },
      { scenario: "s004", persona: "tom", label: "An aborted environment's attestation", needs: ["s004_envs"],
        explain: "created -> attested -> aborted -> destroyed. No match record; the abort trail contains nothing need-derived.",
        touches: [],
        run: async function () {
          return [mk("attestation trail", await get("core/30081/v1/attestations/env/" + state.s004_envs[0]))];
        } },
      { scenario: "s004", persona: "tom", label: "Escalate the systemic pattern", needs: ["s004_envs"],
        explain: "Tom hands Priya a cross-party case linking both aborted lifecycles -- by environment id only.",
        touches: ["platform.incidents"],
        run: async function () {
          return [mk("escalate", await post("core/30086/v1/incidents",
            { summary: "systemic isolation faults in region-a", from: "resource-ops",
              environment_ids: state.s004_envs }))];
        },
        capture: function (rs) { state.s004_case = deepFind(rs, "case_id"); } },
      { scenario: "s004", persona: "priya", label: "The cross-party case", needs: ["s004_case"],
        explain: "Priya owns the whole thread: both aborted lifecycles, one case, no single participant could resolve it alone.",
        touches: [],
        run: async function () {
          return [mk("case", await get("core/30086/v1/incidents/" + state.s004_case))];
        } },

      // --- REGION: s008.mediation
      { scenario: "s008", persona: "sam", label: "Open the case (metadata only)", needs: ["s001_match"],
        explain: "Maya reports the Act I gift never arrived. The case carries order state and settlement -- no identity ever reaches it.",
        touches: ["platform.disclosure"],
        run: async function () {
          return [mk("open case", await post("core/30086/v1/support/cases",
            { match_id: state.s001_match, metadata: { order_state: "settled" } }))];
        },
        capture: function (rs) { state.s008_case = deepFind(rs, "case_id"); } },
      { scenario: "s008", persona: "sam", label: "Request a consented disclosure", needs: ["s008_case"],
        explain: "Metadata cannot resolve it. Sam asks; only the data's owner can answer.",
        touches: ["platform.disclosure"],
        run: async function () {
          return [mk("request disclosure", await post("core/30086/v1/support/cases/disclosure/request",
            { case_id: state.s008_case }))];
        } },
      { scenario: "s008", persona: "maya", label: "Grant it -- minimal and time-boxed", needs: ["s008_case"],
        explain: "One artifact, 20 seconds, logged immutably on the consent ledger under her pseudonym. The countdown starts now.",
        touches: ["ledger.consent.maya", "ledger.verify", "platform.disclosure"],
        run: async function () {
          var r = await post("core/30080/v1/disclosures",
            { token: await token("maya"), case_id: state.s008_case,
              artifact: "delivery-photo-ref-77", ttl_secs: 20 });
          state.s008_expiry = Date.now() + 20000;
          return [mk("grant disclosure", r)];
        } },
      { scenario: "s008", persona: "sam", label: "Read exactly what was granted", needs: ["s008_case"],
        explain: "The artifact is readable in the case -- for as long as the grant lives, and not a second more.",
        touches: [],
        run: async function () {
          return [mk("disclosure", await get("core/30086/v1/support/cases/" + state.s008_case + "/disclosure"))];
        } },
      { scenario: "s008", persona: "sam", label: "Post the refund", needs: ["s001_match", "s008_case"],
        explain: "Compensating entries referencing the case -- history is never edited, the chains still verify, the net reflects the refund.",
        touches: ["ledger.verify", "ledger.settlement.last"],
        run: async function () {
          return [
            mk("refund", await post("core/30086/v1/support/cases/refund",
              { case_id: state.s008_case })),
            mk("settlement after", await get("core/30081/v1/settlements/match/" + state.s001_match))
          ];
        } },
      { scenario: "s008", persona: "sam", label: "After expiry: 410", needs: ["s008_case"], refusal: true,
        explain: "Wait for the notebook countdown to hit zero, then click -- the access path itself is gone.",
        touches: ["platform.disclosure"],
        run: async function () {
          return [mk("disclosure after expiry",
            await get("core/30086/v1/support/cases/" + state.s008_case + "/disclosure"))];
        } },

      // --- REGION: s010.certification
      { scenario: "s010", persona: "ingrid", label: "Certify the evidence trail",
        explain: "Four dimensions over everything this demo just did -- attestation continuity, residency, consent, settlement evidence -- recomputing the chains from raw dumps, trusting no self-report.",
        touches: ["audit.accesslog"],
        run: async function () { return [mk("certify", await post("core/30089/v1/certify"))]; } },
      { scenario: "s010", persona: "ingrid", label: "Tamper with one record -- get caught",
        explain: "We fetch the attestation dump, flip one lifecycle field, and resubmit. Certification localizes the exact modified record.",
        touches: [],
        run: async function () {
          var dump = await get("core/30081/v1/attestations");
          var tampered = JSON.parse(JSON.stringify(dump.data));
          var flip = function (node) {
            if (node === null || typeof node !== "object") return false;
            if (!Array.isArray(node) && typeof node.lifecycle === "string") {
              node.lifecycle += "-TAMPERED";
              return true;
            }
            var vals = Object.values(node);
            for (var i = 0; i < vals.length; i++) { if (flip(vals[i])) return true; }
            return false;
          };
          if (!flip(tampered)) throw new Error("no lifecycle field found in the attestation dump");
          var verdict = await post("core/30089/v1/certify/tamper", tampered);
          return [mk("fetch dump", dump), mk("certify tampered dump", verdict)];
        } },
      { scenario: "s010", persona: "ingrid", label: "The auditor's own access log",
        explain: "Every certification access was a read. No writes, no personal-data scope -- verified about the verifier.",
        touches: [],
        run: async function () { return [mk("access log", await get("core/30089/v1/access-log"))]; } }
    ];

    // Ids are scenario + ordinal WITHIN the scenario, so inserting a step in one
    // scenario never renumbers another and saved check-marks survive edits.
    var seen = {};
    for (var i = 0; i < STEPS.length; i++) {
      var s = STEPS[i];
      seen[s.scenario] = (seen[s.scenario] || 0) + 1;
      s.ord = seen[s.scenario];
      s.id = s.scenario + "-" + (s.ord < 10 ? "0" : "") + s.ord;
      s.index = i;
      if (!s.touches) s.touches = [];
    }
    return STEPS;
  }

  return {
    PERSONAS: PERSONAS, PERSONA_ORDER: PERSONA_ORDER, ACTS: ACTS, SCENARIOS: SCENARIOS,
    NOTEBOOK: NOTEBOOK, deepFind: deepFind, deepFindAll: deepFindAll, mk: mk, offer: offer,
    steps: steps
  };
})();
