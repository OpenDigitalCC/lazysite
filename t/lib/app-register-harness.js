/* What starter/assets/lazysite-app.js says and does (SM1155, SM1197), run under
 * node with a stand-in browser: navigator, document, window, console. argv[2] is
 * the script. Each scenario builds its own world, runs the script, lets the
 * promises settle and reports what reached the console and the window. Prints
 * one JSON object. */
'use strict';
const fs = require('fs');
const vm = require('vm');
const src = fs.readFileSync(process.argv[2], 'utf8');

function world(o) {
  const log = { warn: [], events: [], posted: [], reloads: 0, registered: [] };
  const listeners = {};
  const script = { getAttribute: (k) => (o.attrs || { 'data-ls-app-sw': '/portal/lazysite-sw.js', 'data-ls-app-scope': '/portal/' })[k] || null };
  const reg = o.registration || {};
  reg.addEventListener = reg.addEventListener || ((t, f) => { (reg._l = reg._l || {})[t] = f; });
  const swc = { controller: o.controller === undefined ? {} : o.controller,
    register: (u, opt) => { log.registered.push([u, opt && opt.scope]); return o.reject ? Promise.reject(o.reject) : Promise.resolve(reg); },
    addEventListener: (t, f) => { listeners[t] = f; } };
  const win = { isSecureContext: o.secure !== false,
    addEventListener: () => {}, removeEventListener: () => {},
    dispatchEvent: (e) => { log.events.push({ type: e.type, detail: e.detail }); return true; },
    location: { reload: () => { log.reloads++; } } };
  const ctx = { navigator: o.noSW ? {} : { serviceWorker: swc }, window: win,
    document: { querySelector: (s) => (/data-ls-app-sw/.test(s) ? script : null) },
    console: { warn: (...a) => log.warn.push(a.join(' ')), log: () => {}, error: () => {} },
    CustomEvent: function (type, init) { this.type = type; this.detail = init && init.detail; }, Promise, Error, Object, String };
  win.location = win.location; ctx.location = win.location;
  vm.runInNewContext(src, ctx);
  return { log, reg, swc, listeners, win };
}
const settle = () => new Promise((r) => setTimeout(r, 5));

const facts = {};
(async () => {
  { const w = world({ reject: new Error('A bad HTTP response code (404) was received when fetching the script.') }); await settle();
    facts.rejected_404 = w.log.warn; }
  { const e = new Error('Failed to register a ServiceWorker: ServiceWorker script evaluation failed'); e.name = 'TypeError';
    const w = world({ reject: e }); await settle(); facts.rejected_script = w.log.warn; }
  { const e = new Error('The operation is insecure.'); e.name = 'SecurityError';
    const w = world({ reject: e }); await settle(); facts.rejected_security = w.log.warn; }
  { const w = world({ noSW: true, secure: false }); await settle(); facts.insecure = w.log.warn; }
  { const w = world({ noSW: true, secure: true }); await settle(); facts.no_support = w.log.warn; }
  { const w = world({}); await settle(); facts.ok = { warn: w.log.warn, registered: w.log.registered, events: w.log.events }; }

  // the update that waits: offered to the page, applied only when the page asks
  const waitAttrs = { 'data-ls-app-sw': '/portal/lazysite-sw.js', 'data-ls-app-scope': '/portal/', 'data-ls-app-update': 'wait' };
  {
    const waiting = { posted: [], postMessage(m) { this.posted.push(m); } };
    const w = world({ attrs: waitAttrs, registration: { waiting } });
    await settle();
    facts.waiting_at_load = { events: w.log.events.map((e) => e.type), reloads: w.log.reloads, posted_before: waiting.posted.length };
    const ev = w.log.events[0];
    facts.has_apply = !!(ev && ev.detail && typeof ev.detail.apply === 'function');
    if (facts.has_apply) ev.detail.apply();
    facts.after_apply = { posted: waiting.posted, reloads_before_swap: w.log.reloads };
    w.listeners.controllerchange && w.listeners.controllerchange();
    facts.after_swap = { reloads: w.log.reloads };
  }
  {   // a controllerchange nobody asked for (another tab's update) does not reload this page
    const w = world({ attrs: waitAttrs, registration: {} });
    await settle();
    w.listeners.controllerchange && w.listeners.controllerchange();
    facts.unasked_swap_reloads = w.log.reloads;
  }
  {   // a new worker found while the page is open
    const installing = { state: 'installing', l: {}, addEventListener(t, f) { this.l[t] = f; } };
    const reg = { installing: null, waiting: null };
    const w = world({ attrs: waitAttrs, registration: reg });
    await settle();
    reg.installing = installing;
    reg._l.updatefound();
    installing.state = 'installed';
    reg.waiting = { posted: [], postMessage(m) { this.posted.push(m); } };
    installing.l.statechange();
    facts.found_later = w.log.events.map((e) => e.type);
  }
  {   // first install, no controller yet: nothing to offer
    const w = world({ attrs: waitAttrs, controller: null, registration: { waiting: { postMessage() {} } } });
    await settle();
    facts.first_install = w.log.events.map((e) => e.type);
  }
  {   // not the waiting mode: the page is never asked
    const w = world({ registration: { waiting: { postMessage() {} } } });
    await settle();
    facts.now_mode_events = w.log.events.map((e) => e.type);
  }
  console.log(JSON.stringify(facts));
})().catch((e) => { console.log(JSON.stringify({ error: String(e && e.stack || e) })); });
