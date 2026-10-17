/* The routing and storing rules of the generated app worker (SM1155), run under
 * node with stand-ins for the service worker globals: a cache store, a fetch
 * that serves what the test scripted and records what was asked, and the events
 * the browser delivers. Loaded by t/unit/processor/134 with the worker the
 * processor generated; prints one JSON object of facts for the Perl test.
 *
 * Nothing here knows the worker's internals. It dispatches `fetch`, `install`
 * and `activate` events exactly as the browser would and reads what came out:
 * whether respondWith was called, what the cache holds, what was fetched. */
'use strict';
const fs = require('fs');
const vm = require('vm');
const src = fs.readFileSync(process.argv[2], 'utf8');
const ORIGIN = 'https://app.example.test';

class Resp {
  constructor(o) { this.status = o.status === undefined ? 200 : o.status; this.type = o.type || 'basic';
    this.h = o.headers || {}; this.body = o.body || ''; this.headers = { get: (k) => this.h[k.toLowerCase()] || null }; }
  clone() { return new Resp({ status: this.status, type: this.type, headers: this.h, body: this.body }); }
}

function world(origin_files) {
  const handlers = {};
  const stores = new Map();
  const fetched = [];
  const flags = { skipWaiting: 0, claim: 0 };
  const key = (r) => (typeof r === 'string' ? new URL(r, ORIGIN).href : r.url);
  const caches = {
    open: async (n) => {
      if (!stores.has(n)) stores.set(n, new Map());
      const m = stores.get(n);
      return { match: async (r) => m.get(key(r)), put: async (r, v) => { m.set(key(r), v); }, delete: async (r) => m.delete(key(r)) };
    },
    keys: async () => [...stores.keys()],
    delete: async (n) => stores.delete(n),
  };
  const self = { location: { origin: ORIGIN }, addEventListener: (t, f) => { handlers[t] = f; },
    skipWaiting: () => { flags.skipWaiting++; return Promise.resolve(); }, clients: { claim: () => { flags.claim++; return Promise.resolve(); } } };
  const fetchFn = async (r) => {
    const u = key(r);
    fetched.push(u);
    const f = origin_files[u];
    if (!f) return new Resp({ status: 404 });    // nothing scripted: a plain 404, recorded in `fetched`
    return new Resp(typeof f === 'function' ? f() : f);
  };
  vm.runInNewContext(src, { self, caches, fetch: fetchFn, URL, Promise, Object, Array, RegExp, String });
  return { handlers, stores, fetched, flags, caches };
}

function request(url, o) {
  o = o || {};
  const h = o.headers || {};
  return { url: new URL(url, ORIGIN).href, method: o.method || 'GET', headers: { get: (k) => h[k.toLowerCase()] || null } };
}

async function dispatch(w, url, o) {
  const ev = { request: request(url, o), answered: false, waits: [],
    respondWith(p) { this.answered = true; this.p = Promise.resolve(p); }, waitUntil(p) { this.waits.push(Promise.resolve(p)); } };
  w.handlers.fetch(ev);
  const response = ev.answered ? await ev.p : null;
  await Promise.all(ev.waits);
  return { answered: ev.answered, response };
}

function cacheName() { return /"cache":"([^"]+)"/.exec(src)[1]; }
function held(w) { return [...(w.stores.get(cacheName()) || new Map()).keys()].map((u) => u.replace(ORIGIN, '')); }

const facts = {};
(async () => {
  // what the worker will not answer: the browser fetches these as it would without one
  {
    const files = {};
    const w = world(files);
    const refused = {};
    const cases = {
      odoo_endpoint: ['/cgi-bin/lazysite-odoo.pl'],
      odoo_endpoint_script_name: ['/cgi-bin/anything.js'],
      auth_endpoint: ['/cgi-bin/lazysite-auth.pl'],
      endpoint_off_cgi_bin: ['/x/lazysite-auth.pl/more.js'],
      manager_script: ['/manager/app.js'],
      manager_image: ['/manager/logo.png'],
      sign_in_style: ['/login/x.css'],
      sign_out_script: ['/logout/x.js'],
      engine_tree: ['/lazysite/cache/a.js'],
      page: ['/portal/'],
      page_html: ['/portal/index.html'],
      page_binding_url: ['/portal/shop?x=1'],
      post_script: ['/assets/a.js', { method: 'POST' }],
      other_origin: ['https://cdn.example.test/x.js'],
      ranged: ['/assets/big.js', { headers: { range: 'bytes=0-9' } }],
    };
    for (const [k, [u, o]] of Object.entries(cases)) { refused[k] = (await dispatch(w, u, o)).answered; }
    facts.answered = refused;
    facts.fetched_when_refused = w.fetched.length;
    facts.held_when_refused = held(w);
    // and what it will answer
    facts.answers = {
      script: (await dispatch(world({ [ORIGIN + '/assets/a.js']: { body: 'js' } }), '/assets/a.js')).answered,
      style: (await dispatch(world({ [ORIGIN + '/assets/a.css']: { body: 'css' } }), '/assets/a.css')).answered,
      image: (await dispatch(world({ [ORIGIN + '/i/a.png']: { body: 'png' } }), '/i/a.png')).answered,
    };
  }

  // a response that says no-store or private is never kept, and a copy kept before is dropped
  {
    const keep = {};
    const files = {
      [ORIGIN + '/assets/ok.js']: { headers: { 'cache-control': 'no-cache, must-revalidate' }, body: 'ok' },
      [ORIGIN + '/assets/ns.js']: { headers: { 'cache-control': 'no-store' }, body: 'ns' },
      [ORIGIN + '/assets/pv.css']: { headers: { 'cache-control': 'private, max-age=60' }, body: 'pv' },
      [ORIGIN + '/assets/pub.js']: { headers: { 'cache-control': 'public, max-age=60' }, body: 'pub' },
      [ORIGIN + '/i/pv.png']: { headers: { 'cache-control': 'private' }, body: 'pv' },
      [ORIGIN + '/i/ns.png']: { headers: { 'cache-control': 'max-age=5, NO-STORE' }, body: 'ns' },
      [ORIGIN + '/i/ok.png']: { headers: { 'cache-control': 'public, max-age=5' }, body: 'ok' },
      [ORIGIN + '/assets/404.js']: { status: 404, body: 'gone' },
      [ORIGIN + '/assets/206.js']: { status: 206, body: 'part' },
      [ORIGIN + '/assets/opaque.js']: { type: 'opaque', body: '' },
      [ORIGIN + '/assets/vary.js']: { headers: { vary: '*' }, body: 'v' },
    };
    const w = world(files);
    for (const u of ['/assets/ok.js', '/assets/ns.js', '/assets/pv.css', '/assets/pub.js', '/i/pv.png', '/i/ns.png', '/i/ok.png',
      '/assets/404.js', '/assets/206.js', '/assets/opaque.js', '/assets/vary.js']) { await dispatch(w, u); }
    facts.kept = held(w).sort();

    // a file that was public and becomes protected stops being served from the device
    let protectedNow = false;
    const w2 = world({ [ORIGIN + '/assets/flip.js']: () => (protectedNow
      ? { headers: { 'cache-control': 'no-store' }, body: 'secret' } : { body: 'public' }) });
    await dispatch(w2, '/assets/flip.js');
    const before = held(w2);
    protectedNow = true;
    const second = await dispatch(w2, '/assets/flip.js');   // answered from the copy, revalidated behind
    const afterSecond = held(w2);
    const third = await dispatch(w2, '/assets/flip.js');    // now network only
    facts.flip = { before, second_body: second.response.body, after_second: afterSecond, third_body: third.response.body };
  }

  // stale-while-revalidate and cache-first
  {
    let n = 0, m = 0;
    const w = world({ [ORIGIN + '/assets/v.js']: () => ({ body: 'v' + (++n) }), [ORIGIN + '/i/c.png']: () => ({ body: 'png' + (++m) }) });
    const a = await dispatch(w, '/assets/v.js');
    const b = await dispatch(w, '/assets/v.js');
    const c = await dispatch(w, '/assets/v.js');
    facts.swr = { first: a.response.body, second: b.response.body, third: c.response.body };
    const before = w.fetched.length;
    const i1 = await dispatch(w, '/i/c.png');
    const i2 = await dispatch(w, '/i/c.png');
    const i3 = await dispatch(w, '/i/c.png');
    facts.image = { bodies: [i1, i2, i3].map((r) => r.response.body), fetches: w.fetched.length - before };
  }

  // install precaches the shell (skipping what says no-store), activate drops old worker caches only
  {
    const files = {
      [ORIGIN + '/assets/lazysite-chrome.css']: { body: 'c' },
      [ORIGIN + '/assets/lazysite-chrome.js']: { body: 'j' },
      [ORIGIN + '/assets/lazysite-app.js']: { body: 'a' },
    };
    const shell = JSON.parse(/"shell":(\[[^\]]*\])/.exec(src)[1]);
    for (const u of shell) { if (!files[ORIGIN + u]) files[ORIGIN + u] = { body: 'x' }; }
    files[ORIGIN + shell[0]] = { headers: { 'cache-control': 'no-store' }, body: 'private' };
    const w = world(files);
    w.stores.set('lazysite-app-old-111111111111', new Map([['https://x/a', 1]]));
    w.stores.set('someone-elses-cache', new Map([['https://x/b', 1]]));
    const ev = { waits: [], waitUntil(p) { this.waits.push(Promise.resolve(p)); } };
    w.handlers.install(ev);
    await Promise.all(ev.waits);
    facts.install = { shell, held: held(w).sort(), skip_waiting: w.flags.skipWaiting,
      fetched_shell: shell.every((u) => w.fetched.includes(ORIGIN + u)) };
    const av = { waits: [], waitUntil(p) { this.waits.push(Promise.resolve(p)); } };
    w.handlers.activate(av);
    await Promise.all(av.waits);
    facts.activate = { caches: [...w.stores.keys()].sort(), claim: w.flags.claim, current: cacheName() };
  }

  console.log(JSON.stringify(facts));
})().catch((e) => { console.log(JSON.stringify({ error: String(e && e.stack || e) })); });
