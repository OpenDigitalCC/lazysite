/* SM1299 (ruling 37): the return of the /odoo-signin page, driven under node with a
 * stand-in DOM, a fake fetch that records every request, and a stand-in location.
 * Loaded by t/unit/odoo/120; prints one JSON object of facts for the Perl test.
 * What is held: a button carrying data-ls-odoo-next sends the page's own ?next=
 * with the sign-in (and with the code step), and once signed in the page goes to
 * the path the ENDPOINT answered - never to the ?next= it read itself. A button
 * without the attribute sends no next and goes nowhere, as before. */
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
El.prototype.hasAttribute = function (k) { return this.attrs[k] !== undefined; };
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

function world(search, withNext, script) {
  const log = [];
  const went = [];
  const body = new El('body');
  const btn = new El('button');
  btn.setAttribute('data-ls-odoo-signin', '');
  if (withNext) btn.setAttribute('data-ls-odoo-next', '');
  const document = {
    readyState: 'complete', body: body,
    createElement: function (t) { return new El(t); },
    querySelectorAll: function (sel) { return sel === '[data-ls-odoo-signin]' ? [btn] : []; },
  };
  const win = {
    document: document,
    location: { search: search, assign: function (u) { went.push(u); }, reload: function () {} },
    fetch: async function (u, o) {
      const req = { url: u, method: o.method, body: o.body === undefined ? undefined : JSON.parse(o.body) };
      log.push(req);
      if (o.method === 'GET') return { status: 200, text: async () => JSON.stringify({ ok: true, visitor_token: 'VT' }) };
      const r = script(req);
      return { status: r.status, text: async () => JSON.stringify(r.body) };
    },
  };
  vm.runInNewContext(src, { window: win, Promise, JSON, encodeURIComponent, decodeURIComponent, Object, String, setTimeout });
  return { log: log, went: went, body: body, btn: btn };
}

const tick = function () { return new Promise(function (r) { setTimeout(r, 5); }); };
const dialog = function (w) { return w.body.find(function (n) { return n.attrs['data-ls-odoo-prompt'] !== undefined; }); };
const input = function (root, name) { return root.find(function (n) { return n.tagName === 'input' && n.attrs.name === name; }); };
const forms = function (d) { return d.children.filter(function (n) { return n.tagName === 'form'; }); };
const posts = function (w) { return w.log.filter(function (x) { return x.method === 'POST'; }).map(function (x) { return x.body; }); };

async function signIn(w) {
  w.btn.fire('click');
  await tick();
  const d = dialog(w);
  input(d, 'login').value = 'jane@example.com';
  input(d, 'password').value = 'pw';
  forms(d)[0].fire('submit');
  await tick();
  return d;
}

const facts = {};
(async function () {
  // the endpoint answers what sanitise_next would; the script must follow THAT
  const answer = function (n) { return /^\/[\w\/.-]*$/.test(n) && !/\/\//.test(n) ? n : '/'; };
  const plain = function (req) {
    return { status: 200, body: { ok: true, signed_in: true, identity: { name: 'Jane' }, next: answer(req.body.next) } };
  };
  for (const [name, search] of [['same', '?next=%2Fwholesale'], ['host', '?next=%2F%2Fevil.example%2F'],
      ['scheme', '?a=1&next=https%3A%2F%2Fevil.example'], ['none', ''], ['plus', '?next=/a+b']]) {
    const w = world(search, true, plain);
    await signIn(w);
    facts[name] = { sent: posts(w)[0].next, went: w.went };
  }
  // the script follows the endpoint's answer, never what it read itself
  {
    const w = world('?next=%2F%2Fevil.example', true, function () {
      return { status: 200, body: { ok: true, signed_in: true, identity: { name: 'Jane' }, next: '/' } };
    });
    await signIn(w);
    facts.follows_answer = { went: w.went };
  }
  // no answer from the endpoint: the page stays
  {
    const w = world('?next=%2Fwholesale', true, function () {
      return { status: 200, body: { ok: true, signed_in: true, identity: { name: 'Jane' } } };
    });
    await signIn(w);
    facts.no_answer = { went: w.went };
  }
  // a button without data-ls-odoo-next: no next sent, nowhere to go
  {
    const w = world('?next=%2Fwholesale', false, plain);
    await signIn(w);
    facts.unmarked = { has_next: Object.prototype.hasOwnProperty.call(posts(w)[0], 'next'), went: w.went };
  }
  // two-factor: the code step carries next, and the page goes once that signs in
  {
    const w = world('?next=%2Fwholesale', true, function (req) {
      if (req.body.signin) return { status: 200, body: { ok: true, signed_in: false, second_factor: 'totp', remember_offered: 0 } };
      return plain(req);
    });
    const d = await signIn(w);
    const after_password = w.went.slice();
    const cf = forms(d)[0];
    input(cf, 'code').value = '123456';
    cf.fire('submit');
    await tick();
    facts.two_factor = { after_password: after_password, code_next: posts(w)[1] && posts(w)[1].next, went: w.went };
  }
  console.log(JSON.stringify(facts));
})().catch(function (e) { console.log(JSON.stringify({ error: String(e && e.stack || e) })); });
