// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// The data window: the live state of the three lab VMs while the scenarios
// run. Strictly read-only against the lab - it issues GET requests only, never
// a POST, not even the state-reporting ones, because several of those write
// (an aggregation cycle records itself, certification appends to the auditor's
// access log, minting a token accumulates one). A dashboard must not change
// what it observes.
//
// One sequential pump issues a single lab request at a time: the demo server
// handles requests one by one, and the action window's step POSTs share it.
// The 1s journal poll is the only concurrent request, and it never touches the
// lab.

"use strict";

(function () {
  var $ = function (sel) { return document.querySelector(sel); };

  var SWEEP_SPACING_MS = 150;
  var FAST_PERIOD_MS = 4000;
  var SLOW_PERIOD_MS = 12000;

  var boxState = {};   // id -> { rows, prevRows, status, stale, attribution, flashUntil, lastAt }
  var pending = [];    // ids queued ahead of the regular cadence
  var lastRun = {};    // id -> timestamp of last poll
  var statuses = {};   // step id -> status, for the mini timeline
  var times = {};
  var vms = [];
  var health = {};     // "core:30080" / "edge-a" -> boolean
  var ticker = [];

  var scan = { responses: 0, bytes: 0, identityHits: 0, identityWhat: "", contextHits: 0, contextWhere: {} };

  // --- scanning ---------------------------------------------------------
  // Runs over every lab response the pump receives. Host-side endpoints are
  // never scanned: /api/personas is the operator's own vault view, and
  // /api/journal legitimately carries persona labels for the UI.
  function scanResponse(url, text) {
    if (!text) return;
    scan.responses++;
    scan.bytes += text.length;
    var id = AD.scanIdentity(text);
    if (id) {
      scan.identityHits++;
      if (!scan.identityWhat) scan.identityWhat = id + " in " + url;
    }
    var ctx = AD.scanContext(text);
    if (ctx) {
      scan.contextWhere[url.split("/").slice(0, 3).join("/")] = true;
      scan.contextHits = Object.keys(scan.contextWhere).length;
    }
  }

  function renderStrip() {
    $("#subject-hash").textContent = AD.subjects.maya || "...";

    var idCell = $("#sc-identity");
    var idBig = $("#identity-count");
    if (scan.identityHits > 0) {
      idCell.className = "sc alarm";
      idBig.textContent = scan.identityHits + " hit" + (scan.identityHits === 1 ? "" : "s");
      $("#identity-sub").textContent = scan.identityWhat;
    } else {
      idCell.className = "sc green";
      idBig.textContent = "0 hits";
      $("#identity-sub").textContent = scan.responses + " responses - " +
        Math.round(scan.bytes / 1024) + " KB scanned";
    }

    $("#context-count").textContent = scan.contextHits + " place" + (scan.contextHits === 1 ? "" : "s");
    $("#context-sub").textContent = scan.contextHits
      ? Object.keys(scan.contextWhere).join(" - ")
      : "nothing shared yet";
  }

  // --- polling ----------------------------------------------------------

  function urlFor(box) {
    return typeof box.url === "function" ? box.url() : box.url;
  }

  async function pollBox(box) {
    var url = urlFor(box);
    if (!url) return;                    // a lazy box whose id is not captured yet
    var st = boxState[box.id] || (boxState[box.id] = { rows: [], attribution: "", flashUntil: 0 });
    var res;
    try {
      res = await fetch("/api/" + url);
    } catch (e) {
      st.stale = "unreachable";
      lastRun[box.id] = Date.now();
      return;
    }
    var text = "";
    try { text = await res.text(); } catch (e2) { text = ""; }
    scanResponse(url, text);
    lastRun[box.id] = Date.now();

    var data = null;
    try { data = JSON.parse(text); } catch (e3) { data = null; }

    // A box whose status IS the value (the disclosure trichotomy) reads a 404
    // or 410 as content, not as failure.
    if (!box.statusIsValue && (res.status >= 400 || res.status === 0)) {
      st.stale = "HTTP " + res.status;
      return;
    }
    st.stale = null;
    st.status = res.status;

    var rows;
    try {
      rows = box.presence ? [["reachable", "yes"]] : box.pick(data || {}, res.status);
    } catch (e4) {
      rows = [["parse", "unreadable"]];
    }

    var before = JSON.stringify(st.rows || []);
    var after = JSON.stringify(rows);
    if (before !== "[]" && before !== after) {
      st.flashUntil = Date.now() + 1600;
      st.deltas = deltasBetween(st.rows, rows);
      if (st.pendingAttribution) {
        st.attribution = st.pendingAttribution;
        st.pendingAttribution = null;
      }
    }
    st.rows = rows;
  }

  function deltasBetween(oldRows, newRows) {
    var out = {};
    var prev = {};
    for (var i = 0; i < (oldRows || []).length; i++) prev[oldRows[i][0]] = oldRows[i][1];
    for (var j = 0; j < newRows.length; j++) {
      var k = newRows[j][0], nv = newRows[j][1], ov = prev[k];
      if (typeof nv === "number" && typeof ov === "number" && nv !== ov) {
        out[k] = (nv > ov ? "+" : "") + (nv - ov);
      }
    }
    return out;
  }

  function due(box, now) {
    var period = box.tier === "slow" ? SLOW_PERIOD_MS : FAST_PERIOD_MS;
    return (now - (lastRun[box.id] || 0)) >= period;
  }

  async function pumpOnce() {
    var now = Date.now();
    var box = null;
    while (pending.length && !box) {
      var id = pending.shift();
      box = AD.boxById(id);
    }
    if (!box) {
      var candidates = [];
      for (var i = 0; i < AD.BOXES.length; i++) {
        if (due(AD.BOXES[i], now) && urlFor(AD.BOXES[i])) candidates.push(AD.BOXES[i]);
      }
      // Oldest first, so nothing starves behind the fast tier.
      candidates.sort(function (a, b) { return (lastRun[a.id] || 0) - (lastRun[b.id] || 0); });
      box = candidates[0];
    }
    if (box) {
      await pollBox(box);
      renderBoxes();
      renderStrip();
    }
  }

  // VM power state and the per-service health dots ride the same pump at the
  // slow cadence; a health probe going 502 through the proxy is exactly the
  // "process is down" signal the room needs, and proves reachability along the
  // path the demo itself uses.
  var lastVmAt = 0;
  async function pumpVms() {
    if (Date.now() - lastVmAt < SLOW_PERIOD_MS) return;
    lastVmAt = Date.now();
    var report = await AD.fetchJson("/api/vms");
    if (report) vms = report;
    var ports = [30080, 30081, 30082, 30083, 30084, 30085, 30086, 30087, 30088, 30089];
    for (var i = 0; i < ports.length; i++) {
      var ok = false;
      try {
        var r = await fetch("/api/core/" + ports[i] + "/health");
        ok = r.ok;
      } catch (e) { ok = false; }
      health["core:" + ports[i]] = ok;
    }
    var edges = ["edge-a", "edge-b"];
    for (var e = 0; e < edges.length; e++) {
      var up = false;
      try {
        var re = await fetch("/api/" + edges[e] + "/health");
        up = re.ok;
      } catch (e2) { up = false; }
      health[edges[e]] = up;
    }
    renderVms();
  }

  // --- journal ----------------------------------------------------------

  function onEvents(events) {
    for (var i = 0; i < events.length; i++) {
      var ev = events[i];
      if (ev.kind === "note") {
        ticker.unshift(AD.hhmmss(ev.ts) + "  " + ev.text);
        continue;
      }
      if (ev.kind !== "step" || !ev.step) continue;
      var s = ev.step;
      statuses[s.id] = s.status;
      times[s.id] = AD.hhmmss(ev.ts) + " - " + (s.duration_ms || 0) + "ms";
      if (s.captured) {
        for (var k in s.captured) {
          if (Object.prototype.hasOwnProperty.call(s.captured, k)) AD.state[k] = s.captured[k];
        }
      }
      var who = (AD.PERSONAS[s.persona] || { name: s.persona }).name;
      ticker.unshift(AD.hhmmss(ev.ts) + "  " + s.id + "  " + who + " -- " + s.label +
        (s.status === "fail" ? "  [FAILED]" : s.status === "refused-pass" ? "  [refused, as designed]" : ""));
      // Fast-poll exactly what this step can have changed, and hold the
      // attribution until the value actually moves - so the line always names
      // the step that caused the number on screen.
      var touches = s.touches || [];
      for (var t = 0; t < touches.length; t++) {
        var bs = boxState[touches[t]] || (boxState[touches[t]] = { rows: [], attribution: "", flashUntil: 0 });
        bs.pendingAttribution = who + " -- " + s.label;
        if (pending.indexOf(touches[t]) < 0) pending.push(touches[t]);
      }
    }
    while (ticker.length > 8) ticker.pop();
    renderMini();
    renderTicker();
  }

  function onJournalReset() {
    statuses = {};
    times = {};
    ticker = [];
    scan = { responses: 0, bytes: 0, identityHits: 0, identityWhat: "", contextHits: 0, contextWhere: {} };
    AD.clearLocal();
    for (var id in boxState) {
      if (!Object.prototype.hasOwnProperty.call(boxState, id)) continue;
      boxState[id].attribution = "";
      boxState[id].pendingAttribution = null;
      boxState[id].deltas = null;
    }
    renderStrip();
    renderMini();
    renderTicker();
    renderBoxes();
  }

  // --- rendering --------------------------------------------------------

  function renderVms() {
    var host = $("#vms");
    var byName = { "amisad-core": "core", "amisad-edge-a": "edge-a", "amisad-edge-b": "edge-b" };
    var html = "";
    var names = ["amisad-core", "amisad-edge-a", "amisad-edge-b"];
    for (var i = 0; i < names.length; i++) {
      var name = names[i];
      var vm = null;
      for (var v = 0; v < vms.length; v++) { if (vms[v].name === name) vm = vms[v]; }
      var vmState = vm ? vm.state : "unknown";
      var led = vmState === "running" ? "up" : (vmState === "unknown" ? "" : "down");
      html += '<div class="vm"><div class="vm-top"><span class="led ' + led + '"></span>' +
        '<span class="vm-name">' + name + "</span>" +
        '<span class="vm-ip">' + ((vm && vm.ip) || "--") + "</span>" +
        '<span class="vm-ip">' + vmState + "</span></div>";
      html += '<div class="dots">';
      if (byName[name] === "core") {
        var ports = [30080, 30081, 30082, 30083, 30084, 30085, 30086, 30087, 30088, 30089];
        for (var p = 0; p < ports.length; p++) {
          var st = health["core:" + ports[p]];
          html += '<span class="dot ' + (st === true ? "up" : st === false ? "down" : "") +
            '" title="' + ports[p] + '"></span>';
        }
        html += '</div><div class="vm-cap">ten services answering on their NodePorts</div>';
      } else {
        var es = health[byName[name]];
        html += '<span class="dot ' + (es === true ? "up" : es === false ? "down" : "") + '"></span>';
        html += "</div><div class=\"vm-cap\">" +
          (byName[name] === "edge-a"
            ? "sealed environments run here"
            : "registered, standing by -- sovereignty keeps this jurisdiction's traffic away") +
          "</div>";
      }
      html += "</div>";
    }
    host.innerHTML = html;
  }

  var GROUPS = [
    { title: "amisad-core - the marketplace", vm: "core" },
    { title: "amisad-edge-a - the sealed slice", vm: "edge-a" },
    { title: "amisad-edge-b - the other jurisdiction", vm: "edge-b" }
  ];

  function renderBoxes() {
    var host = $("#boxes");
    var now = Date.now();
    var html = "";
    for (var g = 0; g < GROUPS.length; g++) {
      html += '<div class="grp">' + GROUPS[g].title + "</div>";
      for (var i = 0; i < AD.BOXES.length; i++) {
        var box = AD.BOXES[i];
        if (box.vm !== GROUPS[g].vm) continue;
        var st = boxState[box.id] || { rows: [], attribution: "" };
        var cls = "box";
        if (st.flashUntil > now) cls += " flash";
        if (st.stale) cls += " stale";
        html += '<div class="' + cls + '"><h4>' + AD.escapeHtml(box.title) + "</h4>" +
          '<div class="src">' + box.svc + " - " + box.port + (st.stale ? " - " + st.stale : "") + "</div>";
        var rows = st.rows || [];
        if (!rows.length) {
          html += '<div class="kv"><span>' + (urlFor(box) ? "waiting..." : "not yet in play") + "</span><span>--</span></div>";
        }
        for (var r = 0; r < rows.length; r++) {
          var d = st.deltas && st.deltas[rows[r][0]];
          html += '<div class="kv"><span>' + AD.escapeHtml(rows[r][0]) + "</span><span>" +
            AD.escapeHtml(rows[r][1]) + (d ? '<span class="delta">' + d + "</span>" : "") + "</span></div>";
        }
        if (box.note) html += '<div class="why">' + AD.escapeHtml(box.note) + "</div>";
        if (st.attribution) html += '<div class="attr">changed by ' + AD.escapeHtml(st.attribution) + "</div>";
        html += "</div>";
      }
    }
    host.innerHTML = html;
  }

  function renderMini() {
    AD.buildTimeline($("#mini"), { mini: true, statuses: statuses, times: times });
    var wrap = $("#mini");
    var last = wrap.querySelectorAll(".tl-cell.done, .tl-cell.refused, .tl-cell.failed");
    if (last.length) {
      var el = last[last.length - 1];
      wrap.scrollLeft = Math.max(0, el.offsetLeft - wrap.clientWidth / 2);
    }
  }

  function renderTicker() {
    var html = "";
    for (var i = 0; i < ticker.length; i++) html += "<div>" + AD.escapeHtml(ticker[i]) + "</div>";
    $("#ticker").innerHTML = html || "<div>waiting for the first step...</div>";
  }

  async function resetDemo() {
    if (!window.confirm(
      "Reset the demo?\n\n" +
      "Clears the timeline, captured ids and check-marks in EVERY open window.\n\n" +
      "The lab's own records (offers, orders, ledgers) are left untouched.")) return;
    await AD.journal.reset();
  }

  // --- boot -------------------------------------------------------------

  async function boot() {
    $("#reset-demo").onclick = resetDemo;

    var t = await AD.fetchJson("/api/topology");
    var el = $("#topology");
    if (t && t.core) {
      AD.topo.core = t.core; AD.topo.edgeA = t.edgeA; AD.topo.edgeB = t.edgeB;
      el.textContent = "core " + t.core + " - a " + (t.edgeA || "?") + " - b " + (t.edgeB || "?");
    } else {
      el.textContent = "amisad-core unresolved -- restart with -CoreIp";
      el.className = "chip bad";
    }
    var subj = await AD.fetchJson("/api/subjects");
    if (subj) { AD.subjects.maya = subj.maya; AD.subjects.pat = subj.pat; }

    AD.journal.onEvents = onEvents;
    AD.journal.onReset = onJournalReset;
    AD.journal.start(1000);

    renderStrip();
    renderVms();
    renderBoxes();
    renderMini();
    renderTicker();

    setInterval(function () {
      var d = new Date();
      var p = function (x) { return (x < 10 ? "0" : "") + x; };
      $("#clock").textContent = p(d.getHours()) + ":" + p(d.getMinutes()) + ":" + p(d.getSeconds());
    }, 1000);

    // The pump: one lab request at a time, spaced so a full fast sweep lands
    // in a few seconds without ever running two requests at once.
    (async function loop() {
      for (;;) {
        try {
          await pumpVms();
          await pumpOnce();
        } catch (e) { /* a bad poll must never stop the pump */ }
        await new Promise(function (r) { setTimeout(r, SWEEP_SPACING_MS); });
      }
    })();

    // Flash decay and the disclosure countdown both need a repaint per second.
    setInterval(function () { renderBoxes(); }, 1000);
  }

  boot();
})();
