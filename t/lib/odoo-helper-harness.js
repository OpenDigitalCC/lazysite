/* The behaviour of starter/assets/lazysite-odoo.js, run under node with a fake
 * fetch that records every request. Loaded by t/unit/odoo/31; prints one JSON
 * object of facts for the Perl test to assert on. No DOM: the prompt is replaced
 * by a stand-in (the DOM prompt is checked by its source), so what is tested here
 * is the part that can loop, leak or double-send: tokens, the one retry on a
 * CSRF refusal, the one retry after a sign-in, and what a sign-in request holds. */
'use strict';
const fs = require('fs');
const vm = require('vm');
const src = fs.readFileSync(process.argv[2], 'utf8');

function world(script) {
  const log = [];
  const win = {
    fetch: async (u, o) => {
      const req = { url: u, method: o.method, headers: o.headers || {}, credentials: o.credentials,
        body: o.body === undefined ? undefined : JSON.parse(o.body) };
      log.push(req);
      const r = script(req, log);
      return { status: r.status, text: async () => (r.raw !== undefined ? r.raw : JSON.stringify(r.body)) };
    },
  };
  vm.runInNewContext(src, { window: win, Promise, JSON, encodeURIComponent, Object, String });
  return { api: win.LazysiteOdoo, log };
}

const facts = {};

(async () => {
  // a read is a GET with the binding and its fields, and needs no token
  {
    const w = world(() => ({ status: 200, body: { ok: true, report: { rows: [{ a: 1 }] } } }));
    const r = await w.api.read('shop-list', { limit: 2, q: 'a b&c' });
    facts.read = { n: w.log.length, method: w.log[0].method, url: w.log[0].url, status: r.status, ok: r.data.ok,
      credentials: w.log[0].credentials };
  }

  // a POST carries the visitor token; a stale one is fetched again and the POST sent ONCE more
  {
    let tok = 0, posts = 0;
    const w = world((req) => {
      if (req.method === 'GET') return { status: 200, body: { ok: true, visitor_token: 'T' + (++tok) } };
      posts++;
      return posts === 1 ? { status: 403, body: { ok: false, kind: 'csrf' } } : { status: 200, body: { ok: true, planned: true } };
    });
    const r = await w.api.write('basket', { product: 1 });
    facts.csrf_retry = { status: r.status, posts: w.log.filter(x => x.method === 'POST').map(x => x.body.visitor_token),
      token_fetches: w.log.filter(x => x.method === 'GET').length };
  }

  // a token that is stale TWICE is not tried a third time
  {
    const w = world((req) => req.method === 'GET'
      ? { status: 200, body: { ok: true, visitor_token: 'T' } }
      : { status: 403, body: { ok: false, kind: 'csrf' } });
    const r = await w.api.write('basket', {});
    facts.csrf_twice = { status: r.status, posts: w.log.filter(x => x.method === 'POST').length };
  }

  // tokens are fetched once for several POSTs
  {
    const w = world((req) => req.method === 'GET'
      ? { status: 200, body: { ok: true, visitor_token: 'T' } }
      : { status: 200, body: { ok: true } });
    await w.api.write('a', {}); await w.api.write('b', {}); await w.api.confirm('p'.repeat(32));
    facts.token_once = { fetches: w.log.filter(x => x.method === 'GET').length };
  }

  // sign in required: ask once, send the call once more; a second refusal is returned, never looped
  {
    let asked = 0;
    const w = world(() => ({ status: 401, body: { ok: false, kind: 'signin-required', error: 'sign in' } }));
    w.api.prompt = async (why) => { asked++; facts.prompt_why = why; return true; };
    const r = await w.api.read('mine', {});
    facts.signin_loop = { status: r.status, asked, gets: w.log.length };
  }

  // the prompt resolves, the retry succeeds
  {
    let n = 0;
    const w = world(() => (++n === 1 ? { status: 401, body: { ok: false, kind: 'signin-required' } }
      : { status: 200, body: { ok: true, report: { rows: [] } } }));
    w.api.prompt = async () => true;
    const r = await w.api.read('mine', {});
    facts.signin_then_ok = { status: r.status, gets: w.log.length };
  }

  // cancelled: the call is not sent again
  {
    const w = world(() => ({ status: 401, body: { ok: false, kind: 'signin-required' } }));
    w.api.prompt = async () => false;
    const r = await w.api.read('mine', {});
    facts.cancelled = { status: r.status, gets: w.log.length };
  }

  // a caller can ask for no prompt
  {
    let asked = 0;
    const w = world(() => ({ status: 401, body: { ok: false, kind: 'signin-required' } }));
    w.api.prompt = async () => { asked++; return true; };
    await w.api.read('mine', {}, { prompt: false });
    facts.no_prompt = { asked };
  }

  // a write that needs a sign-in is sent again once, with its token
  {
    let posts = 0;
    const w = world((req) => {
      if (req.method === 'GET') return { status: 200, body: { ok: true, visitor_token: 'T' } };
      return ++posts === 1 ? { status: 401, body: { ok: false, kind: 'signin-required' } } : { status: 200, body: { ok: true, planned: true } };
    });
    w.api.prompt = async () => true;
    const r = await w.api.write('my-add', { product: 1 });
    facts.write_signin = { status: r.status, posts: posts };
  }

  // signing in: the password is in the body of one POST and nowhere else
  {
    const PW = 'hunter2-Sentinel-Value';
    const w = world((req) => req.method === 'GET'
      ? { status: 200, body: { ok: true, visitor_token: 'VT' } }
      : { status: 200, body: { ok: true, signed_in: true, identity: { name: 'Jane' } } });
    const r = await w.api.signIn('jane@example.com', PW);
    const post = w.log.find(x => x.method === 'POST');
    const everything = JSON.stringify(w.log.map(x => ({ url: x.url, method: x.method, headers: x.headers })));
    facts.signin = { status: r.status, name: r.data.identity.name, body: post.body, in_url_or_headers: everything.indexOf(PW) >= 0,
      password_in_posts: w.log.filter(x => x.body && JSON.stringify(x.body).indexOf(PW) >= 0).length,
      result_has_password: JSON.stringify(r).indexOf(PW) >= 0 };
  }

  // signing out
  {
    const w = world((req) => req.method === 'GET'
      ? { status: 200, body: { ok: true, visitor_token: 'VT' } } : { status: 200, body: { ok: true, signed_in: false } });
    const r = await w.api.signOut();
    facts.signout = { status: r.status, body: w.log.find(x => x.method === 'POST').body };
  }

  // an answer that is not JSON is data: null, never a throw
  {
    const w = world(() => ({ status: 502, raw: '<html>bad gateway</html>' }));
    const r = await w.api.read('x', {});
    facts.not_json = { status: r.status, data: r.data };
  }

  // a request that cannot be made rejects, and the caller decides
  {
    const w = world(() => { throw new Error('offline'); });
    let rejected = false;
    try { await w.api.read('x', {}); } catch (e) { rejected = true; }
    facts.offline = { rejected };
  }

  // a region fills ONLY the fields the server drew, and as text
  {
    const w = world(() => ({ status: 200, body: {} }));
    const mk = (n) => ({ getAttribute: () => n, textContent: 'unset' });
    const slots = ['name', 'note', 'obj', 'nul', 'missing'].map(mk);
    const node = { querySelectorAll: () => slots };
    w.api.fill(node, { name: '<b>x</b>', note: 'REFUSED-VALUE', obj: { a: 1 }, nul: null }, { name: {}, obj: {}, nul: {}, missing: {} });
    facts.fill = Object.fromEntries(slots.map(s => [s.getAttribute(), s.textContent]));
    const slots2 = ['name', 'note'].map(mk);
    w.api.fill({ querySelectorAll: () => slots2 }, { name: 'a', note: 'b' }, null);
    facts.fill_all = Object.fromEntries(slots2.map(s => [s.getAttribute(), s.textContent]));
  }

  console.log(JSON.stringify(facts));
})().catch((e) => { console.log(JSON.stringify({ error: String(e && e.stack || e) })); process.exit(1); });
