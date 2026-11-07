/* SM1277: the unknown-write half of extensions/odoo/assets/lazysite-odoo.js, driven under
 * node with a stand-in DOM and a fake fetch that records every request. Loaded by
 * t/unit/odoo/111; prints one JSON object of facts for the Perl test to assert on:
 * what resume() sends, what showUnknown() draws (as text) for a person who may say
 * and one who may not, and what each button sends and draws next. */
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

function world(script, withSlot) {
  const log = [];
  const slot = new El('div');
  slot.attrs['data-ls-odoo-unknown'] = '';
  const document = {
    readyState: 'complete', body: new El('body'),
    createElement: function (t) { return new El(t); },
    querySelectorAll: function () { return []; },
    querySelector: function (sel) { return withSlot && sel === '[data-ls-odoo-unknown]' ? slot : null; },
  };
  const win = {
    document: document,
    fetch: async function (u, o) {
      const req = { url: u, method: o.method, body: o.body === undefined ? undefined : JSON.parse(o.body) };
      log.push(req);
      if (o.method === 'GET') return { status: 200, text: async () => JSON.stringify({ ok: true, visitor_token: 'VT' }) };
      const r = script(req, log);
      return { status: r.status, text: async () => JSON.stringify(r.body) };
    },
  };
  vm.runInNewContext(src, { window: win, Promise, JSON, encodeURIComponent, Object, String, Array, setTimeout });
  return { api: win.LazysiteOdoo, log: log, slot: slot };
}

const tick = function () { return new Promise(function (r) { setTimeout(r, 5); }); };
const posts = function (w) { return w.log.filter(function (x) { return x.method === 'POST'; }); };
const buttons = function (n) { return n.all(function (k) { return k.tagName === 'button'; }).map(function (b) { return b.textContent; }); };
const button = function (n, label) { return n.all(function (k) { return k.tagName === 'button' && k.textContent === label; })[0]; };
const RUN = 'a'.repeat(32);
const UNKNOWN = { ok: false, kind: 'apply-incomplete', unknown: 1, run: RUN, may_assume: 1,
  result: { changes: [ { seq: 1, outcome: 'done', key: 'rename:1' },
    { seq: 2, outcome: 'unknown', key: 'line:1', action: 'create', model: 'x.basket' } ] } };
const facts = {};

(async function () {
  // resume() sends the run, resume: true, the token and the assume lists
  {
    const w = world(function () { return { status: 200, body: { ok: true } }; });
    await w.api.resume(RUN);
    await w.api.resume(RUN, { assumeDone: 'line:1' });
    await w.api.resume(RUN, { assumeNotDone: ['line:1', 'line:2'] });
    facts.resume = posts(w).map(function (p) { return p.body; });
  }

  // a write that left a change unknown is drawn into the page's slot: its maker may say
  {
    const w = world(function () { return { status: 207, body: UNKNOWN }; }, true);
    await w.api.write('mix', { title: 'R' });
    facts.drawn = { state: w.slot.attrs['data-ls-odoo-state'], text: w.slot.text(), buttons: buttons(w.slot) };
  }

  // one who may not say is offered "Check again" alone; it sends no assume list
  {
    let n = 0;
    const w = world(function (req) {
      n++;
      if (n === 1) return { status: 207, body: Object.assign({}, UNKNOWN, { may_assume: 0 }) };
      return { status: 409, body: { ok: false, kind: 'unknown-outcome', run: RUN, may_assume: 0,
        changes: [ { seq: 2, key: 'line:1', action: 'create', model: 'x.basket' } ], error: 'cannot be read back' } };
    }, true);
    await w.api.write('mix', {});
    facts.not_mine = { buttons: buttons(w.slot) };
    button(w.slot, 'Check again').fire('click');
    await tick();
    facts.not_mine.sent = posts(w)[1] && posts(w)[1].body;
    facts.not_mine.after = { state: w.slot.attrs['data-ls-odoo-state'], buttons: buttons(w.slot) };
  }

  // "It was made" sends assume_done for that change, and a settled answer is drawn
  {
    let n = 0;
    const w = world(function () { n++; return n === 1 ? { status: 207, body: UNKNOWN } : { status: 200, body: { ok: true, applied: 1 } }; }, true);
    await w.api.confirm('b'.repeat(32));
    button(w.slot, 'It was made').fire('click');
    await tick();
    facts.made = { sent: posts(w)[1].body, state: w.slot.attrs['data-ls-odoo-state'], text: w.slot.text() };
  }

  // "It was not made", answered by a new run left unknown, draws that run
  {
    let n = 0;
    const RUN2 = 'c'.repeat(32);
    const w = world(function () {
      n++;
      return n === 1 ? { status: 207, body: UNKNOWN } : { status: 207, body: Object.assign({}, UNKNOWN, { run: RUN2 }) };
    }, true);
    await w.api.write('mix', {});
    button(w.slot, 'It was not made').fire('click');
    await tick();
    button(w.slot, 'Check again').fire('click');
    await tick();
    facts.again = { first: posts(w)[1].body, second: posts(w)[2].body };
  }

  // a value from Odoo is text: a key that is markup is drawn as its characters
  {
    const evil = JSON.parse(JSON.stringify(UNKNOWN));
    evil.result.changes[1].key = '<img src=x onerror=alert(1)>';
    const w = world(function () { return { status: 207, body: evil }; }, true);
    await w.api.write('mix', {});
    facts.markup = { tags: w.slot.all(function (k) { return k.tagName === 'img'; }).length, text: w.slot.text() };
  }

  // a page with no slot is answered as before, and nothing is drawn
  {
    const w = world(function () { return { status: 207, body: UNKNOWN }; }, false);
    const r = await w.api.write('mix', {});
    facts.no_slot = { status: r.status, run: r.data.run, drawn: w.slot.children.length };
  }
  console.log(JSON.stringify(facts));
})().catch(function (e) { console.log(JSON.stringify({ error: String(e && e.stack || e) })); });
