/* SM1157: the sign-in dialog of starter/assets/lazysite-odoo.js, driven under node
 * with a stand-in DOM and a fake fetch that records every request. Loaded by
 * t/unit/odoo/49; prints one JSON object of facts for the Perl test to assert on.
 * What is held here is what the dialog does with the two-factor step: it asks for
 * the code after the password, offers "remember this device" only when the server
 * said so, lets a wrong code be tried again, goes back to the password when the
 * sign-in has run out, and never keeps the password or the code. */
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
El.prototype.all = function (pred) {
  const out = [];
  (function walk(n) { n.children.forEach(function (k) { if (pred(k)) out.push(k); walk(k); }); })(this);
  return out;
};

function world(script) {
  const log = [];
  const body = new El('body');
  const document = {
    readyState: 'complete', body: body,
    createElement: function (t) { return new El(t); },
    querySelectorAll: function () { return []; },
  };
  const win = {
    document: document,
    fetch: async function (u, o) {
      const req = { url: u, method: o.method, body: o.body === undefined ? undefined : JSON.parse(o.body), raw: o.body };
      log.push(req);
      if (o.method === 'GET') return { status: 200, text: async () => JSON.stringify({ ok: true, visitor_token: 'VT' }) };
      const r = script(req, log);
      return { status: r.status, text: async () => JSON.stringify(r.body) };
    },
  };
  vm.runInNewContext(src, { window: win, Promise, JSON, encodeURIComponent, Object, String, setTimeout });
  return { api: win.LazysiteOdoo, log: log, body: body };
}

const tick = function () { return new Promise(function (r) { setTimeout(r, 5); }); };
const dialog = function (w) { return w.body.find(function (n) { return n.attrs['data-ls-odoo-prompt'] !== undefined; }); };
const input = function (root, name) { return root.find(function (n) { return n.tagName === 'input' && n.attrs.name === name; }); };
const button = function (root, text) { return root.find(function (n) { return n.tagName === 'button' && n.textContent === text; }); };
const forms = function (d) { return d.children.filter(function (n) { return n.tagName === 'form'; }); };
const posts = function (w) { return w.log.filter(function (x) { return x.method === 'POST'; }); };

const facts = {};

(async function () {
  // A: password, then the code (wrong, then right), with remember offered and ticked
  {
    let n = 0;
    const w = world(function (req) {
      if (req.body.signin) return { status: 200, body: { ok: true, signed_in: false, second_factor: 'totp', remember_offered: 1 } };
      n++;
      return n === 1
        ? { status: 401, body: { ok: false, kind: 'second-factor', error: 'Odoo did not accept that code.' } }
        : { status: 200, body: { ok: true, signed_in: true, identity: { name: 'Tove' } } };
    });
    let result = 'pending';
    w.api.prompt().then(function (v) { result = v; });
    const d = dialog(w);
    input(d, 'login').value = 'tove@example.com';
    input(d, 'password').value = 'Sup3r-secret-pw';
    forms(d)[0].fire('submit');
    await tick();
    const cf = forms(d)[0];
    const code = input(cf, 'code');
    const rem = input(cf, 'remember');
    facts.step = {
      one_form: forms(d).length, has_code: !!code, has_password: !!input(cf, 'password'),
      code_autocomplete: code && code.attrs.autocomplete, code_inputmode: code && code.attrs.inputmode,
      has_remember: !!rem, remember_type: rem && rem.attrs.type, remember_label_for: cf.find(function (x) { return x.tagName === 'label'; }).attrs['for'],
      remember_label: cf.find(function (x) { return x.tagName === 'label'; }).textContent,
      pass_cleared: true, open: result === 'pending',
    };
    code.value = '111111'; rem.checked = true;
    cf.fire('submit');
    facts.code_cleared_before_answer = code.value === '';
    await tick();
    facts.wrong = { msg: cf.find(function (x) { return x.attrs.role === 'alert'; }).textContent, still_open: result === 'pending',
      form_still_there: forms(d)[0] === cf, code_box: code.value };
    code.value = '222222'; rem.checked = false;
    cf.fire('submit');
    await tick();
    facts.right = { result: result, closed: dialog(w) === null };
    const ps = posts(w);
    facts.posts = ps.map(function (p) { return p.body; });
    facts.raws = ps.map(function (p) { return p.raw; });
    facts.requests = w.log.length;
  }

  // B: remember not offered -> no checkbox
  {
    const w = world(function (req) {
      return { status: 200, body: { ok: true, signed_in: false, second_factor: 'totp', remember_offered: 0 } };
    });
    w.api.prompt();
    const d = dialog(w);
    input(d, 'login').value = 'a'; input(d, 'password').value = 'b';
    forms(d)[0].fire('submit');
    await tick();
    facts.no_remember = { has_code: !!input(forms(d)[0], 'code'), has_remember: !!input(forms(d)[0], 'remember') };
  }

  // C: the half-open sign-in has run out -> back to the password
  {
    const w = world(function (req) {
      if (req.body.signin) return { status: 200, body: { ok: true, signed_in: false, second_factor: 'totp', remember_offered: 0 } };
      return { status: 401, body: { ok: false, kind: 'signin-required', error: 'The sign-in has run out - enter the password again.' } };
    });
    let result = 'pending';
    w.api.prompt().then(function (v) { result = v; });
    const d = dialog(w);
    input(d, 'login').value = 'a'; input(d, 'password').value = 'b';
    forms(d)[0].fire('submit');
    await tick();
    const cf = forms(d)[0];
    input(cf, 'code').value = '123456';
    cf.fire('submit');
    await tick();
    const f2 = forms(d)[0];
    facts.lapsed = { open: result === 'pending', forms: forms(d).length, has_password: !!input(f2, 'password'), has_code: !!input(f2, 'code'),
      msg: f2.find(function (x) { return x.attrs.role === 'alert'; }).textContent };
  }

  // D: cancel at the code step -> the half-open sign-in is ended, the dialog resolves false
  {
    const w = world(function (req) {
      if (req.body.signin) return { status: 200, body: { ok: true, signed_in: false, second_factor: 'totp', remember_offered: 0 } };
      return { status: 200, body: { ok: true, signed_in: false } };
    });
    let result = 'pending';
    w.api.prompt().then(function (v) { result = v; });
    const d = dialog(w);
    input(d, 'login').value = 'a'; input(d, 'password').value = 'b';
    forms(d)[0].fire('submit');
    await tick();
    const cf = forms(d)[0];
    input(cf, 'code').value = '123456';
    button(cf, 'Cancel').fire('click');
    await tick();
    facts.cancel = { result: result, closed: dialog(w) === null, signout: posts(w).some(function (p) { return p.body.signout === true; }),
      code_sent: posts(w).some(function (p) { return p.body.signin_code === true; }) };
  }

  // E: a signed-in-at-once answer (no two-factor) is unchanged
  {
    const w = world(function () { return { status: 200, body: { ok: true, signed_in: true, identity: { name: 'Jane' } } }; });
    let result = 'pending';
    w.api.prompt().then(function (v) { result = v; });
    const d = dialog(w);
    input(d, 'login').value = 'a'; input(d, 'password').value = 'b';
    forms(d)[0].fire('submit');
    await tick();
    facts.plain = { result: result, closed: dialog(w) === null, posts: posts(w).length };
  }

  console.log(JSON.stringify(facts));
})().catch(function (e) { console.log(JSON.stringify({ error: String(e && e.stack || e) })); });
