/* SM1322 (ruling 49): /login asks the server whether the session is still honoured,
 * driven under node with a stand-in document (a cookie jar, the login page's
 * [data-ls-auth-*] elements) and a fake fetch that records what was asked. Loaded by
 * t/unit/auth/74 with starter/assets/lazysite-chrome.js; prints one JSON object of
 * facts for the Perl test.
 *
 * Nothing here knows the script's internals: it loads the file as a page would and
 * reads what came out - the cookie jar, which control shows, what was fetched. */
'use strict';
const fs = require('fs');
const vm = require('vm');
const src = fs.readFileSync(process.argv[2], 'utf8');

function El(attrs) { this.attrs = attrs; this.style = { display: 'none' }; }

// opts: marker (bool), check (bool: the page carries data-ls-auth-check),
//       answer (a function giving what fetch resolves to, or throws)
function world(opts) {
  const jar = { lazysite_auth: 'opaque' };
  if (opts.marker) jar.lzs_session = '1';
  const writes = [];
  const fetched = [];
  const panel = new El(opts.check ? { 'data-ls-auth-out': '', 'data-ls-auth-check': '' } : { 'data-ls-auth-out': '' });
  const form = new El({ 'data-ls-auth-in': '' });
  const document = {
    readyState: 'complete',
    get cookie() { return Object.keys(jar).map(function (k) { return k + '=' + jar[k]; }).join('; '); },
    set cookie(v) {
      writes.push(v);
      const m = /^([^=;\s]+)=([^;]*)/.exec(v);
      if (!m) return;
      if (/;\s*max-age=0(?:;|$)/i.test(v)) { delete jar[m[1]]; } else { jar[m[1]] = m[2]; }
    },
    getElementById: function () { return null; },
    querySelector: function (sel) {
      if (sel === '[data-ls-auth-check]') return panel.attrs['data-ls-auth-check'] !== undefined ? panel : null;
      return null;
    },
    querySelectorAll: function (sel) {
      if (sel === '[data-ls-auth-out]') return [panel];
      if (sel === '[data-ls-auth-in]') return [form];
      return [];
    },
    addEventListener: function () {},
  };
  const win = {};
  win.top = win;
  const fetchFn = function (url, init) {
    fetched.push({ url: url, credentials: init && init.credentials, cache: init && init.cache });
    try { return Promise.resolve(opts.answer()); } catch (e) { return Promise.reject(e); }
  };
  vm.runInNewContext(src, { window: win, document: document, fetch: fetchFn, Promise: Promise, Array: Array });
  return { jar: jar, writes: writes, fetched: fetched, panel: panel, form: form };
}

const json = function (status, body) {
  return function () { return { ok: status >= 200 && status < 300, status: status, json: function () { return Promise.resolve(body); } }; };
};
const tick = function () { return new Promise(function (r) { setTimeout(r, 10); }); };

function facts(w) {
  return {
    marker: w.jar.lzs_session === undefined ? null : w.jar.lzs_session,
    session_cookie_kept: w.jar.lazysite_auth === 'opaque',
    panel: w.panel.style.display, form: w.form.style.display,
    fetched: w.fetched, writes: w.writes,
  };
}

(async function () {
  const out = {};
  const cases = {
    refused:      { marker: true,  check: true,  answer: json(200, { ok: true, signed_in: false }) },
    honoured:     { marker: true,  check: true,  answer: json(200, { ok: true, signed_in: true }) },
    unchecked:    { marker: true,  check: false, answer: json(200, { ok: true, signed_in: false }) },
    no_marker:    { marker: false, check: true,  answer: json(200, { ok: true, signed_in: false }) },
    server_error: { marker: true,  check: true,  answer: json(500, { ok: false }) },
    unreachable:  { marker: true,  check: true,  answer: function () { throw new Error('offline'); } },
    no_answer:    { marker: true,  check: true,  answer: json(200, { ok: true }) },
  };
  for (const name of Object.keys(cases)) {
    const w = world(cases[name]);
    out[name + '_before'] = { panel: w.panel.style.display, form: w.form.style.display };
    await tick();
    out[name] = facts(w);
  }
  process.stdout.write(JSON.stringify(out));
})().catch(function (e) { process.stdout.write(JSON.stringify({ error: String(e && e.stack || e) })); });
