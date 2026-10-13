/* lazysite-odoo.js - SM747 D (OA6): the one place a page talks to the Odoo
 * endpoint, so that no page writes its own.
 *
 * WHY A SHIPPED HELPER. Every page that runs an Odoo binding would otherwise
 * write its own fetch, and each would get the same things wrong: fetch the
 * visitor token and forget to refresh it, loop on a refusal, show a sign-in box
 * that keeps the password in a variable or a URL, or put what Odoo returned into
 * the page as markup. It does five things:
 *
 *   1. fetches the tokens (GET ?csrf=1) and sends the right one on every POST;
 *   2. on a CSRF refusal fetches fresh tokens and retries ONCE - never twice;
 *   3. on "sign in" (401, kind signin-required) asks the person to sign in and
 *      retries the call ONCE - never twice, so a wrong password cannot loop;
 *   4. signs a person in and out;
 *   5. fills regions of the page from a binding, as text.
 *
 * THE PASSWORD. It is read from the box, sent in the body of one POST over
 * HTTPS to the page's own endpoint, and the box is cleared at once - before the
 * answer arrives. It is never in a URL, a cookie, a variable that outlives the
 * call, storage, the console or an event. The session it opens lives in an
 * HttpOnly cookie this script cannot read; this script never holds it.
 *
 * VALUES GO IN AS TEXT, ALWAYS, via textContent. Nothing here builds markup from
 * what Odoo returned, so a record whose name is a script tag renders as those
 * characters and does nothing. A field the server refused to draw (`refused`) is
 * not in `fields` and is not filled.
 *
 * NO DEPENDENCIES, NO CDN, NO BUILD, NO STORAGE: it serves from the site's own
 * origin and keeps nothing between page loads.
 *
 * THE MARKUP CONTRACT, for a region:
 *
 *   <div data-ls-odoo="shop-list" data-ls-odoo-limit="10">
 *     <template><li><span data-ls-field="name"></span></li></template>
 *     <p data-ls-empty>Nothing to show yet.</p>
 *   </div>
 *   <button data-ls-odoo-signin>Sign in to Odoo</button>
 *   <button data-ls-odoo-signout>Sign out</button>
 *   <span data-ls-odoo-name></span>
 *
 * `data-ls-odoo-<name>="v"` on a region is the request field `<name>`.
 */
(function (root) {
  'use strict';

  var API = {
    endpoint: '/cgi-bin/lazysite-odoo.pl',
    prompt: null            /* set below: asks the person to sign in */
  };
  var tokens = null;        /* { visitor_token, token } for this page, in memory only */

  function doc() { return root.document; }

  function url(query) {
    return API.endpoint + (query ? '?' + query : '');
  }

  function encodeQuery(params) {
    var out = [];
    Object.keys(params || {}).forEach(function (k) {
      var v = params[k];
      if (v === undefined || v === null) return;
      out.push(encodeURIComponent(k) + '=' + encodeURIComponent(String(v)));
    });
    return out.join('&');
  }

  /* One request. Resolves { status, data } - never rejects on an HTTP status,
   * so a caller reads what the endpoint said; rejects only when it could not
   * ask at all. */
  function send(method, query, body) {
    var opts = {
      method: method,
      credentials: 'same-origin',
      cache: 'no-store',
      headers: { 'Accept': 'application/json' }
    };
    if (body !== undefined) {
      opts.headers['Content-Type'] = 'application/json';
      opts.body = JSON.stringify(body);
    }
    return root.fetch(url(query), opts).then(function (res) {
      return res.text().then(function (text) {
        var data = null;
        try { data = JSON.parse(text); } catch (e) { data = null; }
        return { status: res.status, data: data };
      });
    });
  }

  /* The visitor token (and the session token, for a signed-in lazysite
   * account), fetched on demand and kept in memory only. */
  function getTokens(fresh) {
    if (tokens && !fresh) return Promise.resolve(tokens);
    return send('GET', 'csrf=1').then(function (r) {
      tokens = (r.data && r.data.ok) ? r.data : {};
      return tokens;
    });
  }

  function withTokens(body, t) {
    var out = {};
    Object.keys(body).forEach(function (k) { out[k] = body[k]; });
    if (t && t.visitor_token) out.visitor_token = t.visitor_token;
    if (t && t.token) out.token = t.token;
    return out;
  }

  function isCsrf(r) { return r.status === 403 && r.data && r.data.kind === 'csrf'; }
  function isSignin(r) { return r.status === 401 && r.data && r.data.kind === 'signin-required'; }

  /* A POST with its token. A token the server calls stale is fetched again and
   * the POST sent once more - ONCE. */
  function post(body) {
    return getTokens(false).then(function (t) {
      return send('POST', '', withTokens(body, t)).then(function (r) {
        if (!isCsrf(r)) return r;
        return getTokens(true).then(function (t2) {
          return send('POST', '', withTokens(body, t2));
        });
      });
    });
  }

  function get(params) { return send('GET', encodeQuery(params)); }

  /* The sign-in step of a call: if the endpoint says to sign in, ask the person
   * - once - and send the same call again - once. A cancelled or refused
   * sign-in ends it with the answer the endpoint gave. */
  function withSignin(attempt, opts) {
    return attempt().then(function (r) {
      if (!isSignin(r) || (opts && opts.prompt === false) || typeof API.prompt !== 'function') return r;
      return API.prompt(r.data && r.data.error).then(function (signedIn) {
        return signedIn ? attempt() : r;
      });
    });
  }

  /* run a READING binding: GET ?binding=ID&field=value */
  API.read = function (binding, params, opts) {
    var q = {}; Object.keys(params || {}).forEach(function (k) { q[k] = params[k]; });
    q.binding = binding;
    return withSignin(function () { return get(q); }, opts);
  };

  /* run a binding that may WRITE: POST {binding, params}. A write returns a
   * plan to confirm, or applies, as the binding says. */
  API.write = function (binding, params, opts) {
    return withSignin(function () { return post({ binding: binding, params: params || {} }); }, opts);
  };

  /* apply a plan this person made */
  API.confirm = function (plan, opts) {
    return withSignin(function () { return post({ plan: plan, confirm: true }); }, opts);
  };

  /* sign a person in. The password is in this call's argument and the request
   * body and nowhere else; the caller clears its own box. Resolves the
   * endpoint's answer: { status, data } with data.identity.name on success. */
  API.signIn = function (login, password) {
    return post({ signin: true, login: login, password: password }).then(function (r) {
      password = null;
      return r;
    });
  };

  API.signOut = function () {
    return post({ signout: true });
  };

  /* ---- the sign-in prompt -------------------------------------------------- */

  function el(tag, attrs, text) {
    var d = doc();
    var n = d.createElement(tag);
    Object.keys(attrs || {}).forEach(function (k) { n.setAttribute(k, attrs[k]); });
    if (text !== undefined) n.textContent = text;
    return n;
  }

  /* Asks the person for their Odoo login and password. Resolves true when
   * signed in, false when they cancel or the sign-in is refused. ONE attempt per
   * ask: a refusal says so in the box and the person can try again, but each
   * try is a fresh ask from the person, never a loop in this script. */
  API.prompt = function (why) {
    var d = doc();
    if (!d || !d.body) return Promise.resolve(false);
    return new Promise(function (resolve) {
      var box = el('div', { role: 'dialog', 'aria-modal': 'true', 'aria-label': 'Sign in to Odoo', 'data-ls-odoo-prompt': '' });
      var form = el('form', { autocomplete: 'on' });
      var msg = el('p', { role: 'alert' }, why || 'Sign in to Odoo to continue.');
      var login = el('input', { type: 'text', name: 'login', autocomplete: 'username', 'aria-label': 'Odoo login', required: 'required' });
      var pass = el('input', { type: 'password', name: 'password', autocomplete: 'current-password', 'aria-label': 'Odoo password', required: 'required' });
      var go = el('button', { type: 'submit' }, 'Sign in');
      var no = el('button', { type: 'button' }, 'Cancel');
      [msg, login, pass, go, no].forEach(function (n) { form.appendChild(n); });
      box.appendChild(form);

      function close(result) {
        pass.value = '';
        if (box.parentNode) box.parentNode.removeChild(box);
        resolve(result);
      }

      no.addEventListener('click', function () { close(false); });
      form.addEventListener('submit', function (ev) {
        ev.preventDefault();
        var l = login.value, p = pass.value;
        pass.value = '';                 /* gone from the page before the answer arrives */
        go.disabled = true;
        API.signIn(l, p).then(function (r) {
          p = null;
          go.disabled = false;
          if (r.status === 200 && r.data && r.data.ok) {
            close(true);
            var who = doc().querySelectorAll('[data-ls-odoo-name]');
            for (var i = 0; i < who.length; i++) {
              who[i].textContent = (r.data.identity && r.data.identity.name) || '';
            }
            return;
          }
          msg.textContent = (r.data && r.data.error) || 'That sign-in did not work.';
          login.focus();
        }, function () {
          p = null;
          go.disabled = false;
          msg.textContent = 'Odoo could not be reached. Try again.';
        });
      });

      d.body.appendChild(box);
      login.focus();
    });
  };

  /* ---- regions ------------------------------------------------------------- */

  function fill(node, row, allowed) {
    var slots = node.querySelectorAll('[data-ls-field]');
    for (var i = 0; i < slots.length; i++) {
      var name = slots[i].getAttribute('data-ls-field');
      if (allowed && !Object.prototype.hasOwnProperty.call(allowed, name)) continue;
      var v = row[name];
      if (v === undefined) continue;
      slots[i].textContent = v === null ? '' : (typeof v === 'object' ? JSON.stringify(v) : String(v));
    }
    return node;
  }

  function render(el_, rows, fields) {
    var tpl = el_.querySelector('template');
    if (!tpl) return;
    var empty = el_.querySelector('[data-ls-empty]');
    var frag = doc().createDocumentFragment();
    for (var i = 0; i < rows.length; i++) {
      frag.appendChild(fill(tpl.content.cloneNode(true), rows[i], fields));
    }
    var kill = [];
    for (var c = el_.firstChild; c; c = c.nextSibling) {
      if (c === tpl || (empty && c === empty)) continue;
      kill.push(c);
    }
    kill.forEach(function (n) { el_.removeChild(n); });
    el_.insertBefore(frag, empty || null);
    if (empty) empty.hidden = rows.length > 0;
    el_.setAttribute('data-ls-odoo-state', 'ready');
  }

  function params(el_) {
    var out = {};
    var attrs = el_.attributes;
    for (var i = 0; i < attrs.length; i++) {
      var m = /^data-ls-odoo-(.+)$/.exec(attrs[i].name);
      if (!m || /^(state|prompt|signin|signout|name)$/.test(m[1])) continue;
      out[m[1]] = attrs[i].value;
    }
    return out;
  }

  /* exposed so a template author can fill a node the same way, and so the test
   * can hold that a field the server refused to draw is never filled */
  API.fill = fill;

  API.load = function (el_) {
    if (el_.getAttribute('data-ls-odoo-state') === 'loading') return Promise.resolve();
    el_.setAttribute('data-ls-odoo-state', 'loading');
    var prompt = el_.hasAttribute('data-ls-odoo-prompt');
    return API.read(el_.getAttribute('data-ls-odoo'), params(el_), { prompt: prompt }).then(function (r) {
      if (isSignin(r)) {
        /* Nothing is shown in place of what needs a sign-in; what was there stays. */
        el_.setAttribute('data-ls-odoo-state', 'signin-required');
        return;
      }
      var rep = r.data && r.data.report;
      if (r.status !== 200 || !r.data || !r.data.ok || !rep || !rep.rows) {
        el_.setAttribute('data-ls-odoo-state', 'stale');
        return;
      }
      render(el_, rep.rows, r.data.fields || null);
    }, function () {
      el_.setAttribute('data-ls-odoo-state', 'stale');
    });
  };

  function start() {
    var d = doc();
    if (!d) return;
    [].slice.call(d.querySelectorAll('[data-ls-odoo]')).forEach(function (el_) { API.load(el_); });
    [].slice.call(d.querySelectorAll('[data-ls-odoo-signin]')).forEach(function (b) {
      b.addEventListener('click', function () {
        API.prompt().then(function (ok) {
          if (ok) [].slice.call(d.querySelectorAll('[data-ls-odoo]')).forEach(function (r) { API.load(r); });
        });
      });
    });
    [].slice.call(d.querySelectorAll('[data-ls-odoo-signout]')).forEach(function (b) {
      b.addEventListener('click', function () {
        API.signOut().then(function () { root.location.reload(); });
      });
    });
  }

  root.LazysiteOdoo = API;
  if (root.document) {
    if (root.document.readyState === 'loading') {
      root.document.addEventListener('DOMContentLoaded', start);
    } else {
      start();
    }
  }
})(typeof window !== 'undefined' ? window : globalThis);
