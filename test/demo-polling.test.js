// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
// GUID: 42706983-ecc4-4cb0-bd94-1e746f52c9f0
'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function polling(boxes) {
  const raw = fs.readFileSync(path.join(__dirname, '../poc/demo/data-view/ui/data.js'), 'utf8');
  // Exercise the shipping polling functions without starting the browser's endless loop.
  const source = raw.replace('  boot();', `
  renderBoxes = function () {};
  renderStrip = function () {};
  globalThis.polling = { pollBox: pollBox, pumpOnce: pumpOnce, boxState: boxState, lastRun: lastRun, pending: pending };
`);
  assert.notEqual(source, raw);
  let now = 20000;
  let rows = [['count', 1]];
  const requests = [];
  const context = {
    Date: { now: () => now },
    AD: { BOXES: boxes, scanIdentity: () => '', scanContext: () => '', boxById: id => boxes.find(box => box.id === id) },
    fetch: async url => { requests.push(url); return { status: 200, text: async () => JSON.stringify(rows) }; }
  };
  vm.runInNewContext(source, context);
  return { api: context.polling, requests, setRows: value => { rows = value; }, setNow: value => { now = value; } };
}

test('unchanged polls do not flash; changed rows retain deltas and attribution', async () => {
  const box = { id: 'fixture', url: 'fixture', pick: value => value };
  const { api, setRows, setNow } = polling([box]);
  await api.pollBox(box);
  const state = api.boxState.fixture;
  assert.equal(state.flashUntil, 0);
  state.pendingAttribution = 'fixture-step';
  await api.pollBox(box);
  assert.equal(state.flashUntil, 0);
  assert.equal(state.pendingAttribution, 'fixture-step');
  setRows([['count', 4]]);
  setNow(21000);
  await api.pollBox(box);
  assert.equal(state.flashUntil, 22600);
  assert.equal(state.deltas.count, '+3');
  assert.equal(state.attribution, 'fixture-step');
  assert.equal(state.pendingAttribution, null);
});

// The journal client as the data window runs it: every script data.html loads
// ahead of data.js, in its order, with a fetch whose answers the test gives.
function journalClient() {
  const demo = path.join(__dirname, '../poc/demo');
  const page = fs.readFileSync(path.join(demo, 'data-view/ui/data.html'), 'utf8');
  const sources = [...page.matchAll(/<script src="([^"]+)"><\/script>/g)].map(match => match[1]);
  const before = sources.slice(0, sources.indexOf('/ui/data.js'));
  assert.ok(before.includes('/ui/shared.js'), 'data.html loads shared.js before data.js');
  const requests = [];
  const waiting = [];
  const context = {
    fetch: url => {
      requests.push(url);
      return new Promise((resolve, reject) => waiting.push({ resolve, reject }));
    }
  };
  vm.createContext(context);
  for (const source of before) {
    // The demo servers map /ui/ to the page's own folder and /common/ to poc/demo/common.
    const file = source.startsWith('/common/') ? path.join(demo, source) : path.join(demo, 'data-view', source);
    vm.runInContext(fs.readFileSync(file, 'utf8'), context, { filename: file });
  }
  const journal = context.AD.journal;
  const delivered = [];
  const resets = [];
  journal.onEvents = events => { for (const event of events) delivered.push(event.seq); };
  journal.onReset = why => resets.push(why);
  return {
    journal, requests, delivered, resets,
    // Answers every request still waiting, then lets the client finish with it.
    answer: async payload => {
      for (const request of waiting.splice(0)) request.resolve({ json: async () => payload });
      await new Promise(resolve => setImmediate(resolve));
    },
    refuse: async () => {
      for (const request of waiting.splice(0)) request.reject(new Error('fixture: connection refused'));
      await new Promise(resolve => setImmediate(resolve));
    }
  };
}

test('a journal tick during a slow poll neither requests nor delivers twice', async () => {
  const { journal, requests, delivered, answer } = journalClient();
  const first = journal.poll();
  const second = journal.poll();
  await answer({ latest: 2, events: [{ seq: 1, kind: 'step' }, { seq: 2, kind: 'step' }] });
  await Promise.all([first, second]);
  assert.deepEqual({ requests, delivered }, { requests: ['/api/journal?since=0'], delivered: [1, 2] });
  // The next tick asks again, from where the last answer left off.
  const third = journal.poll();
  await answer({ latest: 2, events: [] });
  await third;
  assert.deepEqual(requests, ['/api/journal?since=0', '/api/journal?since=2']);
});

test('events at or below the cursor are not delivered again', async () => {
  // A late answer that overlaps what the window already took.
  const steps = journalClient();
  steps.journal.cursor = 2;
  const late = steps.journal.poll();
  await steps.answer({ latest: 3, events: [{ seq: 1, kind: 'step' }, { seq: 2, kind: 'step' }, { seq: 3, kind: 'step' }] });
  await late;
  // A reset the window already applied does not clear its views again.
  const reset = journalClient();
  reset.journal.cursor = 2;
  const again = reset.journal.poll();
  await reset.answer({ latest: 3, events: [{ seq: 1, kind: 'step' }, { seq: 2, kind: 'reset' }, { seq: 3, kind: 'step' }] });
  await again;
  assert.deepEqual(
    { delivered: steps.delivered, cursor: steps.journal.cursor, afterReset: reset.delivered, resets: reset.resets },
    { delivered: [3], cursor: 3, afterReset: [3], resets: [] });
});

test('a latest below the cursor still rebuilds from zero', async () => {
  const { journal, requests, delivered, resets, answer } = journalClient();
  journal.cursor = 5;
  const poll = journal.poll();
  await answer({ latest: 2, events: [] });
  await answer({ latest: 2, events: [{ seq: 1, kind: 'step' }, { seq: 2, kind: 'step' }] });
  await poll;
  assert.deepEqual(requests, ['/api/journal?since=5', '/api/journal?since=0']);
  assert.deepEqual({ delivered, resets, cursor: journal.cursor }, { delivered: [1, 2], resets: ['server restarted'], cursor: 2 });
});

test('a poll that fails leaves the next tick free to ask again', async () => {
  const { journal, requests, delivered, answer, refuse } = journalClient();
  const failed = journal.poll();
  await refuse();
  await failed;
  const next = journal.poll();
  await answer({ latest: 1, events: [{ seq: 1, kind: 'step' }] });
  await next;
  assert.deepEqual({ requests, delivered }, { requests: ['/api/journal?since=0', '/api/journal?since=0'], delivered: [1] });
});

test('oldest due box wins, ties stay in registry order, and unresolved boxes are skipped', async () => {
  const boxes = [
    { id: 'unresolved', url: () => '', pick: value => value },
    { id: 'first', url: 'first', pick: value => value },
    { id: 'second', url: 'second', pick: value => value },
    { id: 'recent', url: 'recent', pick: value => value }
  ];
  const { api, requests } = polling(boxes);
  api.lastRun.first = 100;
  api.lastRun.second = 100;
  api.lastRun.recent = 19000;
  await api.pumpOnce();
  await api.pumpOnce();
  await api.pumpOnce();
  assert.deepEqual(requests, ['/api/first', '/api/second']);
  api.pending.push('recent');
  await api.pumpOnce();
  assert.deepEqual(requests, ['/api/first', '/api/second', '/api/recent']);
});
