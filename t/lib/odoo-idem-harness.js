/* SM1223: the Idempotency-Key half of starter/assets/lazysite-odoo.js, run under node
 * with a fake fetch that records every request's headers. Loaded by
 * t/unit/odoo/98; prints one JSON object of facts. */
'use strict';
const fs = require('fs');
const vm = require('vm');
const src = fs.readFileSync(process.argv[2], 'utf8');

function world(script) {
  const log = [];
  const win = {
    Blob, FormData,
    fetch: async (u, o) => {
      log.push({ url: u, method: o.method, headers: o.headers || {}, isForm: typeof FormData !== 'undefined' && o.body instanceof FormData,
        json: typeof o.body === 'string' ? JSON.parse(o.body) : null });
      const r = script(log[log.length - 1], log);
      return { status: r.status, text: async () => JSON.stringify(r.body) };
    },
  };
  vm.runInNewContext(src, { window: win, Promise, JSON, encodeURIComponent, Object, String, Array, Error });
  return { api: win.LazysiteOdoo, log };
}
const posts = (w) => w.log.filter((x) => x.method === 'POST');
const tok = (req) => (req.method === 'GET' ? { status: 200, body: { ok: true, visitor_token: 'VT' } } : null);
const facts = {};

(async () => {
  {   // a write with a key: the header, on the one POST
    const w = world((req) => tok(req) || { status: 200, body: { ok: true, applied: true } });
    await w.api.write('expense', { amount: '1' }, { idempotencyKey: 'queue-item-0001-aaaa' });
    facts.write = { n: posts(w).length, key: posts(w)[0].headers['Idempotency-Key'], body_has_key: JSON.stringify(posts(w)[0].json).indexOf('queue-item') >= 0,
      get_has_key: w.log.filter((x) => x.method === 'GET').some((x) => x.headers['Idempotency-Key'] !== undefined) };
  }
  {   // no key: no header
    const w = world((req) => tok(req) || { status: 200, body: { ok: true } });
    await w.api.write('expense', { amount: '1' });
    facts.none = posts(w)[0].headers['Idempotency-Key'];
  }
  {   // a stale token and a sign-in each send the call again, with the same key
    let p = 0;
    const w2 = world((req) => {
      if (req.method === 'GET') return { status: 200, body: { ok: true, visitor_token: 'VT' } };
      p++;
      return p === 1 ? { status: 403, body: { ok: false, kind: 'csrf' } } : { status: 200, body: { ok: true } };
    });
    await w2.api.write('expense', { amount: '1' }, { idempotencyKey: 'queue-item-0002-bbbb' });
    facts.retry = posts(w2).map((x) => x.headers['Idempotency-Key']);
  }
  {   // a confirm takes one too
    const w = world((req) => tok(req) || { status: 200, body: { ok: true } });
    await w.api.confirm('a'.repeat(32), { idempotencyKey: 'confirm-key-0003-cc' });
    facts.confirm = { key: posts(w)[0].headers['Idempotency-Key'], confirm: posts(w)[0].json.confirm };
  }
  {   // a file upload keeps it too
    const w = world((req) => tok(req) || { status: 200, body: { ok: true } });
    await w.api.write('expense', { photo: new Blob(['x']) }, { idempotencyKey: 'upload-item-0004-dd' });
    facts.upload = { form: posts(w)[0].isForm, key: posts(w)[0].headers['Idempotency-Key'] };
  }
  console.log(JSON.stringify(facts));
})().catch((e) => { console.log(JSON.stringify({ error: String(e && e.stack || e) })); });
