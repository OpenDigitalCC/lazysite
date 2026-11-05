/* SM1347: the not-kept half of starter/assets/lazysite-odoo.js, driven under node
 * with a stand-in DOM and a fake fetch. Loaded by t/unit/odoo/124; prints one JSON
 * object of facts for the Perl test to assert on: what write(), confirm() and a
 * settled resume draw into [data-ls-odoo-not-kept] (as text), and that a page
 * without the slot is answered as before. */
'use strict';
const fs = require('fs');
const vm = require('vm');
const src = fs.readFileSync(process.argv[2], 'utf8');

function El(tag) {
  this.tagName = tag; this.attrs = {}; this.children = []; this.parentNode = null;
  this.disabled = false; this.textContent = ''; this.listeners = {};
}
Object.defineProperty(El.prototype, 'firstChild', { get: function () { return this.children[0] || null; } });
El.prototype.appendChild = function (c) { c.parentNode = this; this.children.push(c); return c; };
El.prototype.removeChild = function (c) { this.children = this.children.filter(function (x) { return x !== c; }); c.parentNode = null; return c; };
El.prototype.setAttribute = function (k, v) { this.attrs[k] = v; };
El.prototype.getAttribute = function (k) { return this.attrs[k] === undefined ? null : this.attrs[k]; };
El.prototype.hasAttribute = function (k) { return this.attrs[k] !== undefined; };
El.prototype.addEventListener = function (t, f) { (this.listeners[t] = this.listeners[t] || []).push(f); };
El.prototype.fire = function (t) { (this.listeners[t] || []).forEach(function (f) { f({ preventDefault: function () {} }); }); };
El.prototype.all = function (pred) {
  const out = [];
  (function walk(n) { n.children.forEach(function (k) { if (pred(k)) out.push(k); walk(k); }); })(this);
  return out;
};
El.prototype.text = function () {
  return [this.textContent].concat(this.children.map(function (c) { return c.text(); })).join(' ').replace(/\s+/g, ' ').trim();
};

function world(script, withSlots) {
  const unknown = new El('div');
  const notKept = new El('div');
  const document = {
    readyState: 'complete', body: new El('body'),
    createElement: function (t) { return new El(t); },
    querySelectorAll: function () { return []; },
    querySelector: function (sel) {
      if (!withSlots) return null;
      if (sel === '[data-ls-odoo-unknown]') return unknown;
      if (sel === '[data-ls-odoo-not-kept]') return notKept;
      return null;
    },
  };
  const win = {
    document: document,
    fetch: async function (u, o) {
      if (o.method === 'GET') return { status: 200, text: async () => JSON.stringify({ ok: true, visitor_token: 'VT' }) };
      const r = script();
      return { status: r.status, text: async () => JSON.stringify(r.body) };
    },
  };
  vm.runInNewContext(src, { window: win, Promise, JSON, encodeURIComponent, Object, String, Array, setTimeout });
  return { api: win.LazysiteOdoo, unknown: unknown, notKept: notKept };
}

const tick = function () { return new Promise(function (r) { setTimeout(r, 5); }); };
const button = function (n, label) { return n.all(function (k) { return k.tagName === 'button' && k.textContent === label; })[0]; };
const NOTE = 'Odoo did not keep this change as asked: name';
const NOT_KEPT = { ok: true, applied: 1, result: { not_verified: 1, changes: [
  { seq: 1, outcome: 'done', bucket: 'rename', not_kept: ['name'], note: NOTE },
  { seq: 2, outcome: 'done', bucket: 'line' } ] } };
const KEPT = { ok: true, applied: 1, result: { not_verified: 0, changes: [ { seq: 1, outcome: 'done' } ] } };
const RUN = 'a'.repeat(32);
const UNKNOWN = { ok: false, kind: 'apply-incomplete', unknown: 1, run: RUN, may_assume: 1,
  result: { changes: [ { seq: 1, outcome: 'unknown', key: 'rename:1', action: 'write', model: 'x.product' } ] } };
const facts = {};

(async function () {
  {
    const w = world(function () { return { status: 200, body: NOT_KEPT }; }, true);
    await w.api.write('mix', {});
    facts.write = { state: w.notKept.attrs['data-ls-odoo-state'], text: w.notKept.text(), lines: w.notKept.children.length,
      api: w.api.notKept(NOT_KEPT).length };
  }
  {
    const w = world(function () { return { status: 200, body: NOT_KEPT }; }, true);
    await w.api.confirm('b'.repeat(32));
    facts.confirm = { text: w.notKept.text() };
  }
  {
    const w = world(function () { return { status: 200, body: KEPT }; }, true);
    await w.api.write('mix', {});
    facts.kept = { state: w.notKept.attrs['data-ls-odoo-state'], lines: w.notKept.children.length };
  }
  {
    let n = 0;
    const w = world(function () { n++; return n === 1 ? { status: 207, body: UNKNOWN } : { status: 200, body: NOT_KEPT }; }, true);
    await w.api.write('mix', {});
    button(w.unknown, 'Check again').fire('click');
    await tick();
    facts.resume = { unknown: w.unknown.text(), state: w.unknown.attrs['data-ls-odoo-state'], notKept: w.notKept.text() };
  }
  {
    const evil = JSON.parse(JSON.stringify(NOT_KEPT));
    evil.result.changes[0].note = '<img src=x onerror=alert(1)>';
    const w = world(function () { return { status: 200, body: evil }; }, true);
    await w.api.write('mix', {});
    facts.markup = { tags: w.notKept.all(function (k) { return k.tagName === 'img'; }).length, text: w.notKept.text() };
  }
  {
    const w = world(function () { return { status: 200, body: NOT_KEPT }; }, false);
    const r = await w.api.write('mix', {});
    facts.no_slot = { status: r.status, note: r.data.result.changes[0].note, drawn: w.notKept.children.length };
  }
  console.log(JSON.stringify(facts));
})().catch(function (e) { console.log(JSON.stringify({ error: String(e && e.stack || e) })); });
