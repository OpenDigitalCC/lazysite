/* SM1162: the file half of starter/assets/lazysite-odoo.js, run under node with a
 * fake fetch that records every request INCLUDING a FormData body (node 18+ has
 * FormData and Blob). Loaded by t/unit/odoo/68; prints one JSON object of facts.
 * Separate from odoo-helper-harness.js, whose fetch reads every body as JSON. */
'use strict';
const fs = require('fs');
const vm = require('vm');
const src = fs.readFileSync(process.argv[2], 'utf8');

async function describe(body) {
  if (body === undefined) return { kind: 'none' };
  if (typeof body === 'string') return { kind: 'json', json: JSON.parse(body) };
  if (typeof FormData !== 'undefined' && body instanceof FormData) {
    const parts = [];
    for (const [name, v] of body.entries()) {
      if (typeof v === 'string') parts.push({ name, text: v });
      else parts.push({ name, filename: v.name, size: v.size, type: v.type, text: await v.text() });
    }
    return { kind: 'form', parts };
  }
  return { kind: 'other' };
}

function world(script) {
  const log = [];
  const win = {
    Blob, FormData,
    fetch: async (u, o) => {
      const req = { url: u, method: o.method, headers: o.headers || {}, credentials: o.credentials, body: await describe(o.body) };
      log.push(req);
      const r = script(req, log);
      return { status: r.status, text: async () => JSON.stringify(r.body) };
    },
  };
  vm.runInNewContext(src, { window: win, Promise, JSON, encodeURIComponent, Object, String, Array, Error });
  return { api: win.LazysiteOdoo, log };
}

const facts = {};
const posts = (w) => w.log.filter((x) => x.method === 'POST');

(async () => {
  // a File among the params is sent as multipart/form-data: the JSON part carries the
  // plain values and the token, each file its own part named for the field
  {
    const w = world((req) => req.method === 'GET'
      ? { status: 200, body: { ok: true, visitor_token: 'VT1' } }
      : { status: 200, body: { ok: true, applied: true } });
    const photo = new Blob(['\xFF\xD8JPEGBYTES'], { type: 'image/jpeg' });
    const r = await w.api.write('expense', { note: 'lunch', photo: photo, shots: [new Blob(['a']), new Blob(['bb'])] });
    const p = posts(w)[0];
    facts.upload = { status: r.status, n_posts: posts(w).length, url: p.url, kind: p.body.kind,
      content_type: p.headers['Content-Type'] === undefined, // the browser writes it, with the boundary
      json: JSON.parse(p.body.parts.find((x) => x.name === 'json').text),
      json_has_filename: p.body.parts.find((x) => x.name === 'json').filename !== undefined,
      files: p.body.parts.filter((x) => x.filename !== undefined).map((x) => [x.name, x.filename, x.size]) };
    facts.upload_photo_type = p.body.parts.find((x) => x.name === 'photo').type;
    facts.upload_in_json = JSON.stringify(JSON.parse(p.body.parts.find((x) => x.name === 'json').text)).indexOf('JPEGBYTES') >= 0;
  }

  // a named File keeps its name
  {
    const w = world((req) => req.method === 'GET' ? { status: 200, body: { ok: true, visitor_token: 'T' } } : { status: 200, body: { ok: true } });
    const f = new File(['x'], 'receipt.jpg', { type: 'image/jpeg' });
    await w.api.write('expense', { photo: f });
    facts.named = posts(w)[0].body.parts.find((x) => x.name === 'photo').filename;
  }

  // no file: exactly today's JSON POST
  {
    const w = world((req) => req.method === 'GET' ? { status: 200, body: { ok: true, visitor_token: 'T' } } : { status: 200, body: { ok: true } });
    await w.api.write('basket', { product: 1 });
    const p = posts(w)[0];
    facts.json_path = { url: p.url, kind: p.body.kind, ct: p.headers['Content-Type'], params: p.body.json.params, token: p.body.json.visitor_token };
  }

  // a stale token: the multipart POST is sent again ONCE, with a fresh FormData and the fresh token
  {
    let tok = 0, n = 0;
    const w = world((req) => {
      if (req.method === 'GET') return { status: 200, body: { ok: true, visitor_token: 'T' + (++tok) } };
      return ++n === 1 ? { status: 403, body: { ok: false, kind: 'csrf' } } : { status: 200, body: { ok: true } };
    });
    const r = await w.api.write('expense', { photo: new Blob(['abc']) });
    facts.csrf_retry = { status: r.status, tokens: posts(w).map((x) => JSON.parse(x.body.parts.find((y) => y.name === 'json').text).visitor_token),
      file_both_times: posts(w).map((x) => x.body.parts.find((y) => y.name === 'photo').text) };
  }

  // a stale token twice is not tried a third time
  {
    const w = world((req) => req.method === 'GET' ? { status: 200, body: { ok: true, visitor_token: 'T' } } : { status: 403, body: { ok: false, kind: 'csrf' } });
    const r = await w.api.write('expense', { photo: new Blob(['abc']) });
    facts.csrf_twice = { status: r.status, posts: posts(w).length };
  }

  // sign in required: ask once, send the call (with its file) once more
  {
    let n = 0, asked = 0;
    const w = world((req) => req.method === 'GET' ? { status: 200, body: { ok: true, visitor_token: 'T' } }
      : (++n === 1 ? { status: 401, body: { ok: false, kind: 'signin-required' } } : { status: 200, body: { ok: true } }));
    w.api.prompt = async () => { asked++; return true; };
    const r = await w.api.write('mine', { photo: new Blob(['abc']) });
    facts.signin = { status: r.status, asked, posts: posts(w).length,
      file_second: posts(w)[1].body.parts.find((y) => y.name === 'photo').text };
  }

  // a batch carries no files: refused before anything is sent
  {
    const w = world(() => ({ status: 200, body: { ok: true, results: [] } }));
    let err = null;
    try { await w.api.batch([{ binding: 'a', params: { photo: new Blob(['x']) } }]); } catch (e) { err = String(e.message); }
    facts.batch = { err, sent: w.log.length };
  }

  // an empty list is not a file: it goes in the JSON as a plain (empty) value
  {
    const w = world((req) => req.method === 'GET' ? { status: 200, body: { ok: true, visitor_token: 'T' } } : { status: 200, body: { ok: true } });
    await w.api.write('a', { shots: [] });
    facts.empty_list = posts(w)[0].body.kind;
  }

  console.log(JSON.stringify(facts));
})().catch((e) => { console.log(JSON.stringify({ error: String(e && e.stack || e) })); });
