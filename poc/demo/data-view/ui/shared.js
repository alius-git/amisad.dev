// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 4217b9d2-247a-4819-af1b-c688a2af0c57
// Shared model for the AmisAd data-view demo: the box registry the data window
// polls, the journal client that keeps every open window in step, and the
// swimlane renderer both windows draw with. The persona cast and the scenario
// script come from common/scenario-script.js, which the by-act console runs
// too, so each page loads that file first. Loaded as a plain script (no
// modules) and written to the Safari 13.1 / iPadOS 13 baseline: optional
// chaining and ?? are fine, replaceAll / Array.at / structuredClone are not.

"use strict";

var AD = (function () {

  // --- REGION: cast
  var PERSONAS = AmisAdScript.PERSONAS;
  var PERSONA_ORDER = AmisAdScript.PERSONA_ORDER;
  var ACTS = AmisAdScript.ACTS;
  var SCENARIOS = AmisAdScript.SCENARIOS;
  var NOTEBOOK = AmisAdScript.NOTEBOOK;

  // --- REGION: notebook state
  var LS_STATE = "amisad-dv-state";
  var LS_DONE = "amisad-dv-done";

  function load(k, d) {
    try { var v = JSON.parse(localStorage.getItem(k)); return v === null || v === undefined ? d : v; }
    catch (e) { return d; }
  }
  var state = load(LS_STATE, {});
  var done = load(LS_DONE, {});
  function save() {
    try {
      localStorage.setItem(LS_STATE, JSON.stringify(state));
      localStorage.setItem(LS_DONE, JSON.stringify(done));
    } catch (e) { /* private-mode storage denial must not stop the demo */ }
  }
  function clearLocal() {
    for (var k in state) { if (Object.prototype.hasOwnProperty.call(state, k)) { delete state[k]; } }
    for (var d in done) { if (Object.prototype.hasOwnProperty.call(done, d)) { delete done[d]; } }
    save();
  }

  var topo = { core: "", edgeA: "", edgeB: "" };
  var subjects = { maya: "", pat: "" };

  // --- REGION: plumbing
  // Every window's single hook for lab traffic. onCall lets the action window
  // draw a call log and the data window feed its leak scanner, without either
  // reaching into the other's rendering.
  var hooks = { onCall: null };

  async function call(method, url, body) {
    var opts = { method: method };
    if (body !== undefined) {
      opts.headers = { "Content-Type": "application/json" };
      opts.body = JSON.stringify(body);
    }
    var status = 0, text = "";
    try {
      var res = await fetch("/api/" + url, opts);
      status = res.status;
      text = await res.text();
    } catch (e) {
      status = 0;
      text = JSON.stringify({ error: String((e && e.message) || e) });
    }
    var data;
    try { data = JSON.parse(text); } catch (e2) { data = text; }
    if (hooks.onCall) hooks.onCall(method, url, status, text, data);
    return { status: status, data: data };
  }
  function post(url, body) { return call("POST", url, body === undefined ? {} : body); }
  function get(url) { return call("GET", url); }

  // identity-mock token, minted fresh per step (matches buyer-client).
  async function token(actor) {
    var r = await post("core/30084/v1/tokens", { actor: actor, class: "person" });
    if (r.status !== 201 || !r.data || !r.data.token) throw new Error("token mint failed (" + r.status + ")");
    return r.data.token;
  }

  // --- REGION: the script
  var STEPS = AmisAdScript.steps({ state: state, post: post, get: get, token: token, topo: topo });

  function scenarioById(id) {
    for (var i = 0; i < SCENARIOS.length; i++) { if (SCENARIOS[i].id === id) return SCENARIOS[i]; }
    return null;
  }
  function stepById(id) {
    for (var i = 0; i < STEPS.length; i++) { if (STEPS[i].id === id) return STEPS[i]; }
    return null;
  }
  function actOf(step) {
    var sc = scenarioById(step.scenario);
    return sc ? sc.act : "I";
  }

  // A step is runnable when its persona is selected, it has not been done, and
  // every notebook id it consumes exists. Order is otherwise free - the
  // presenter can re-run or skip at will.
  function missingNeeds(step) {
    var out = [];
    var needs = step.needs || [];
    for (var i = 0; i < needs.length; i++) {
      var k = needs[i];
      var v = k === "s004_envs" ? ((state[k] || []).length) : state[k];
      if (!v) out.push(k);
    }
    return out;
  }

  // --- REGION: verdict
  // step.check wins outright; otherwise a refusal step passes on a 4xx from
  // its LAST call, and any other 4xx/5xx fails the step.
  function verdictFor(step, results) {
    if (step.check) return step.check(results);
    var last = results[results.length - 1];
    if (step.refusal) {
      return (last && last.status >= 400 && last.status < 500)
        ? { ok: true, refused: true, note: "Refused (" + last.status + ") -- the boundary held. That IS the pass." }
        : { ok: false, note: "Expected a 4xx refusal, got " + (last ? last.status : "nothing") + "." };
    }
    for (var i = 0; i < results.length; i++) {
      if (results[i].status >= 400) {
        return { ok: false, note: results[i].label + " returned " + results[i].status + "." };
      }
    }
    return { ok: true, note: "" };
  }

  // --- REGION: data-view box registry
  // Every box reads ONE endpoint, and every endpoint here is a GET: the data
  // window must never mutate what it observes. `pick` projects the response
  // into the displayed rows, and change detection compares that projection -
  // so a re-ordered payload does not read as a change.

  function n(v) { return (v === undefined || v === null) ? 0 : v; }
  function len(v) { return Array.isArray(v) ? v.length : 0; }
  function money(cents) {
    if (cents === undefined || cents === null) return "--";
    return (cents / 100).toFixed(2);
  }
  function tally(list, field) {
    var out = {};
    for (var i = 0; i < (list || []).length; i++) {
      var k = list[i][field] || "?";
      out[k] = (out[k] || 0) + 1;
    }
    return out;
  }
  function rowsFromTally(t) {
    var rows = [], keys = Object.keys(t).sort();
    for (var i = 0; i < keys.length; i++) rows.push([keys[i], t[keys[i]]]);
    return rows;
  }
  // Egress entries are "<kind>:{...}" strings, so the kind tally is the whole
  // story: what left the seal, and how much of each.
  function egressRows(d) {
    var list = d.entries || [];
    var kinds = {};
    for (var i = 0; i < list.length; i++) {
      var k = String(list[i]).split(":")[0];
      kinds[k] = (kinds[k] || 0) + 1;
    }
    return [["records", list.length]].concat(rowsFromTally(kinds));
  }

  var BOXES = [
    { id: "coordinator.contributions", vm: "core", svc: "fabric-coordinator", port: 30080,
      title: "Open needs contributing", tier: "slow", url: "core/30080/v1/needs/contributions",
      note: "The only window onto open needs: a consent-gated count. Their content is not enumerable anywhere.",
      pick: function (d) { return [["contributions", n(d.contributions)]]; } },

    { id: "ledger.verify", vm: "core", svc: "ledger-svc", port: 30081,
      title: "Hash chains", tier: "fast", url: "core/30081/v1/verify",
      note: "Three append-only chains, re-verified end to end on every poll.",
      pick: function (d) {
        return [["attestation", n(d.attestation_len) + (d.attestation_ok ? " [OK]" : " [X]")],
                ["settlement", n(d.settlement_len) + (d.settlement_ok ? " [OK]" : " [X]")],
                ["consent", n(d.consent_len) + (d.consent_ok ? " [OK]" : " [X]")]];
      } },

    { id: "ledger.consent.maya", vm: "core", svc: "ledger-svc", port: 30081,
      title: "Consent - buyer pseudonym", tier: "fast",
      url: function () { return subjects.maya ? "core/30081/v1/consents/subject/" + subjects.maya : null; },
      note: "Mandate and disclosure grants land on this chain too -- the events are public, their scopes are not.",
      pick: function (d) {
        return [["participation", d.participation || "--"],
                ["contribution", d.contribution || "--"],
                ["history", len(d.history)]];
      } },

    { id: "ledger.settlement.last", vm: "core", svc: "ledger-svc", port: 30081,
      title: "Latest settlement", tier: "lazy",
      url: function () {
        var keys = ["s008_case" in state ? "s001_match" : null, "s007_match", "s005_match", "s004_match", "s002_match", "s001_match"];
        for (var i = 0; i < keys.length; i++) { if (keys[i] && state[keys[i]]) return "core/30081/v1/settlements/match/" + state[keys[i]]; }
        return null;
      },
      note: "Split across seller, network, platform -- and the ad parties when a campaign funded the match.",
      pick: function (d) {
        return [["value", money(d.value_cents)],
                ["confirmed", d.confirmed ? "yes" : "no"],
                ["entries", len(d.entries)],
                ["net", money(d.total_cents)]];
      } },

    { id: "seller.orders", vm: "core", svc: "seller-svc", port: 30083,
      title: "Order board", tier: "fast", url: "core/30083/v1/orders",
      note: "Every order carries a match id and the context line the buyer chose to share -- never who she is.",
      pick: function (d) {
        var rows = [["orders", n(d.count)]];
        return rows.concat(rowsFromTally(tally(d.orders, "state")));
      } },

    { id: "seller.catalog.a", vm: "core", svc: "seller-svc", port: 30083,
      title: "Matchable catalog - region-a", tier: "fast", url: "core/30083/v1/offers/region/region-a",
      note: "Zero-stock offers are filtered out here -- the ERP's truth, applied silently.",
      pick: function (d) { return [["offers", len(d.offers)]]; } },

    { id: "seller.catalog.b", vm: "core", svc: "seller-svc", port: 30083,
      title: "Matchable catalog - region-b", tier: "slow", url: "core/30083/v1/offers/region/region-b",
      pick: function (d) { return [["offers", len(d.offers)]]; } },

    { id: "resource.edges", vm: "core", svc: "resource-svc", port: 30082,
      title: "Edge fleet", tier: "fast", url: "core/30082/v1/edges",
      pick: function (d) {
        var rows = [], list = d.edges || [];
        for (var i = 0; i < list.length; i++) rows.push([list[i].region, "cap " + n(list[i].capacity)]);
        return rows.length ? rows : [["registered", 0]];
      } },

    { id: "resource.telemetry", vm: "core", svc: "resource-svc", port: 30082,
      title: "Slice lifecycle telemetry", tier: "fast", url: "core/30082/v1/telemetry",
      note: "Mirrored from the sealed slices: created, attested, executed, destroyed -- and aborted.",
      pick: function (d) {
        var list = d.entries || [];
        var rows = [["events", list.length]];
        return rows.concat(rowsFromTally(tally(list, "event")));
      } },

    { id: "resource.incidents", vm: "core", svc: "resource-svc", port: 30082,
      title: "Operator incidents", tier: "fast", url: "core/30082/v1/incidents",
      pick: function (d) { return [["incidents", len(d.incidents)]]; } },

    { id: "insights.workbench", vm: "core", svc: "insights-svc", port: 30085,
      title: "Demand workbench", tier: "fast", url: "core/30085/v1/workbench",
      note: "Cells below the anonymity threshold are ABSENT here, not zeroed -- suppression you can see by what is missing.",
      pick: function (d) {
        var rows = [["threshold", n(d.threshold)]], cells = d.aggregates || [];
        for (var i = 0; i < cells.length; i++) {
          rows.push([(cells[i].category || "?") + " - " + (cells[i].region || "?"), n(cells[i].needs)]);
        }
        if (!cells.length) rows.push(["cells above it", 0]);
        return rows;
      } },

    { id: "insights.aggregates", vm: "core", svc: "insights-svc", port: 30085,
      title: "Aggregation cycles", tier: "slow", url: "core/30085/v1/aggregates",
      pick: function (d) {
        return [["cycles", n(d.cycles)],
                ["last contributions", d.latest_contributions === null || d.latest_contributions === undefined
                  ? "--" : d.latest_contributions]];
      } },

    { id: "insights.unmet", vm: "core", svc: "insights-svc", port: 30085,
      title: "Unmet demand", tier: "slow", url: "core/30085/v1/unmet-demand",
      pick: function (d) { return [["flags", len(d.unmet)]]; } },

    { id: "platform.incidents", vm: "core", svc: "platform-svc", port: 30086,
      title: "Cross-party cases", tier: "fast", url: "core/30086/v1/incidents",
      pick: function (d) { return [["cases", len(d.cases)]]; } },

    { id: "platform.disclosure", vm: "core", svc: "platform-svc", port: 30086,
      title: "Support disclosure", tier: "lazy",
      url: function () { return state.s008_case ? "core/30086/v1/support/cases/" + state.s008_case + "/disclosure" : null; },
      note: "The status IS the story: 404 not requested - 200 granted - 410 the access path is gone.",
      statusIsValue: true,
      pick: function (d, status) {
        var label = status === 410 ? "EXPIRED (410)"
          : status === 200 ? "granted (200)"
          : status === 404 ? "not requested (404)"
          : String(status);
        var rows = [["access", label]];
        // The 200 body carries only the artifact; the countdown is the grant
        // TTL captured when Maya signed it.
        if (status === 200 && state.s008_expiry) {
          var left = Math.max(0, Math.ceil((state.s008_expiry - Date.now()) / 1000));
          rows.push(["expires in", left + "s"]);
        }
        return rows;
      } },

    { id: "ads.briefs", vm: "core", svc: "ads-svc", port: 30087,
      title: "Open creative briefs", tier: "fast", url: "core/30087/v1/briefs",
      pick: function (d) { return [["open", len(d.briefs)]]; } },

    { id: "ads.campaign", vm: "core", svc: "ads-svc", port: 30087,
      title: "Campaign pacing", tier: "lazy",
      url: function () { return state.s005_campaign ? "core/30087/v1/campaigns/" + state.s005_campaign : null; },
      note: "Targeting is a region and a category. No individual was ever addressable.",
      pick: function (d) {
        return [["state", d.state || "--"],
                ["budget left", money(n(d.budget_cents) - n(d.spent_cents))],
                ["per match", money(d.ad_cents_per_match)]];
      } },

    { id: "ads.attributions", vm: "core", svc: "ads-svc", port: 30087,
      title: "Attribution", tier: "fast", url: "core/30087/v1/attributions",
      note: "Credit by campaign and asset id. Zero buyer signal on the campaign side.",
      pick: function (d) {
        return [["closed matches", n(d.closed_matches)],
                ["agency", money(d.agency_cents_total)],
                ["creator", money(d.creator_cents_total)]];
      } },

    { id: "connect.deltas", vm: "core", svc: "connect-svc", port: 30088,
      title: "ERP inventory deltas", tier: "fast", url: "core/30088/v1/deltas",
      pick: function (d) { return [["deltas", len(d.deltas)]]; } },

    { id: "connect.audit", vm: "core", svc: "connect-svc", port: 30088,
      title: "Refused out-of-scope calls", tier: "fast", url: "core/30088/v1/audit",
      note: "The scope ceiling, logged. Partner records and credentials themselves are not listable.",
      pick: function (d) { return [["refused", len(d.audit)]]; } },

    { id: "connect.erp", vm: "core", svc: "connect-svc", port: 30088,
      title: "ERP mirror", tier: "lazy",
      url: function () { return state.s007_match ? "core/30088/v1/erp/orders/" + state.s007_match : null; },
      pick: function (d) { return [["state", d.state || "--"]]; } },

    { id: "audit.accesslog", vm: "core", svc: "audit-svc", port: 30089,
      title: "Auditor access log", tier: "fast", url: "core/30089/v1/access-log",
      note: "Verified about the verifier: every certification access is a read.",
      pick: function (d) {
        var list = d.access || [];
        var allGet = true;
        for (var i = 0; i < list.length; i++) { if (list[i].method !== "GET") allGet = false; }
        return [["accesses", list.length], ["all reads", list.length ? (allGet ? "yes" : "NO") : "--"]];
      } },

    { id: "identity.presence", vm: "core", svc: "identity-mock", port: 30084,
      title: "Identity service", tier: "slow", url: "core/30084/health",
      note: "Knows the login -- by design, and nothing downstream does. Issued tokens are deliberately not listable.",
      pick: function (d) { return [["status", (d && d.status) || "up"]]; } },

    { id: "edge-a.runtime", vm: "edge-a", svc: "slice-runtime", port: 8080,
      title: "Slice runtime", tier: "fast", url: "edge-a/v1/egress", presence: true,
      note: "The sealed environment host: creates, attests, opens, destroys -- per match.",
      pick: function (d) { return [["reachable", "yes"]]; } },

    { id: "edge-a.egress", vm: "edge-a", svc: "slice-runtime", port: 8080,
      title: "Egress - what left the seal", tier: "fast", url: "edge-a/v1/egress",
      note: "Attestations, telemetry, settlement instructions, and match records carrying her chosen context line.",
      pick: function (d) { return egressRows(d); } },

    { id: "edge-a.ingress", vm: "edge-a", svc: "slice-runtime", port: 8080,
      title: "Ingress - what entered the seal", tier: "fast", url: "edge-a/v1/ingress",
      note: "Campaign creatives only. Her envelope is never logged here -- it exists in flight and inside the environment, nowhere else.",
      pick: function (d) { return [["records", len(d.entries)]]; } },

    { id: "edge-b.runtime", vm: "edge-b", svc: "slice-runtime", port: 8080,
      title: "Slice runtime", tier: "slow", url: "edge-b/v1/egress", presence: true,
      note: "Registered, standing by -- sovereignty means this jurisdiction's traffic never arrives here.",
      pick: function (d) { return [["reachable", "yes"]]; } },

    { id: "edge-b.egress", vm: "edge-b", svc: "slice-runtime", port: 8080,
      title: "Egress - what left the seal", tier: "slow", url: "edge-b/v1/egress",
      pick: function (d) { return egressRows(d); } },

    { id: "edge-b.ingress", vm: "edge-b", svc: "slice-runtime", port: 8080,
      title: "Ingress - what entered the seal", tier: "slow", url: "edge-b/v1/ingress",
      pick: function (d) { return [["records", len(d.entries)]]; } }
  ];

  function boxById(id) {
    for (var i = 0; i < BOXES.length; i++) { if (BOXES[i].id === id) return BOXES[i]; }
    return null;
  }

  // --- REGION: privacy scanner
  // Two different questions, deliberately kept apart.
  //
  // Identity: the buyer-side logins and PII field names must appear in NO lab
  // response, ever. Whole-word matching keeps 'pat' out of 'participation';
  // supply-side names are excluded on purpose - 'elena-atelier' is a public
  // tenant id and 'kai' a public creator credit, both catalog data rather than
  // anything about a buyer.
  //
  // Shared context: the one-line summary she wrote DOES travel, to the
  // seller's order board and the egress log, because it is the half of the
  // envelope she chose to share. Counting where it appears next to a zero
  // identity count is the whole thesis.
  var IDENTITY_MARKERS = ["maya", "pat"];
  var PII_KEYS = /"(full_?name|given_?name|surname|address|email|phone|postcode|zip)"\s*:/i;
  var CONTEXT_MARKERS = ["wedding", "anniversary", "warm-weather", "office"];

  var identityRe = [];
  (function () {
    for (var i = 0; i < IDENTITY_MARKERS.length; i++) {
      identityRe.push({ m: IDENTITY_MARKERS[i], re: new RegExp("\\b" + IDENTITY_MARKERS[i] + "\\b", "i") });
    }
  })();

  function scanIdentity(text) {
    for (var i = 0; i < identityRe.length; i++) {
      if (identityRe[i].re.test(text)) return identityRe[i].m;
    }
    if (PII_KEYS.test(text)) return "PII field";
    return null;
  }
  function scanContext(text) {
    var lower = text.toLowerCase();
    for (var i = 0; i < CONTEXT_MARKERS.length; i++) {
      if (lower.indexOf(CONTEXT_MARKERS[i]) >= 0) return CONTEXT_MARKERS[i];
    }
    return null;
  }

  // --- REGION: journal client
  // One writer (the action window), any number of readers. A 'latest' below
  // our cursor means this server process restarted and its in-memory journal
  // is gone, so every derived view must be rebuilt rather than left frozen.
  // One poll at a time: the interval keeps ticking while the server is slow
  // to answer, and a second request from the same cursor would hand the same
  // events over twice. Anything at or below the cursor has been handed over
  // already, so a late or overlapping answer delivers nothing twice.

  var journal = {
    cursor: 0,
    timer: null,
    polling: false,
    onEvents: null,
    onReset: null,
    async append(event) {
      try {
        var res = await fetch("/api/journal", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(event)
        });
        return res.ok;
      } catch (e) { return false; }
    },
    async reset() {
      try {
        // An explicit body, so the request always carries a content length:
        // HttpListener answers 411 on its own for a POST that has neither.
        await fetch("/api/journal/reset", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: "{}"
        });
        return true;
      } catch (e) { return false; }
    },
    async poll() {
      if (this.polling) return;
      this.polling = true;
      try {
        var payload;
        try {
          var res = await fetch("/api/journal?since=" + this.cursor);
          payload = await res.json();
        } catch (e) { return; }
        if (!payload) return;
        if (typeof payload.latest === "number" && payload.latest < this.cursor) {
          this.cursor = 0;
          if (this.onReset) this.onReset("server restarted");
          try {
            var again = await fetch("/api/journal?since=0");
            payload = await again.json();
          } catch (e2) { return; }
        }
        var events = (payload && payload.events) || [];
        if (!events.length) return;
        var forward = [];
        for (var i = 0; i < events.length; i++) {
          if (!(events[i].seq > this.cursor)) continue;
          this.cursor = events[i].seq;
          if (events[i].kind === "reset") {
            if (this.onReset) this.onReset("demo reset");
            forward = [];
          } else {
            forward.push(events[i]);
          }
        }
        if (forward.length && this.onEvents) this.onEvents(forward);
      } finally {
        this.polling = false;
      }
    },
    start(intervalMs) {
      var self = this;
      if (self.timer) clearInterval(self.timer);
      self.poll();
      self.timer = setInterval(function () { self.poll(); }, intervalMs || 1000);
    }
  };

  // --- REGION: swimlane renderer
  // Both windows draw the same chart from the same data: the action window at
  // full size and interactive, the data window as a compact read-only strip so
  // a single projector still carries the parallel-persona picture.

  var ACT_CLASS = { I: "", II: "a2", III: "a3" };

  function buildTimeline(host, opts) {
    opts = opts || {};
    var mini = !!opts.mini;
    var statuses = opts.statuses || {};
    var selected = opts.selected || null;
    var current = opts.current || null;

    host.innerHTML = "";
    host.className = "tl-wrap" + (mini ? " tl--mini" : "");
    var inner = document.createElement("div");

    // Scenario header strip: each block is exactly as wide as its steps.
    var scen = document.createElement("div");
    scen.className = "tl-scen";
    for (var i = 0; i < SCENARIOS.length; i++) {
      var sc = SCENARIOS[i];
      var count = 0;
      for (var j = 0; j < STEPS.length; j++) { if (STEPS[j].scenario === sc.id) count++; }
      var cellW = mini ? 9 : 44;
      var blk = document.createElement("div");
      blk.className = "tl-sc";
      blk.style.width = (count * cellW) + "px";
      blk.style.minWidth = (count * cellW) + "px";
      blk.style.borderTop = "2px solid " + (sc.act === "I" ? "var(--act-1)" : sc.act === "II" ? "var(--act-2)" : "var(--act-3)");
      blk.textContent = mini ? sc.id : sc.id.replace("s00", "s");
      blk.title = sc.name;
      scen.appendChild(blk);
    }
    inner.appendChild(scen);

    for (var p = 0; p < PERSONA_ORDER.length; p++) {
      var key = PERSONA_ORDER[p];
      var lane = document.createElement("div");
      lane.className = "tl-lane";

      var label = document.createElement("div");
      label.className = "tl-label" + (opts.activePersona === key ? " on" : "");
      label.textContent = mini ? PERSONAS[key].name.slice(0, 3) : PERSONAS[key].name;
      lane.appendChild(label);

      var cells = document.createElement("div");
      cells.className = "tl-cells";
      for (var s = 0; s < STEPS.length; s++) {
        var step = STEPS[s];
        var cell = document.createElement(mini ? "div" : "button");
        var cls = ["tl-cell", ACT_CLASS[actOf(step)]];
        if (step.persona !== key) {
          cls.push("empty");
          cell.setAttribute("aria-hidden", "true");
        } else {
          var st = statuses[step.id];
          if (!st) cls.push("ghost");
          else if (st === "fail") cls.push("failed");
          else if (st === "refused-pass") cls.push("refused");
          else cls.push("done");
          if (step.optional) cls.push("opt");
          if (current === step.id) cls.push("cur");
          if (selected === step.id) cls.push("sel");
          cell.title = step.scenario + " - " + PERSONAS[key].name + " - " + step.label +
            (step.optional ? " (optional)" : "") +
            (opts.times && opts.times[step.id] ? "\n" + opts.times[step.id] : "");
          if (!mini) {
            cell.type = "button";
            cell.setAttribute("data-step", step.id);
          }
        }
        cell.className = cls.join(" ");
        cells.appendChild(cell);
      }
      lane.appendChild(cells);
      inner.appendChild(lane);
    }
    host.appendChild(inner);
  }

  // --- REGION: misc
  function hhmmss(ms) {
    var d = new Date(ms);
    var p = function (x) { return (x < 10 ? "0" : "") + x; };
    return p(d.getHours()) + ":" + p(d.getMinutes()) + ":" + p(d.getSeconds());
  }
  function escapeHtml(s) {
    return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  }
  async function fetchJson(url) {
    try {
      var res = await fetch(url);
      return await res.json();
    } catch (e) { return null; }
  }

  return {
    PERSONAS: PERSONAS, PERSONA_ORDER: PERSONA_ORDER, ACTS: ACTS,
    SCENARIOS: SCENARIOS, STEPS: STEPS, NOTEBOOK: NOTEBOOK,
    BOXES: BOXES, boxById: boxById,
    state: state, done: done, save: save, clearLocal: clearLocal,
    topo: topo, subjects: subjects,
    call: call, post: post, get: get, token: token, mk: AmisAdScript.mk, offer: AmisAdScript.offer,
    deepFind: AmisAdScript.deepFind, deepFindAll: AmisAdScript.deepFindAll,
    hooks: hooks,
    scenarioById: scenarioById, stepById: stepById, actOf: actOf,
    missingNeeds: missingNeeds, verdictFor: verdictFor,
    scanIdentity: scanIdentity, scanContext: scanContext,
    CONTEXT_MARKERS: CONTEXT_MARKERS, IDENTITY_MARKERS: IDENTITY_MARKERS,
    journal: journal, buildTimeline: buildTimeline,
    hhmmss: hhmmss, escapeHtml: escapeHtml, fetchJson: fetchJson
  };
})();
