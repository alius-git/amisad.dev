// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 42d63209-6571-443b-9644-51c65091a57c
// Both demo consoles run one scenario script, poc/demo/common/scenario-script.js:
// every page loads it first, neither console keeps a copy, each step runs
// through the transport and notebook a console hands it, and the file holds
// the Safari 13.1 baseline of the data-view pages that load it.
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const DEMO = path.join(__dirname, '../demo');
const SCRIPT = path.join(DEMO, 'common/scenario-script.js');
const read = (rel) => fs.readFileSync(path.join(DEMO, rel), 'utf8');

function load() {
  const context = {};
  vm.createContext(context);
  vm.runInContext(fs.readFileSync(SCRIPT, 'utf8'), context, { filename: SCRIPT });
  return context.AmisAdScript;
}

// Every notebook id a step can consume, so each step's run() is reachable.
const NOTEBOOK_SEED = {
  s001_handle: 'h1', s001_match: 'm1', s002_handle: 'h2', s002_match: 'm2', s003_handle: 'h3',
  s005_campaign: 'c5', s005_asset: 'a5', s005_handle: 'h5', s005_match: 'm5', s006_held: 'h6',
  s007_partner: 'p7', s007_cred: 'k7', s007_match: 'm7', s009_version: 'v9', s004_match: 'm4',
  s004_envs: ['e1', 'e2'], s004_case: 'c4', s008_case: 'c8', s008_expiry: 1
};

// A console's side of a run: its own notebook, topology and recording transport.
function consoleApi() {
  const calls = [];
  const answer = (method, url, body) => {
    calls.push({ method, url, body });
    // The tamper step flips a lifecycle field in the dump it fetches.
    const data = url === 'core/30081/v1/attestations'
      ? { entries: [{ lifecycle: 'created' }] }
      : { handle: 'handle-' + calls.length, match_id: 'match-' + calls.length, environment_id: 'env-' + calls.length };
    return Promise.resolve({ status: 201, data });
  };
  return {
    calls,
    api: {
      state: {},
      topo: { core: '', edgeA: '', edgeB: '' },
      post: (url, body) => answer('POST', url, body),
      get: (url) => answer('GET', url),
      token: (actor) => Promise.resolve('token-' + actor)
    }
  };
}

test('every page loads the shared script before its own scripts', () => {
  for (const page of ['by-act/ui/index.html', 'data-view/ui/actions.html', 'data-view/ui/data.html']) {
    const scripts = [...read(page).matchAll(/<script\b[^>]*>/g)].map((tag) => tag[0]);
    assert.ok(scripts.length > 1, page);
    assert.equal(scripts[0], '<script src="/common/scenario-script.js">', page);
  }
});

test('neither console keeps its own copy of the cast, the steps or their helpers', () => {
  for (const file of ['by-act/ui/app.js', 'data-view/ui/shared.js']) {
    const text = read(file);
    assert.doesNotMatch(text, /\b(const|var|let)\s+(PERSONAS|ACTS|SCENARIOS|NOTEBOOK|STEPS)\s*=\s*[[{]/, file);
    assert.doesNotMatch(text, /\bfunction\s+(deepFind|deepFindAll|mk|offer)\s*\(|\b(const|var|let)\s+(deepFind|deepFindAll|mk|offer)\s*=/, file);
    assert.match(text, /\bAmisAdScript\.steps\(/, file);
  }
});

test('every step runs through the console transport under a stable per-scenario id', async () => {
  const script = load();
  const { calls, api } = consoleApi();
  const steps = script.steps(api);
  assert.ok(steps.length > 0);
  const ids = steps.map((step) => step.id);
  assert.equal(new Set(ids).size, ids.length, 'step ids are unique');
  for (const id of ids) assert.match(id, /^s\d{3}-\d{2}$/);
  const scenarioIds = script.SCENARIOS.map((scenario) => scenario.id);
  for (const id of scenarioIds) assert.ok(steps.some((step) => step.scenario === id), 'no step in ' + id);
  for (const step of steps) {
    assert.ok(scenarioIds.includes(step.scenario), step.id);
    assert.ok(script.PERSONA_ORDER.includes(step.persona) && step.persona in script.PERSONAS, step.id);
    for (const need of step.needs || []) assert.ok(need in script.NOTEBOOK, step.id + ' needs ' + need);
    assert.ok(Array.isArray(step.touches), step.id);
  }
  // The topology arrives after the steps are built; a step reads it when it runs.
  Object.assign(api.topo, { core: '192.0.2.1', edgeA: '192.0.2.2', edgeB: '192.0.2.3' });
  Object.assign(api.state, NOTEBOOK_SEED);
  for (const step of steps) {
    const before = calls.length;
    const results = await step.run();
    assert.ok(Array.isArray(results) && results.length > 0, step.id);
    for (const result of results) assert.deepEqual(Object.keys(result), ['label', 'status', 'data'], step.id);
    assert.ok(calls.length > before, step.id + ' made no call');
    if (step.capture) step.capture(results.map((result) => result.data));
  }
  const edges = calls.filter((call) => call.url === 'core/30082/v1/edges').map((call) => call.body.endpoint);
  assert.deepEqual(edges, ['http://192.0.2.2:8080', 'http://192.0.2.3:8080']);
  // Captures land in the notebook the console handed over.
  assert.match(String(api.state.s001_match), /^match-\d+$/);
});

test('the s003 silence step reads the notification list the coordinator answers', () => {
  const { api } = consoleApi();
  const silence = load().steps(api).find((step) => step.scenario === 's003' && step.label === '...silence');
  assert.ok(silence && silence.check);
  // fabric-coordinator answers GET /v1/notifications/<handle> with {"notifications": [...]}.
  assert.equal(silence.check([{ label: 'notifications', status: 200, data: { notifications: [] } }]).ok, true);
  assert.equal(silence.check([{ label: 'notifications', status: 200, data: { notifications: [{ kind: 'match' }] } }]).ok, false);
});

test('the shared script holds the Safari 13.1 baseline of the data-view pages', () => {
  const text = fs.readFileSync(SCRIPT, 'utf8');
  assert.doesNotMatch(text, /^\s*(import|export)\b/m, 'a plain script, not a module');
  for (const api of ['replaceAll(', '.at(', 'structuredClone(']) assert.ok(!text.includes(api), api);
});
