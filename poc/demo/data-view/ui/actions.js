// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// The action window: draws the persona swimlane chart, runs the selected step
// against the live lab, and appends every outcome to the server journal so the
// data view - and any other open window, on any machine - stays in step.
// This window is the journal's only writer.

"use strict";

(function () {
  var $ = function (sel) { return document.querySelector(sel); };

  var currentPersona = "";
  var selectedId = null;
  var statuses = {};        // step id -> "ok" | "fail" | "refused-pass"
  var times = {};           // step id -> tooltip line
  var stepResults = {};     // step id -> { results, verdict }  (session only)
  var personaSecrets = {};
  var running = false;

  // --- journal fold -----------------------------------------------------
  // Everything on screen derives from journal events, so a reload or a second
  // window rebuilds the identical picture. localStorage is only a boot seed
  // for the notebook before the first poll lands.

  function applyEvent(ev) {
    if (ev.kind !== "step" || !ev.step) return;
    var s = ev.step;
    statuses[s.id] = s.status;
    if (s.status !== "fail") AD.done[s.id] = true;
    times[s.id] = AD.hhmmss(ev.ts) + " - " + (s.duration_ms || 0) + "ms";
    if (s.captured) {
      for (var k in s.captured) {
        if (Object.prototype.hasOwnProperty.call(s.captured, k)) AD.state[k] = s.captured[k];
      }
    }
  }

  function onEvents(events) {
    for (var i = 0; i < events.length; i++) applyEvent(events[i]);
    AD.save();
    render();
  }

  function onJournalReset() {
    statuses = {};
    times = {};
    stepResults = {};
    selectedId = null;
    AD.clearLocal();
    render();
  }

  // --- current / selection ---------------------------------------------

  function currentStepId() {
    for (var i = 0; i < AD.STEPS.length; i++) {
      var s = AD.STEPS[i];
      if (!s.optional && !statuses[s.id]) return s.id;
    }
    return null;
  }
  function activeStep() {
    if (selectedId) return AD.stepById(selectedId);
    var cur = currentStepId();
    return cur ? AD.stepById(cur) : AD.STEPS[AD.STEPS.length - 1];
  }
  function canRun(step) {
    if (!step) return false;
    if (running) return false;
    if (step.persona !== currentPersona) return false;
    return AD.missingNeeds(step).length === 0;
  }

  // --- running a step ---------------------------------------------------

  async function runStep(step, btn) {
    running = true;
    btn.disabled = true;
    btn.className = "busy";
    btn.textContent = "Running...";

    var calls = [];
    var unhook = AD.hooks.onCall;
    AD.hooks.onCall = function (method, url, status, text, data) {
      calls.push({ method: method, url: url, status: status });
      logLine(method, url, status);
      if (unhook) unhook(method, url, status, text, data);
    };

    // Several steps write notebook keys inside run() rather than through
    // capture(), so the journal's captured set is a before/after diff of the
    // whole notebook - instrumenting capture() alone would miss them.
    var before = JSON.parse(JSON.stringify(AD.state));
    var started = Date.now();
    var results = [];
    var verdict;
    try {
      results = await step.run();
      if (step.capture) {
        step.capture(results.map(function (r) { return r.data; }));
      }
      verdict = AD.verdictFor(step, results);
    } catch (e) {
      verdict = { ok: false, note: String((e && e.message) || e) };
    }
    var duration = Date.now() - started;
    AD.hooks.onCall = unhook;

    var captured = {};
    for (var k in AD.state) {
      if (!Object.prototype.hasOwnProperty.call(AD.state, k)) continue;
      if (JSON.stringify(AD.state[k]) !== JSON.stringify(before[k])) captured[k] = AD.state[k];
    }

    var status = verdict.ok ? (verdict.refused ? "refused-pass" : "ok") : "fail";
    stepResults[step.id] = { results: results, verdict: verdict };
    statuses[step.id] = status;
    if (status !== "fail") AD.done[step.id] = true;
    times[step.id] = AD.hhmmss(Date.now()) + " - " + duration + "ms";
    AD.save();

    await AD.journal.append({
      kind: "step",
      step: {
        id: step.id, scenario: step.scenario, persona: step.persona, label: step.label,
        status: status, note: verdict.note || "",
        started_ms: started, duration_ms: duration,
        calls: calls, touches: step.touches, captured: captured
      }
    });

    running = false;
    selectedId = null;
    render();
  }

  // --- rendering --------------------------------------------------------

  function logLine(method, url, status) {
    var el = document.createElement("div");
    el.className = "s" + String(status).charAt(0);
    el.textContent = AD.hhmmss(Date.now()) + "  " + method + " " + url + " -> " + status;
    var log = $("#log");
    log.insertBefore(el, log.firstChild);
    while (log.childElementCount > 200) log.removeChild(log.lastChild);
  }

  function renderTimeline() {
    var host = $("#timeline");
    AD.buildTimeline(host, {
      statuses: statuses,
      times: times,
      selected: selectedId,
      current: currentStepId(),
      activePersona: currentPersona
    });
    var cells = host.querySelectorAll("button[data-step]");
    for (var i = 0; i < cells.length; i++) {
      cells[i].onclick = function () {
        selectedId = this.getAttribute("data-step");
        var st = AD.stepById(selectedId);
        // Tapping someone else's slot switches to them: on a tablet that is
        // the fastest way to follow the script across lanes.
        if (st && st.persona !== currentPersona) {
          currentPersona = st.persona;
          $("#persona-select").value = currentPersona;
        }
        render();
      };
    }
    var cur = host.querySelector(".tl-cell.cur") || host.querySelector(".tl-cell.sel");
    if (cur && cur.scrollIntoView) {
      var wrap = host;
      var left = cur.offsetLeft - wrap.clientWidth / 2;
      if (wrap.scrollLeft !== undefined) wrap.scrollLeft = Math.max(0, left);
    }
  }

  function avatar(key, small) {
    return '<div class="avatar"' + (small ? ' style="width:34px;height:34px;line-height:34px;font-size:0.9rem"' : "") +
      ">" + AD.PERSONAS[key].name.charAt(0) + "</div>";
  }

  function renderIdentity() {
    var host = $("#identity");
    if (!currentPersona) {
      host.innerHTML = "<h2>Who is acting</h2><p class=\"hint\">Pick a persona above, or tap any slot in the chart " +
        "to jump to whoever acts there.</p>";
      return;
    }
    var p = AD.PERSONAS[currentPersona];
    var pw = personaSecrets[currentPersona];
    host.innerHTML = "<h2>Who is acting</h2>" +
      '<div class="who-row">' + avatar(currentPersona) +
      "<div><div style=\"font-weight:650\">" + p.name + '</div><div class="role">' + p.role + "</div></div></div>" +
      '<p class="hint">' + AD.escapeHtml(p.blurb) + "</p>" +
      '<div class="cred"><b>' + currentPersona + "</b>" +
      '<span id="pw" data-shown="0">********</span>' +
      '<button id="pw-toggle" type="button">show</button></div>' +
      '<p class="hint">Vault password for the VM account -- the console login this persona would really use.</p>';
    $("#pw-toggle").onclick = function () {
      var el = $("#pw");
      var shown = el.getAttribute("data-shown") === "1";
      el.textContent = shown ? "********" : (pw === undefined ? "<unavailable>" : pw);
      el.setAttribute("data-shown", shown ? "0" : "1");
      this.textContent = shown ? "show" : "hide";
    };
  }

  function renderRunner() {
    var host = $("#runner");
    if (!currentPersona) {
      var html = "<h2>The cast</h2><p class=\"hint\">Eleven people, one loop. Tap anyone to act as them -- " +
        "or open the <a href=\"/data\" target=\"_blank\" rel=\"noopener\">data view</a> on the projector first.</p>" +
        '<div class="cast">';
      for (var i = 0; i < AD.PERSONA_ORDER.length; i++) {
        var k = AD.PERSONA_ORDER[i];
        html += '<div class="member" data-persona="' + k + '">' + avatar(k, true) +
          '<span><div class="m-name">' + AD.PERSONAS[k].name + '</div><div class="m-role">' +
          AD.PERSONAS[k].role + "</div></span></div>";
      }
      host.innerHTML = html + "</div>";
      var members = host.querySelectorAll(".member");
      for (var m = 0; m < members.length; m++) {
        members[m].onclick = function () {
          currentPersona = this.getAttribute("data-persona");
          $("#persona-select").value = currentPersona;
          render();
        };
      }
      return;
    }

    var step = activeStep();
    if (!step) { host.innerHTML = "<h2>Runner</h2><p class=\"hint\">Nothing left to run.</p>"; return; }
    var sc = AD.scenarioById(step.scenario);
    var missing = AD.missingNeeds(step);
    var res = stepResults[step.id];
    var runnable = canRun(step);

    var h = "<h2>" + AD.ACTS[sc.act] + " - " + AD.escapeHtml(sc.name) + "</h2>" +
      '<div class="step-head"><span class="step-num">' + step.id + "</span>" +
      '<span class="step-label">' + AD.escapeHtml(step.label) + "</span>" +
      (step.optional ? '<span class="pill">optional</span>' : "") +
      (step.refusal ? '<span class="pill warn">refusal proves it</span>' : "") +
      (statuses[step.id] ? '<span class="pill ok">done</span>' : "") + "</div>" +
      '<p class="step-explain">' + AD.escapeHtml(step.explain) + "</p>" +
      '<div class="step-actions">';

    if (step.persona !== currentPersona) {
      h += '<button type="button" id="switch-to">Act as ' + AD.PERSONAS[step.persona].name + "</button>" +
        '<span class="hint">' + AD.PERSONAS[step.persona].name + " runs this step.</span>";
    } else {
      h += '<button type="button" id="run-step"' + (runnable ? "" : " disabled") + ">Run this step</button>";
      if (missing.length) {
        h += '<span class="missing">needs: ' + missing.map(function (k) { return AD.NOTEBOOK[k] || k; }).join(", ") + "</span>";
      }
    }
    h += '<button type="button" class="ghost" id="next-step" style="color:var(--ink);border-color:var(--line)">Next ></button>';
    h += "</div>";

    if (res) {
      h += '<div class="verdict ' + (res.verdict.ok ? "ok" : "bad") + '">' +
        (res.verdict.ok ? "[OK] " : "[X] ") + AD.escapeHtml(res.verdict.note || "Done.") + "</div>";
      h += '<div class="res">';
      for (var r = 0; r < res.results.length; r++) {
        var row = res.results[r];
        var cls = row.status >= 500 || row.status === 0 ? "bad" : row.status >= 400 ? "warn" : "ok";
        h += '<details class="res-row"><summary><span class="pill ' + cls + '">' + row.status + "</span>" +
          "<span>" + AD.escapeHtml(row.label) + "</span></summary><pre>" +
          AD.escapeHtml(JSON.stringify(row.data, null, 2)) + "</pre></details>";
      }
      h += "</div>";
    } else if (statuses[step.id]) {
      h += '<p class="hint">Ran in another window -- the chart carries the outcome; response bodies stay local to the ' +
        "window that clicked.</p>";
    }
    host.innerHTML = h;

    if ($("#switch-to")) {
      $("#switch-to").onclick = function () {
        currentPersona = step.persona;
        $("#persona-select").value = currentPersona;
        render();
      };
    }
    if ($("#run-step")) {
      $("#run-step").onclick = function () { runStep(step, this); };
    }
    $("#next-step").onclick = function () {
      var from = step.index;
      for (var i = from + 1; i < AD.STEPS.length; i++) {
        if (!statuses[AD.STEPS[i].id]) { selectedId = AD.STEPS[i].id; break; }
      }
      render();
    };
  }

  function renderNotebook() {
    var nb = $("#notebook");
    nb.innerHTML = "";
    var any = false;
    for (var key in AD.NOTEBOOK) {
      if (!Object.prototype.hasOwnProperty.call(AD.NOTEBOOK, key)) continue;
      var v = AD.state[key];
      if (v === undefined || v === null || v === "" || (Array.isArray(v) && !v.length)) continue;
      any = true;
      var el = document.createElement("div");
      el.className = "nb-chip";
      if (key === "s008_expiry") {
        var left = Math.ceil((v - Date.now()) / 1000);
        el.className += left > 0 ? " hot" : "";
        el.innerHTML = "<b>" + AD.NOTEBOOK[key] + "</b> " + (left > 0 ? left + "s left" : "expired");
      } else {
        el.innerHTML = "<b>" + AD.NOTEBOOK[key] + "</b> " + AD.escapeHtml(Array.isArray(v) ? v.join(", ") : v);
      }
      nb.appendChild(el);
    }
    if (!any) nb.innerHTML = '<p class="hint">Empty -- ids appear here as steps capture them.</p>';
  }

  function render() {
    renderTimeline();
    renderIdentity();
    renderRunner();
    renderNotebook();
  }

  // --- consent preflight ------------------------------------------------
  // The coordinator refuses a need with 403 whenever the newest consent entry
  // for the buyer's subject is a revoke, and that state is durable: a pause
  // left behind by an earlier run would 403 her very first step here. Repair
  // only what actually reads revoked, so the grant/revoke/re-grant history
  // s003 puts on screen stays clean.
  async function ensureBuyerConsents() {
    var st = await AD.post("core/30080/v1/consents/state", { token: await AD.token("maya") });
    if (st.status !== 200) return { ok: false, note: "consent state unavailable (" + st.status + ")" };
    var stale = [];
    var kinds = ["participation", "contribution"];
    for (var i = 0; i < kinds.length; i++) {
      if (st.data[kinds[i]] === "revoked") stale.push(kinds[i]);
    }
    if (!stale.length) return { ok: true, note: "consents ready" };
    for (var g = 0; g < stale.length; g++) {
      var r = await AD.post("core/30080/v1/consents",
        { token: await AD.token("maya"), grant_type: stale[g], action: "grant" });
      if (r.status !== 201) return { ok: false, note: "re-granting " + stale[g] + " failed (" + r.status + ")" };
    }
    return { ok: true, note: "re-granted " + stale.join(" + ") };
  }

  async function runPreflight() {
    var el = $("#consents");
    el.className = "chip";
    el.textContent = "checking consents...";
    if (!AD.topo.core) { el.textContent = ""; return; }
    try {
      var r = await ensureBuyerConsents();
      el.textContent = r.note;
      el.className = "chip " + (r.ok ? "good" : "bad");
      if (r.note !== "consents ready") {
        await AD.journal.append({ kind: "note", text: "consent preflight: " + r.note });
      }
    } catch (e) {
      el.textContent = "consent preflight failed";
      el.className = "chip bad";
    }
  }

  // --- reset ------------------------------------------------------------

  async function resetDemo() {
    if (!window.confirm(
      "Reset the demo?\n\n" +
      "Clears the timeline, captured ids and check-marks in EVERY open window, " +
      "and re-arms the buyer's participation consent so the next run cannot be refused.\n\n" +
      "The lab's own records (offers, orders, ledgers) are left untouched.")) return;
    var btn = $("#reset-demo");
    btn.disabled = true;
    btn.textContent = "Resetting...";
    AD.clearLocal();
    statuses = {};
    times = {};
    stepResults = {};
    selectedId = null;
    $("#log").innerHTML = "";
    await AD.journal.reset();
    await runPreflight();
    btn.disabled = false;
    btn.textContent = "Reset demo";
    render();
  }

  // --- boot -------------------------------------------------------------

  async function boot() {
    var sel = $("#persona-select");
    for (var i = 0; i < AD.PERSONA_ORDER.length; i++) {
      var k = AD.PERSONA_ORDER[i];
      var opt = document.createElement("option");
      opt.value = k;
      opt.textContent = AD.PERSONAS[k].name + " -- " + AD.PERSONAS[k].role;
      sel.appendChild(opt);
    }
    sel.onchange = function () { currentPersona = sel.value; selectedId = null; render(); };
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

    var list = await AD.fetchJson("/api/personas");
    if (list && list.length) {
      for (var p = 0; p < list.length; p++) personaSecrets[list[p].username] = list[p].password;
    }

    AD.journal.onEvents = onEvents;
    AD.journal.onReset = onJournalReset;
    AD.journal.start(1000);

    render();
    // The disclosure countdown is the only thing that changes on its own.
    setInterval(renderNotebook, 1000);
    await runPreflight();
  }

  boot();
})();
