/* SM1328: the texts of starter/assets/lazysite-odoo.js that name Odoo, driven under
 * node with a stand-in DOM. Loaded by t/unit/odoo/121; prints one JSON object of
 * facts per case for the Perl test to assert on. A case is the script tag the
 * engine adds: none (a page that loads the helper itself), a name, or an empty
 * name. For each, the sign-in dialog's label, message and field labels, what it
 * says when the endpoint cannot be reached, and the line an unknown write draws. */
'use strict';
const fs = require('fs');
const vm = require('vm');
const src = fs.readFileSync(process.argv[2], 'utf8');

function El(tag) {
  this.tagName = tag; this.attrs = {}; this.children = []; this.parentNode = null;
  this.value = ''; this.checked = false; this.disabled = false; this.textContent = ''; this.listeners = {};
}
El.prototype.appendChild = function (c) { c.parentNode = this; this.children.push(c); return c; };
El.prototype.removeChild = function (c) { this.children = this.children.filter(function (x) { return x !== c; }); c.parentNode = null; return c; };
El.prototype.setAttribute = function (k, v) { this.attrs[k] = v; };
El.prototype.getAttribute = function (k) { return this.attrs[k] === undefined ? null : this.attrs[k]; };
El.prototype.addEventListener = function (t, f) { (this.listeners[t] = this.listeners[t] || []).push(f); };
El.prototype.focus = function () {};
El.prototype.fire = function (t) {
  const ev = { preventDefault: function () {} };
  (this.listeners[t] || []).forEach(function (f) { f(ev); });
};
El.prototype.find = function (pred) {
  let hit = null;
  (function walk(n) { n.children.forEach(function (k) { if (!hit && pred(k)) hit = k; if (!hit) walk(k); }); })(this);
  return hit;
};

function world(name) {
  const body = new El('body');
  let script = null;
  if (name !== undefined) {
    script = new El('script');
    script.setAttribute('data-ls-odoo-display-name', name);
  }
  const document = {
    readyState: 'complete', body: body,
    createElement: function (t) { return new El(t); },
    querySelectorAll: function () { return []; },
    querySelector: function (sel) { return sel === 'script[data-ls-odoo-display-name]' ? script : null; },
  };
  const win = {
    document: document,
    fetch: async function (u, o) {
      if (o.method === 'GET') return { status: 200, text: async () => JSON.stringify({ ok: true, visitor_token: 'VT' }) };
      throw new Error('offline');
    },
  };
  vm.runInNewContext(src, { window: win, Promise, JSON, encodeURIComponent, Object, String, setTimeout });
  return { api: win.LazysiteOdoo, body: body };
}

const tick = function () { return new Promise(function (r) { setTimeout(r, 5); }); };

async function facts(name) {
  const w = world(name);
  const f = {};
  w.api.prompt();
  const box = w.body.find(function (n) { return n.attrs['data-ls-odoo-prompt'] !== undefined; });
  const input = function (k) { return box.find(function (n) { return n.tagName === 'input' && n.attrs.name === k; }); };
  const msg = box.find(function (n) { return n.tagName === 'p'; });
  f.dialog = box.attrs['aria-label'];
  f.message = msg.textContent;
  f.login = input('login').attrs['aria-label'];
  f.password = input('password').attrs['aria-label'];
  input('login').value = 'tove';
  input('password').value = 'pw';
  box.find(function (n) { return n.tagName === 'form'; }).fire('submit');
  for (let i = 0; i < 20 && msg.textContent === f.message; i++) await tick();
  f.unreachable = msg.textContent;

  const one = new El('div');
  w.api.showUnknown(one, { run: 'r1', kind: 'unknown-outcome', changes: [{ seq: 1 }] });
  f.unknown_one = one.children[0] ? one.children[0].textContent : null;
  const two = new El('div');
  w.api.showUnknown(two, { run: 'r1', kind: 'unknown-outcome', changes: [{ seq: 1 }, { seq: 2 }] });
  f.unknown_two = two.children[0] ? two.children[0].textContent : null;
  return f;
}

(async function () {
  const out = {};
  out.none = await facts(undefined);
  out.named = await facts('Acme Office');
  out.empty = await facts('');
  process.stdout.write(JSON.stringify(out));
})().catch(function (e) { process.stdout.write(JSON.stringify({ error: String(e && e.stack || e) })); });
