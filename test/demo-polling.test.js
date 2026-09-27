// LICENSEURI https://yuruna.link/license
// Copyright (c) 2026 by Alisson Sol et al.
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
