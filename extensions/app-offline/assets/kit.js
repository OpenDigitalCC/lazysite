/* kit.js - the offline kit (SM1396, ruling 53; the app-offline extension).
 *
 * A site installed as an app (SM1155) keeps the pages it lists for offline
 * (SM1197). This script makes such a page WORK with no signal, on top of the
 * Odoo browser helper (/assets/lazysite-odoo.js), which it wraps:
 *
 *   1. a connection banner: [data-ls-app-banner] is shown while the browser is
 *      offline, hidden while it is online;
 *   2. kept reads: the last good answer for each read a page makes is kept,
 *      and answered when the same read fails for want of a network - marked
 *      `kept` with the time it was kept, and the region marked data-ls-app-kept;
 *   3. a write guard: LazysiteAppOffline.write() sends a change at once when it
 *      can, and queues it when it cannot - and a queued change is sent ONCE,
 *      with the Idempotency-Key that makes a resend safe (SM1223), so a send
 *      that was cut off is sent again with the same key and the server does
 *      not write twice;
 *   4. the queue: sent in order when the signal is back, and never from two
 *      flushes at once;
 *   5. install and update status: [data-ls-app-status] says whether the page
 *      runs installed, and offers a waiting update (lazysite-app-update) to
 *      apply with a tap;
 *   6. sign-out: signing out drops what was kept for that person; a queued
 *      change waits for them.
 *
 * WHAT IS KEPT IS OWNED BY LOGIN (ruling 53). The endpoint's ?csrf=1 names the
 * signed-in person by `owner`, a label of the login that is not the login. A
 * kept read or a queued change is stored under that owner, shown to and sent
 * for no other login on the same browser, and one made with no owner - nobody
 * signed in, or an identity that has lapsed - is dropped, never queued. The
 * store is this browser's localStorage, under this site's origin; it holds
 * what the endpoint answered a page and what a page asked to send, never a
 * token, a cookie or a password.
 *
 * THE SLOTS a layout may carry: data-ls-app-banner, data-ls-app-show-out,
 * data-ls-app-show-in, data-ls-app-status. Each is toggled with `hidden` and
 * marked with data-ls-app-state; the kit writes text only into the status.
 *
 * NO DEPENDENCIES, NO CDN, NO BUILD: served by the engine from the extension's
 * own payload at /assets/app-offline-kit.js. */
(function (root) {
  'use strict';

  var STORE = 'lazysite-app-offline:v1';
  var MAX_READS = 50;      /* kept reads per owner */
  var MAX_QUEUE = 100;     /* queued changes per owner */
  var state = { owner: null, signedIn: false, online: true, flushing: null, update: null };
  var listeners = [];

  function doc() { return root.document; }
  function now() { return new Date().toISOString(); }
  function odoo() { return root.LazysiteOdoo || null; }

  /* ---- the store ----------------------------------------------------------- */

  function storage() {
    try { return root.localStorage || null; } catch (e) { return null; }
  }
  function load() {
    var s = storage();
    if (!s) return { owners: {} };
    try {
      var v = JSON.parse(s.getItem(STORE) || 'null');
      return v && v.owners ? v : { owners: {} };
    } catch (e) { return { owners: {} }; }
  }
  function save(data) {
    var s = storage();
    if (!s) return false;
    try { s.setItem(STORE, JSON.stringify(data)); return true; } catch (e) { return false; }
  }
  function bucket(data, owner) {
    data.owners[owner] = data.owners[owner] || { reads: {}, queue: [] };
    return data.owners[owner];
  }

  function readKey(binding, params) {
    var keys = Object.keys(params || {}).sort();
    return String(binding) + '?' + keys.map(function (k) {
      return encodeURIComponent(k) + '=' + encodeURIComponent(String(params[k]));
    }).join('&');
  }

  function keep(owner, key, answer) {
    if (!owner) return;
    var data = load(), b = bucket(data, owner);
    b.reads[key] = { at: now(), data: answer };
    var ks = Object.keys(b.reads);
    if (ks.length > MAX_READS) {
      ks.sort(function (a, c) { return b.reads[a].at < b.reads[c].at ? -1 : 1; });
      ks.slice(0, ks.length - MAX_READS).forEach(function (k) { delete b.reads[k]; });
    }
    save(data);
  }
  function kept(owner, key) {
    if (!owner) return null;
    var data = load();
    var b = data.owners[owner];
    return b && b.reads[key] ? b.reads[key] : null;
  }

  function newKey() {
    var c = root.crypto;
    if (c && typeof c.randomUUID === 'function') return c.randomUUID();
    var out = '', hex = '0123456789abcdef';
    for (var i = 0; i < 32; i++) out += hex.charAt(Math.floor(Math.random() * 16));
    return out;
  }

  /* ---- who, and the connection --------------------------------------------- */

  function endpoint() {
    var o = odoo();
    return (o && o.endpoint) || '/cgi-bin/lazysite-odoo.pl';
  }

  /* Asks the endpoint who is signed in: `owner` is the label of the login, or
   * absent. Resolves the owner (or null); never rejects. */
  function askOwner() {
    return root.fetch(endpoint() + '?csrf=1', { credentials: 'same-origin', cache: 'no-store',
      headers: { 'Accept': 'application/json' } })
      .then(function (res) { return res.text().then(function (t) { try { return JSON.parse(t); } catch (e) { return {}; } }); })
      .then(function (d) {
        state.signedIn = !!(d && d.odoo_signed_in);
        state.owner = d && typeof d.owner === 'string' && /^signin:[0-9a-f]{16}$/.test(d.owner) ? d.owner : null;
        markOnline(true);
        return state.owner;
      }, function () { markOnline(false); return state.owner; });
  }

  function markOnline(on) {
    state.online = !!on;
    render();
  }
  function online() {
    var n = root.navigator;
    return !(n && n.onLine === false) && state.online;
  }

  /* ---- the slots ----------------------------------------------------------- */

  function all(sel) {
    var d = doc();
    return d && d.querySelectorAll ? [].slice.call(d.querySelectorAll(sel)) : [];
  }
  function installed() {
    var m = root.matchMedia;
    try { return !!(m && m('(display-mode: standalone)').matches) || !!(root.navigator && root.navigator.standalone); } catch (e) { return false; }
  }
  function queued() {
    if (!state.owner) return 0;
    var b = load().owners[state.owner];
    return b ? b.queue.length : 0;
  }
  function render() {
    var on = online(), n = queued();
    all('[data-ls-app-banner]').forEach(function (el) {
      el.hidden = on;
      el.setAttribute('data-ls-app-state', on ? 'online' : 'offline');
      el.setAttribute('data-ls-app-queued', String(n));
    });
    all('[data-ls-app-show-out]').forEach(function (el) { el.hidden = !!state.owner; });
    all('[data-ls-app-show-in]').forEach(function (el) { el.hidden = !state.owner; });
    all('[data-ls-app-status]').forEach(function (el) {
      var inst = installed();
      el.setAttribute('data-ls-app-installed', inst ? 'yes' : 'no');
      el.setAttribute('data-ls-app-queued', String(n));
      if (state.update) {
        el.setAttribute('data-ls-app-update', 'ready');
        el.textContent = 'A new version is ready - tap to update';
      } else {
        el.removeAttribute('data-ls-app-update');
        el.textContent = (inst ? 'Installed as an app' : 'Running in the browser') + (n ? ' - ' + n + ' change' + (n === 1 ? '' : 's') + ' waiting to send' : '');
      }
    });
  }

  function emit(detail) {
    if (typeof root.CustomEvent === 'function' && typeof root.dispatchEvent === 'function') {
      root.dispatchEvent(new root.CustomEvent('lazysite-app-offline', { detail: detail }));
    }
    listeners.forEach(function (f) { try { f(detail); } catch (e) { /* a listener's fault is its own */ } });
  }

  /* ---- the write guard and the queue --------------------------------------- */

  function hasFiles(params) {
    return !!root.Blob && Object.keys(params || {}).some(function (k) {
      var v = params[k];
      return v instanceof root.Blob || (Array.isArray(v) && v.length > 0 && v.every(function (x) { return x instanceof root.Blob; }));
    });
  }

  function enqueue(owner, item) {
    var data = load(), b = bucket(data, owner);
    if (b.queue.some(function (q) { return q.key === item.key; })) return true;   /* already waiting */
    if (b.queue.length >= MAX_QUEUE) return false;
    b.queue.push(item);
    return save(data);
  }
  function dequeue(owner, key) {
    var data = load(), b = data.owners[owner];
    if (!b) return;
    b.queue = b.queue.filter(function (q) { return q.key !== key; });
    save(data);
  }

  /* One send of one change, through the helper, with its key. prompt:false -
   * a queue is sent in the background and never opens the sign-in dialog. */
  function sendOnce(item) {
    var o = odoo();
    if (!o) return Promise.reject(new Error('the Odoo helper is not on this page'));
    return o.write(item.binding, item.params, { idempotencyKey: item.key, prompt: false });
  }

  function queuedAnswer(key) {
    return { status: 0, queued: true, data: { ok: false, kind: 'queued', key: key,
      error: 'no connection: the change is kept and will be sent once the signal is back' } };
  }

  var API = {};

  /* The owner the kit last learnt (a label, never the login), or null. */
  API.owner = function () { return state.owner; };
  API.queued = function () { return queued(); };
  API.onChange = function (f) { if (typeof f === 'function') listeners.push(f); };

  /* write(binding, params, opts) - as LazysiteOdoo.write, guarded:
   *   online, it is sent at once with a key (opts.idempotencyKey or a new one)
   *   and the answer is the endpoint's; cut off, or offline, it is queued for
   *   the signed-in owner and the answer says `queued` with the key; with no
   *   owner it is refused (`no-owner`) and kept nowhere; a change carrying a
   *   file is never queued (a file cannot be kept here). */
  API.write = function (binding, params, opts) {
    opts = opts || {};
    var key = opts.idempotencyKey !== undefined && opts.idempotencyKey !== null ? String(opts.idempotencyKey) : newKey();
    var owner = state.owner;
    if (!owner) {
      return Promise.resolve({ status: 0, data: { ok: false, kind: 'no-owner',
        error: 'sign in before making a change: nothing is kept for nobody' } });
    }
    var item = { key: key, binding: String(binding), params: params || {}, at: now(), owner: owner };
    if (hasFiles(params)) {
      if (!online()) return Promise.resolve({ status: 0, data: { ok: false, kind: 'offline', error: 'no connection, and a file cannot be kept for later' } });
      return sendOnce(item);
    }
    if (!online()) {
      enqueue(owner, item);
      render();
      emit({ type: 'queued', key: key, binding: item.binding });
      return Promise.resolve(queuedAnswer(key));
    }
    return sendOnce(item).then(function (r) {
      markOnline(true);
      return r;
    }, function () {
      /* cut off: no answer came, so the change is kept with its key and sent
         again later - the key is what makes that resend safe */
      markOnline(false);
      enqueue(owner, item);
      render();
      emit({ type: 'queued', key: key, binding: item.binding });
      return queuedAnswer(key);
    });
  };

  /* Sends the owner's queue, in order, one flush at a time. An item leaves the
   * queue when ANY answer comes back (the page is told what it was); it stays
   * when the send was cut off (sent again next time, same key), or when the
   * endpoint says to sign in (it belongs to the person, who is not here). */
  API.flush = function () {
    if (state.flushing) return state.flushing;
    state.flushing = askOwner().then(function (owner) {
      if (!owner || !online()) return { sent: 0 };
      var data = load(), b = data.owners[owner];
      var items = b ? b.queue.slice() : [];
      var sent = 0;
      function next(i) {
        if (i >= items.length) return { sent: sent };
        var item = items[i];
        return sendOnce(item).then(function (r) {
          if (r && r.status === 401 && r.data && r.data.kind === 'signin-required') {
            state.owner = null;
            render();
            return { sent: sent, stopped: 'signin-required' };
          }
          dequeue(owner, item.key);
          sent++;
          render();
          emit({ type: 'sent', key: item.key, binding: item.binding, status: r.status, data: r.data });
          return next(i + 1);
        }, function () {
          markOnline(false);
          return { sent: sent, stopped: 'offline' };
        });
      }
      return next(0);
    }).then(function (r) { state.flushing = null; return r; }, function () { state.flushing = null; return { sent: 0 }; });
    return state.flushing;
  };

  /* ---- kept reads: wrap the helper ------------------------------------------- */

  var wrapped = false;
  function wrap() {
    var o = odoo();
    if (!o || wrapped) return;
    wrapped = true;
    var read = o.read, load_ = o.load, signIn = o.signIn, signInCode = o.signInCode, signOut = o.signOut;

    o.read = function (binding, params, opts) {
      var key = readKey(binding, params);
      return read.call(o, binding, params, opts).then(function (r) {
        markOnline(true);
        if (r && r.status === 200 && r.data && r.data.ok) keep(state.owner, key, r.data);
        return r;
      }, function (err) {
        markOnline(false);
        var k = kept(state.owner, key);
        if (!k) throw err;
        var data = {};
        Object.keys(k.data).forEach(function (f) { data[f] = k.data[f]; });
        data.kept = true;
        data.kept_at = k.at;
        return { status: 200, kept: true, kept_at: k.at, data: data };
      });
    };

    if (typeof load_ === 'function') {
      o.load = function (el) {
        var key = readKey(el.getAttribute('data-ls-odoo'), regionParams(el));
        return load_.call(o, el).then(function (r) {
          var k = kept(state.owner, key);
          if (!online() && k) el.setAttribute('data-ls-app-kept', k.at);
          else el.removeAttribute('data-ls-app-kept');
          return r;
        });
      };
    }

    function afterSignin(r) {
      if (r && r.data && r.data.signed_in) {
        askOwner().then(function () { render(); API.flush(); });
      }
      return r;
    }
    if (typeof signIn === 'function') o.signIn = function (l, p) { return signIn.call(o, l, p).then(afterSignin); };
    if (typeof signInCode === 'function') o.signInCode = function (c, m) { return signInCode.call(o, c, m).then(afterSignin); };
    if (typeof signOut === 'function') {
      o.signOut = function () {
        var owner = state.owner;
        return signOut.call(o).then(function (r) {
          /* what was kept for the person goes with the sign-out; a queued
             change waits for them (it is theirs, and nobody else's) */
          if (owner) {
            var data = load();
            if (data.owners[owner]) { data.owners[owner].reads = {}; save(data); }
          }
          state.owner = null;
          state.signedIn = false;
          render();
          return r;
        });
      };
    }
  }

  /* the request fields a region carries, as the helper reads them */
  function regionParams(el) {
    var out = {};
    var attrs = el.attributes || [];
    for (var i = 0; i < attrs.length; i++) {
      var m = /^data-ls-odoo-(.+)$/.exec(attrs[i].name);
      if (!m || /^(state|prompt|signin|signout|name|in|out|banner|unknown|next|not-kept)$/.test(m[1])) continue;
      out[m[1]] = attrs[i].value;
    }
    return out;
  }

  /* ---- start ----------------------------------------------------------------- */

  function start() {
    wrap();
    render();
    askOwner().then(function () { render(); if (queued()) API.flush(); });
  }

  if (typeof root.addEventListener === 'function') {
    root.addEventListener('online', function () { markOnline(true); API.flush(); });
    root.addEventListener('offline', function () { markOnline(false); });
    root.addEventListener('lazysite-app-update', function (e) {
      state.update = e && e.detail && typeof e.detail.apply === 'function' ? e.detail.apply : null;
      render();
    });
  }
  if (doc() && typeof doc().addEventListener === 'function') {
    doc().addEventListener('visibilitychange', function () {
      if (doc().visibilityState === 'visible' && queued()) API.flush();
    });
    doc().addEventListener('click', function (ev) {
      var t = ev && ev.target;
      while (t && t.getAttribute && !t.hasAttribute('data-ls-app-status')) t = t.parentNode;
      if (t && t.getAttribute && state.update) { ev.preventDefault(); state.update(); }
    });
  }

  root.LazysiteAppOffline = API;
  if (odoo()) wrap();
  if (doc()) {
    if (doc().readyState === 'loading') doc().addEventListener('DOMContentLoaded', start);
    else start();
  }
})(typeof window !== 'undefined' ? window : globalThis);
