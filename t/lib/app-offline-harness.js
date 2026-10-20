/* The offline pages and the waiting update of the generated app worker (SM1197),
 * run under node with the same kind of stand-ins as app-worker-harness.js (SM1155):
 * a cache store, a fetch that serves what the test scripted and records what was
 * asked (the request AND its init, so "sent without credentials" is observable),
 * and the events the browser delivers. argv[2] is a worker generated with
 * app_offline_pages, argv[3] the same site with app_update: wait, argv[4] a copy
 * of the first whose page list was edited by the test to name what the engine
 * would never list (the endpoint, the manager, the engine tree).
 *
 * Nothing here knows the worker's internals: it dispatches fetch, install,
 * activate and message events and reads what came out. Prints one JSON object. */
'use strict';
const fs = require('fs');
const vm = require('vm');
const ORIGIN = 'https://app.example.test';
const SRC = { now: fs.readFileSync(process.argv[2], 'utf8'), wait: fs.readFileSync(process.argv[3], 'utf8'),
  forced: fs.readFileSync(process.argv[4], 'utf8') };

class Resp {
  constructor(o) { this.status = o.status === undefined ? 200 : o.status; this.type = o.type || 'basic';
    this.redirected = !!o.redirected; this.h = o.headers || {}; this.body = o.body || '';
    this.headers = { get: (k) => this.h[k.toLowerCase()] || null }; }
  clone() { return new Resp({ status: this.status, type: this.type, redirected: this.redirected, headers: this.h, body: this.body }); }
}

function world(which, files) {
  const src = SRC[which];
  const handlers = {};
  const stores = new Map();
  const fetched = [];          // { url, credentials }
  const flags = { skipWaiting: 0, claim: 0, down: false };
  const key = (r) => (typeof r === 'string' ? new URL(r, ORIGIN).href : r.url);
  const caches = {
    open: async (n) => {
      if (!stores.has(n)) stores.set(n, new Map());
      const m = stores.get(n);
      return { match: async (r) => { const v = m.get(key(r)); return v ? v.clone() : v; }, put: async (r, v) => { m.set(key(r), v); }, delete: async (r) => m.delete(key(r)) };
    },
    keys: async () => [...stores.keys()],
    delete: async (n) => stores.delete(n),
  };
  const self = { location: { origin: ORIGIN }, addEventListener: (t, f) => { handlers[t] = f; },
    skipWaiting: () => { flags.skipWaiting++; return Promise.resolve(); }, clients: { claim: () => { flags.claim++; return Promise.resolve(); } } };
  const fetchFn = async (r, init) => {
    if (flags.down) throw new TypeError('Failed to fetch');
    const u = key(r);
    const credentials = init && init.credentials ? init.credentials : (typeof r === 'object' && r.credentials) || 'include';
    // SM1203: the engine's visitor log tells the worker's own fetch from a visit by
    // this header, so what the fetch sent is recorded too (init first, else the request).
    const hdrs = (init && init.headers) || (typeof r === 'object' && r.headers) || {};
    const app = typeof hdrs.get === 'function' ? hdrs.get('x-lazysite-app')
      : (Object.keys(hdrs).filter((k) => k.toLowerCase() === 'x-lazysite-app').map((k) => hdrs[k])[0] || null);
    fetched.push({ url: u.replace(ORIGIN, ''), credentials, app });
    const f = files[u];
    if (!f) return new Resp({ status: 404 });
    return new Resp(typeof f === 'function' ? f(credentials) : f);
  };
  vm.runInNewContext(src, { self, caches, fetch: fetchFn, URL, Promise, Object, Array, RegExp, String, TypeError, Error }, {});
  return { handlers, stores, fetched, flags, src };
}

function request(url, o) {
  o = o || {};
  const h = o.headers || {};
  return { url: new URL(url, ORIGIN).href, method: o.method || 'GET', mode: o.mode || 'navigate', credentials: 'include',
    headers: { get: (k) => h[k.toLowerCase()] || null } };
}

async function dispatch(w, url, o) {
  const ev = { request: request(url, o), answered: false, waits: [],
    respondWith(p) { this.answered = true; this.p = Promise.resolve(p); }, waitUntil(p) { this.waits.push(Promise.resolve(p)); } };
  w.handlers.fetch(ev);
  let response = null, rejected = null;
  if (ev.answered) { try { response = await ev.p; } catch (e) { rejected = String(e); } }
  await Promise.all(ev.waits);
  return { answered: ev.answered, response, rejected };
}

function cacheName(w) { return /"cache":"([^"]+)"/.exec(w.src)[1]; }
function held(w) { return [...(w.stores.get(cacheName(w)) || new Map()).keys()].map((u) => u.replace(ORIGIN, '')); }
function cfg(w, k) { return JSON.parse(new RegExp('"' + k + '":(\\[[^\\]]*\\]|"[^"]*")').exec(w.src)[1]); }

const facts = {};
(async () => {
  // the list the worker was given
  { const w = world('now', {}); facts.pages = cfg(w, 'pages'); facts.update_now = cfg(w, 'update'); facts.update_wait = cfg(world('wait', {}), 'update'); }

  // a listed page: network first, the last good copy kept, served offline
  {
    let n = 0;
    const files = { [ORIGIN + '/portal/']: () => ({ headers: { 'cache-control': 'no-cache, must-revalidate', vary: 'Cookie' }, body: 'home' + (++n) }) };
    const w = world('now', files);
    const a = await dispatch(w, '/portal/');
    facts.online = { answered: a.answered, body: a.response && a.response.body, held: held(w) };
    const b = await dispatch(w, '/portal/');                       // a newer render replaces the kept one
    w.flags.down = true;
    const off = await dispatch(w, '/portal/');
    facts.offline = { answered: off.answered, body: off.response && off.response.body, rejected: off.rejected };
    const q = await dispatch(w, '/portal/?source=pwa');           // the launch URL the installed app uses
    facts.offline_with_query = { answered: q.answered, body: q.response && q.response.body };
    const un = await dispatch(w, '/portal/other');                // an unlisted page offline: the browser's own error
    facts.offline_unlisted = { answered: un.answered };
    facts.kept_once_listed_only = held(w);
  }

  // the user is sent what the network sent; the copy that is KEPT comes from a request without credentials
  {
    const files = { [ORIGIN + '/portal/']: (cred) => ({ body: cred === 'omit' ? 'anonymous page' : 'page for alice, signed in' }) };
    const w = world('now', files);
    const a = await dispatch(w, '/portal/');
    w.flags.down = true;
    const off = await dispatch(w, '/portal/');
    facts.credentials = { shown_online: a.response.body, shown_offline: off.response.body,
      fetched: w.fetched.map((f) => f.credentials) };
  }

  // SM1203: the worker's keeping fetch says what it is; the person's own navigation says nothing
  {
    const w = world('now', { [ORIGIN + '/portal/']: { body: 'p' } });
    await dispatch(w, '/portal/');
    facts.app_header = { fetches: w.fetched.map((f) => ({ credentials: f.credentials, app: f.app })) };
  }

  // what is never kept
  {
    const mk = (o) => ({ [ORIGIN + '/portal/new']: o });
    const cases = {
      no_store: { headers: { 'cache-control': 'no-store' }, body: 'x' },
      private: { headers: { 'cache-control': 'private, max-age=60' }, body: 'x' },
      private_caps: { headers: { 'cache-control': 'max-age=5, PRIVATE' }, body: 'x' },
      set_cookie: { headers: { 'set-cookie': 'sid=1; HttpOnly' }, body: 'x' },
      vary_star: { headers: { vary: '*' }, body: 'x' },
      redirected_to_login: { redirected: true, body: 'login form' },
      not_200: { status: 403, body: 'no' },
      partial: { status: 206, body: 'part' },
      opaque: { type: 'opaque', body: '' },
      ok: { body: 'fine' },
    };
    facts.kept = {};
    for (const [k, v] of Object.entries(cases)) {
      const w = world('now', mk(v));
      await dispatch(w, '/portal/new');
      facts.kept[k] = held(w);
    }
    // a page kept while public, then protected: the copy goes at the next fetch
    let guarded = false;
    const w = world('now', { [ORIGIN + '/portal/']: () => (guarded ? { headers: { 'cache-control': 'no-store' }, body: 'secret' } : { body: 'public' }) });
    await dispatch(w, '/portal/');
    const before = held(w);
    guarded = true;
    await dispatch(w, '/portal/');
    facts.flip = { before, after: held(w) };
    // a failed refresh (the network is down) leaves the good copy alone
    const w2 = world('now', { [ORIGIN + '/portal/']: { body: 'good' } });
    await dispatch(w2, '/portal/');
    w2.flags.down = true;
    await dispatch(w2, '/portal/');
    facts.survives_outage = held(w2);
  }

  // what the worker does not answer: unlisted pages, other methods, other origins, the endpoint, the manager
  {
    const files = {};
    for (const p of ['/portal/other', '/portal/new', '/cgi-bin/lazysite-odoo.pl', '/cgi-bin/anything', '/manager/', '/lazysite/x', '/login', '/dav/portal/', '/lazysite-assets/a.css'])
      files[ORIGIN + p] = { body: 'x' };
    const w = world('now', files);
    const ask = { unlisted: ['/portal/other'], unlisted_in_scope_dir: ['/portal/new/deeper'], post_listed: ['/portal/', { method: 'POST' }],
      other_origin: ['https://elsewhere.test/portal/'], endpoint: ['/cgi-bin/lazysite-odoo.pl'], cgi: ['/cgi-bin/anything'],
      manager: ['/manager/'], engine_tree: ['/lazysite/x'], sign_in: ['/login'], ranged: ['/portal/', { headers: { range: 'bytes=0-9' } }] };
    facts.answered = {};
    for (const [k, [u, o]] of Object.entries(ask)) facts.answered[k] = (await dispatch(w, u, o)).answered;
    facts.fetched_when_refused = w.fetched.length;
    facts.held_when_refused = held(w);
    // the same, with a page list that (wrongly) names the endpoint, the manager and the engine tree
    const f = world('forced', files);
    facts.forced_pages = cfg(f, 'pages');
    facts.forced_answered = {};
    for (const [k, [u, o]] of Object.entries({ endpoint: ['/cgi-bin/lazysite-odoo.pl'], cgi: ['/cgi-bin/anything'], manager: ['/manager/'],
      engine_tree: ['/lazysite/x'], sign_in: ['/login'], dav: ['/lazysite-dav.pl/portal/'] })) facts.forced_answered[k] = (await dispatch(f, u, o)).answered;
    facts.forced_fetched = f.fetched.length;
    facts.forced_held = held(f);
  }

  // install: the listed pages are fetched without credentials, and kept when they may be
  {
    const files = {
      [ORIGIN + '/portal/']: (c) => ({ body: c === 'omit' ? 'anon' : 'signed in' }),
      [ORIGIN + '/portal/new']: { headers: { 'cache-control': 'no-store' }, body: 'x' },
    };
    const shell = cfg(world('now', {}), 'shell');
    for (const u of shell) files[ORIGIN + u] = { body: 's' };
    const w = world('now', files);
    const ev = { waits: [], waitUntil(p) { this.waits.push(Promise.resolve(p)); } };
    w.handlers.install(ev);
    await Promise.all(ev.waits);
    facts.install = { held_pages: held(w).filter((u) => u.indexOf('/portal') === 0),
      page_fetches: w.fetched.filter((f) => f.url.indexOf('/portal') === 0) };
  }

  // the update: now (today's behaviour) or waiting for the page
  {
    for (const which of ['now', 'wait']) {
      const files = {};
      for (const u of cfg(world(which, {}), 'shell')) files[ORIGIN + u] = { body: 's' };
      const w = world(which, files);
      const ev = { waits: [], waitUntil(p) { this.waits.push(Promise.resolve(p)); } };
      w.handlers.install(ev);
      await Promise.all(ev.waits);
      const afterInstall = w.flags.skipWaiting;
      const msg = (data, src) => { const e = { data, source: src === undefined ? { type: 'window' } : src, waits: [], waitUntil(p) { this.waits.push(Promise.resolve(p)); } }; w.handlers.message && w.handlers.message(e); return e; };
      msg('something else');
      msg({ type: 'skip-waiting-not' });
      const afterOther = w.flags.skipWaiting;
      msg({ type: 'skip-waiting' });
      const afterObject = w.flags.skipWaiting;
      msg('skip-waiting');
      const av = { waits: [], waitUntil(p) { this.waits.push(Promise.resolve(p)); } };
      w.handlers.activate(av);
      await Promise.all(av.waits);
      facts['update_' + which + '_flow'] = { after_install: afterInstall, after_other_messages: afterOther, after_object: afterObject,
        after_string: w.flags.skipWaiting, claim: w.flags.claim, has_message_listener: !!w.handlers.message };
    }
  }

  console.log(JSON.stringify(facts));
})().catch((e) => { console.log(JSON.stringify({ error: String(e && e.stack || e) })); });
