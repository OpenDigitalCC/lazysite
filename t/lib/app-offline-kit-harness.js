/* The behaviour of the offline kit (extensions/app-offline/assets/kit.js) on top
 * of the Odoo browser helper, run under node against a REAL endpoint stand-in
 * on 127.0.0.1 that records every request it receives, with its
 * Idempotency-Key. Loaded by t/unit/extensions/78; prints one JSON object of
 * facts for the Perl test to assert on. What is tested is what can double-send,
 * leak across people or lose a change: the queue, the guard, the owner. */
'use strict';
const fs = require('fs');
const vm = require('vm');
const http = require('http');

const helperSrc = fs.readFileSync(process.argv[2], 'utf8');
const kitSrc = fs.readFileSync(process.argv[3], 'utf8');

/* ---- the endpoint stand-in ------------------------------------------------ */
const cfg = { owner: null, signedIn: false, failNext: 0 };
const requests = [];           /* { method, url, key, body, answered } */

const server = http.createServer((req, res) => {
  let raw = '';
  req.on('data', (c) => { raw += c; });
  req.on('end', () => {
    const rec = { method: req.method, url: req.url, key: req.headers['idempotency-key'] || null,
      body: raw ? (() => { try { return JSON.parse(raw); } catch (e) { return raw; } })() : null, answered: true };
    requests.push(rec);
    if (req.method === 'POST' && cfg.failNext > 0) {
      cfg.failNext--;
      rec.answered = false;
      req.socket.destroy();            /* cut off: no answer ever comes */
      return;
    }
    let body;
    if (req.method === 'GET' && /csrf=1/.test(req.url)) {
      body = { ok: true, visitor_token: 'VT', odoo_signed_in: cfg.signedIn ? 1 : 0 };
      if (cfg.owner) body.owner = cfg.owner;
      if (cfg.signedIn) body.identity = { name: 'Jane' };
    } else if (req.method === 'GET') {
      body = { ok: true, report: { rows: [{ name: 'Widget', n: requests.length }] } };
    } else if (rec.body && rec.body.signout) {
      body = { ok: true };
    } else {
      body = { ok: true, planned: true, key: rec.key };
    }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(body));
  });
});

/* ---- a browser stand-in ------------------------------------------------------ */
function world(base) {
  const store = new Map();
  const handlers = {};
  const win = {
    navigator: { onLine: true },
    localStorage: {
      getItem: (k) => (store.has(k) ? store.get(k) : null),
      setItem: (k, v) => { store.set(k, String(v)); },
      removeItem: (k) => { store.delete(k); },
    },
    down: false,
    fetch: (u, o) => {
      if (win.down) return Promise.reject(new TypeError('Failed to fetch'));
      return fetch(base + u, o);
    },
    addEventListener: (n, f) => { (handlers[n] = handlers[n] || []).push(f); },
    dispatchEvent: (e) => { (handlers[e.type] || []).forEach((f) => f(e)); return true; },
    CustomEvent: class CustomEvent { constructor(type, init) { this.type = type; this.detail = init && init.detail; } },
    crypto: require('crypto').webcrypto,
    location: { search: '' },
    matchMedia: () => ({ matches: false }),
    setTimeout, clearTimeout,
  };
  win.document = {
    readyState: 'complete',
    visibilityState: 'visible',
    querySelectorAll: () => [],
    addEventListener: () => {},
  };
  win.window = win;
  const ctx = { window: win, Promise, JSON, encodeURIComponent, decodeURIComponent, Object, String, Array, Math, Date, Error, TypeError, RegExp };
  vm.runInNewContext(helperSrc, ctx);
  vm.runInNewContext(kitSrc, ctx);
  return { win, odoo: win.LazysiteOdoo, kit: win.LazysiteAppOffline, store,
    stored: () => JSON.parse(store.get('lazysite-app-offline:v1') || '{"owners":{}}'),
    posts: () => requests.filter((r) => r.method === 'POST' && !(r.body && r.body.signout)) };
}

function fire(w, type) { w.win.dispatchEvent(new w.win.CustomEvent(type)); }

const facts = {};

server.listen(0, '127.0.0.1', async () => {
  const base = 'http://127.0.0.1:' + server.address().port;
  const A = 'signin:0123456789abcdef', B = 'signin:fedcba9876543210';
  try {
    /* A. offline: two changes queued, the signal back twice over: each sent ONCE */
    {
      cfg.owner = A; cfg.signedIn = true;
      const w = world(base);
      await w.kit.flush();
      facts.owner_learnt = w.kit.owner();
      w.win.navigator.onLine = false;
      const r1 = await w.kit.write('basket', { product: 1 });
      const r2 = await w.kit.write('basket', { product: 2 });
      const before = w.posts().length;
      w.win.navigator.onLine = true;
      fire(w, 'online'); fire(w, 'online');
      await w.kit.flush();
      const posts = w.posts().slice(before);
      facts.queue = { r1: r1.data.kind, r2: r2.data.kind, keys_differ: r1.data.key !== r2.data.key,
        posted_before_online: before, posts: posts.length, keys: posts.map((p) => p.key),
        bindings: posts.map((p) => p.body && p.body.binding), expected: [r1.data.key, r2.data.key],
        queue_after: w.kit.queued(), queued_answer_status: r1.status };
    }
    /* B. cut off mid-send: kept with its key, sent again with the SAME key */
    {
      cfg.owner = A; cfg.signedIn = true; cfg.failNext = 1;
      const w = world(base);
      await w.kit.flush();
      const before = w.posts().length;
      const r = await w.kit.write('basket', { product: 3 });
      const cut = w.posts().slice(before);
      w.win.navigator.onLine = true;
      fire(w, 'online');
      await w.kit.flush();
      const all = w.posts().slice(before);
      facts.cut_off = { answer: r.data.kind, key: r.data.key, cut_posts: cut.length, cut_answered: cut.map((p) => p.answered),
        posts: all.length, keys: all.map((p) => p.key), queue_after: w.kit.queued() };
    }
    /* C. nobody signed in: nothing is queued, nothing is sent, nothing is kept */
    {
      cfg.owner = null; cfg.signedIn = false;
      const w = world(base);
      await w.kit.flush();
      const before = w.posts().length;
      w.win.navigator.onLine = false;
      const r = await w.kit.write('basket', { product: 4 });
      facts.no_owner = { answer: r.data.kind, posts: w.posts().length - before, owners: Object.keys(w.stored().owners) };
    }
    /* C2. a default Odoo site (rulings 161, 163): signed in to Odoo, named, and no
     * owner - the endpoint names one only where the Odoo sign-in is the site
     * sign-in. A change is refused offline and online, sent never; a read is
     * answered live and kept for nobody. */
    {
      cfg.owner = null; cfg.signedIn = true;
      const w = world(base);
      await w.kit.flush();
      const before = w.posts().length;
      w.win.navigator.onLine = false;
      const off = await w.kit.write('basket', { product: 41 });
      w.win.navigator.onLine = true;
      fire(w, 'online');
      await w.kit.flush();
      const on = await w.kit.write('basket', { product: 42 });
      const live = await w.odoo.read('shop-list', { limit: 2 });
      w.win.down = true;
      let kept;
      try { kept = await w.odoo.read('shop-list', { limit: 2 }); } catch (e) { kept = 'rejected'; }
      w.win.down = false;
      facts.default_site = { owner: w.kit.owner(), offline: off.data.kind, online: on.data.kind,
        posts: w.posts().length - before, queued: w.kit.queued(), live_status: live.status,
        kept_read: kept === 'rejected' ? 'rejected' : 'answered', owners: Object.keys(w.stored().owners) };
    }
    /* D. another login on the same browser: A's queue is not sent as B, and stays A's */
    {
      cfg.owner = A; cfg.signedIn = true;
      const w = world(base);
      await w.kit.flush();
      w.win.navigator.onLine = false;
      const r = await w.kit.write('basket', { product: 5 });
      cfg.owner = B;
      const before = w.posts().length;
      w.win.navigator.onLine = true;
      fire(w, 'online');
      await w.kit.flush();
      const s = w.stored();
      facts.other_login = { queued: r.data.kind, posts: w.posts().length - before, owner_now: w.kit.owner(),
        a_queue: (s.owners[A] || { queue: [] }).queue.length, b_queue: (s.owners[B] || { queue: [] }).queue.length,
        b_visible_queue: w.kit.queued() };
    }
    /* E. online: sent at once, once, with a key, and not queued */
    {
      cfg.owner = A; cfg.signedIn = true;
      const w = world(base);
      await w.kit.flush();
      const before = w.posts().length;
      const r = await w.kit.write('basket', { product: 6 }, { idempotencyKey: 'page-gave-this-key' });
      const posts = w.posts().slice(before);
      facts.online = { status: r.status, planned: !!(r.data && r.data.planned), posts: posts.length,
        key: posts[0] && posts[0].key, queue_after: w.kit.queued() };
    }
    /* F. kept reads: the last good answer, answered when the network is gone, for the owner alone */
    {
      cfg.owner = A; cfg.signedIn = true;
      const w = world(base);
      await w.kit.flush();
      const live = await w.odoo.read('shop-list', { limit: 2 });
      w.win.down = true;
      const kept = await w.odoo.read('shop-list', { limit: 2 });
      let other;
      try { other = await w.odoo.read('shop-list', { limit: 3 }); } catch (e) { other = 'rejected'; }
      facts.kept = { live_status: live.status, live_kept: !!live.kept, kept_status: kept.status, kept_flag: !!kept.kept,
        kept_rows: kept.data.report.rows[0].name, kept_marked: !!kept.data.kept, kept_at: typeof kept.kept_at,
        other_read: other === 'rejected' ? 'rejected' : 'answered' };
      /* another login finds nothing of A's */
      w.win.down = false;
      cfg.owner = B;
      await w.kit.flush();
      w.win.down = true;
      let b;
      try { b = await w.odoo.read('shop-list', { limit: 2 }); } catch (e) { b = 'rejected'; }
      facts.kept.other_owner = b === 'rejected' ? 'rejected' : 'answered';
    }
    /* G. signing out drops what was kept for the person; a queued change waits for them */
    {
      cfg.owner = A; cfg.signedIn = true;
      const w = world(base);
      await w.kit.flush();
      await w.odoo.read('shop-list', { limit: 2 });
      w.win.navigator.onLine = false;
      await w.kit.write('basket', { product: 7 });
      w.win.navigator.onLine = true;
      const before = JSON.parse(JSON.stringify(w.stored().owners[A]));
      await w.odoo.signOut();
      const after = w.stored().owners[A];
      facts.signout = { reads_before: Object.keys(before.reads).length, queue_before: before.queue.length,
        reads_after: Object.keys(after.reads).length, queue_after: after.queue.length, owner_after: w.kit.owner() };
    }
    /* H. what the store holds: never a token, a password or a cookie */
    {
      const all = JSON.stringify(Array.from(world(base).store.values()));
      facts.store_text = { has_token: /VT|visitor_token/.test(all) };
    }
  } catch (e) {
    facts.error = String(e && e.stack || e);
  }
  server.close();
  process.stdout.write(JSON.stringify(facts));
});
