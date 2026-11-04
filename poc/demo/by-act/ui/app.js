// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 425c9590-1065-4d9b-9242-30b1a9023151
// AmisAd demo console: persona dropdown drives per-scenario step buttons,
// each a real API call through serve-by-act.ps1's same-origin proxy. The
// cast and the steps are common/scenario-script.js, which the data-view demo
// runs too and which index.html loads first. Full behavior:
// ../README.md#how-it-works

"use strict";

// --- REGION: personas
const { PERSONAS, ACTS, SCENARIOS, NOTEBOOK } = AmisAdScript;

// --- REGION: state
const load = (k, d) => { try { return JSON.parse(localStorage.getItem(k)) ?? d; } catch { return d; } };
const state = load("amisad-demo-state", {});
const done = load("amisad-demo-done", {});
const save = () => {
  localStorage.setItem("amisad-demo-state", JSON.stringify(state));
  localStorage.setItem("amisad-demo-done", JSON.stringify(done));
};

const topo = { core: "", edgeA: "", edgeB: "" };
let currentPersona = "";

// --- REGION: plumbing
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

// --- REGION: the script
const STEPS = AmisAdScript.steps({ state, post, get, token, topo });

// --- REGION: rendering
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

// --- REGION: boot
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
    Object.assign(topo, t);
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
