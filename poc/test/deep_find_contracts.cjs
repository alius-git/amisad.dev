// LICENSEURI https://yuruna.link/license
// Copyright (c) 2019-2026 by Alisson Sol et al.
const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict'),path=require('node:path');
const source=fs.readFileSync(path.join(__dirname,'../demo/data-view/ui/shared.js'),'utf8');
const start=source.indexOf('  function deepFindAll('),end=source.indexOf('\n\n',start);
const ctx={};vm.runInNewContext(source.slice(start,end),ctx);
const shared={id:'repeat'},node={id:'first',a:[shared,{id:42},{id:'first'},shared],b:{id:false,c:{id:'last'}}};
assert.deepEqual(Array.from(ctx.deepFindAll(node,'id')),['first','repeat',42,false,'last']);
const nodes=Array.from({length:10000},(_,i)=>({id:i%200}));assert.equal(ctx.deepFindAll(nodes,'id').length,200);
console.log('PASS nested duplicate values retain first-seen order; 10000-node fixture.');
