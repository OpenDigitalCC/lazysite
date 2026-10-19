/* lazysite-odoo.js - SM747 D (OA6): the one place a page talks to the Odoo
 * endpoint, so that no page writes its own.
 *
 * WHY A SHIPPED HELPER. Every page that runs an Odoo binding would otherwise
 * write its own fetch, and each would get the same things wrong: fetch the
 * visitor token and forget to refresh it, loop on a refusal, show a sign-in box
 * that keeps the password in a variable or a URL, or put what Odoo returned into
 * the page as markup. It does eight things:
 *
 *   1. fetches the tokens (GET ?csrf=1) and sends the right one on every POST;
 *   2. on a CSRF refusal fetches fresh tokens and retries ONCE - never twice;
 *   3. on "sign in" (401, kind signin-required) asks the person to sign in and
 *      retries the call ONCE - never twice, so a wrong password cannot loop;
 *   4. signs a person in and out, including Odoo's own two-factor code step;
 *   5. fills regions of the page from a binding, as text;
 *   6. runs several calls in one request (`batch`, SM1146);
 *   7. shows who is signed in, from the tokens it already fetches (SM1145);
 *   8. sends a File (or Blob, or a list of them) in a binding call's params as
 *      multipart/form-data (SM1162), see `write` below.
 *
 * THE SECOND FACTOR (SM1157). An Odoo account with two-factor authentication
 * answers the password with { second_factor: 'totp' } and nothing else: the
 * server holds the half-open sign-in in its own signed HttpOnly cookie, and the
 * dialog changes to ask for the 6-digit code from the person's authenticator app.
 * A wrong code says so and asks again (Odoo counts the tries); a sign-in that has
 * run out sends the person back to the password. "Remember this device" is shown
 * only when the site offers it, and what Odoo returns for it goes into a cookie
 * this script cannot read. The code is handled as the password is: read from the
 * box, the box cleared at once, sent in one POST, never kept.
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
 *
 * `<span data-ls-odoo-name>` is filled, as text, with the display name of the
 * person signed in to Odoo when the page loads (SM1145): from the answer to the
 * token fetch, which reads the identity cookie this script cannot read, so the
 * page costs no Odoo call to say who is here. It is left as it is when nobody is
 * signed in or the identity has lapsed (the next call that reaches Odoo
 * freshens it).
 */
(function (root) {
  'use strict';

  var API = {
    endpoint: '/cgi-bin/lazysite-odoo.pl',
    prompt: null            /* set below: asks the person to sign in */
  };
  var tokens = null;        /* { visitor_token, token, identity } for this page, in memory only */
  var pending = null;       /* the token fetch in flight, so two askers share one request */

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
  function send(method, query, body, form) {
    var opts = {
      method: method,
      credentials: 'same-origin',
      cache: 'no-store',
      headers: { 'Accept': 'application/json' }
    };
    if (form) {
      /* SM1162: a FormData. No Content-Type here: the browser writes it, with the boundary. */
      opts.body = form;
    } else if (body !== undefined) {
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
    /* SM1145: the name fill and a first POST both ask at load; one request answers both */
    if (pending && !fresh) return pending;
    var p = send('GET', 'csrf=1').then(function (r) {
      tokens = (r.data && r.data.ok) ? r.data : {};
      pending = null;
      return tokens;
    }, function (e) {
      pending = null;
      throw e;
    });
    pending = p;
    return p;
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

  /* SM1162: FILES. A File is a Blob. A value that is one (or a non-empty list of
   * them) is a file, and goes as a part of a multipart request; everything else
   * goes in the JSON part, as it always has. */
  function isBlob(v) { return !!root.Blob && v instanceof root.Blob; }
  function isFiles(v) {
    return isBlob(v) || (Array.isArray(v) && v.length > 0 && v.every(isBlob));
  }
  function splitFiles(params) {
    var plain = {}, files = {}, any = false;
    Object.keys(params || {}).forEach(function (k) {
      if (isFiles(params[k])) { files[k] = [].concat(params[k]); any = true; }
      else plain[k] = params[k];
    });
    return { plain: plain, files: any ? files : null };
  }

  /* One multipart POST: the JSON body (params and the token) as the part named
   * `json`, each file as a part named for its field. The binding is in the query
   * so the server knows its size cap before it reads the body. The FormData is
   * built afresh for each send, so a retry never reuses a spent one. */
  function formFor(binding, split, t) {
    var fd = new root.FormData();
    fd.append('json', JSON.stringify(withTokens({ binding: binding, params: split.plain }, t)));
    Object.keys(split.files).forEach(function (field) {
      split.files[field].forEach(function (b) { fd.append(field, b, b.name || 'file'); });
    });
    return fd;
  }

  function postFiles(binding, split) {
    var q = 'binding=' + encodeURIComponent(binding);
    return getTokens(false).then(function (t) {
      return send('POST', q, undefined, formFor(binding, split, t)).then(function (r) {
        if (!isCsrf(r)) return r;
        return getTokens(true).then(function (t2) {
          return send('POST', q, undefined, formFor(binding, split, t2));
        });
      });
    });
  }

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
  /* SM1162: a File, a Blob or a list of them among the params is sent as
   * multipart/form-data, the rest in its JSON part; the binding names which
   * request field is a file (file_params) and how large one may be. A binding
   * call with no file goes exactly as before. */
  API.write = function (binding, params, opts) {
    var split = splitFiles(params);
    if (split.files) {
      return withSignin(function () { return postFiles(binding, split); }, opts);
    }
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

  /* the second request of a two-factor sign-in: the code for the half-open
   * sign-in the server holds. Like the password, it is in this call's argument
   * and the request body and nowhere else. */
  API.signInCode = function (code, remember) {
    return post({ signin_code: true, code: code, remember: remember ? true : false }).then(function (r) {
      code = null;
      return r;
    });
  };

  API.signOut = function () {
    return post({ signout: true });
  };

  /* SM1146: several calls in ONE request - POST {calls: [{binding, params}, ...]},
   * at most ten (the endpoint says so beyond that). Each call is a {binding,
   * params} or a {plan, confirm: true}, and each is answered in order with its own
   * `status`: resolves { status: 200, data: { ok, results: [...] } }, a failing
   * call leaving the others as they were. A call the endpoint refused for a stale
   * token is sent again ONCE, with fresh tokens; one it refused for want of a
   * sign-in, once more after the person has been asked ONCE - and only those
   * calls, never the whole batch. */
  function isCsrfResult(x) { return !!x && x.status === 403 && x.kind === 'csrf'; }
  function isSigninResult(x) { return !!x && x.status === 401 && x.kind === 'signin-required'; }

  API.batch = function (calls, opts) {
    var list = (calls || []).slice();
    /* SM1162: a batch carries no files; each file goes in a write() of its own */
    var withFile = list.some(function (c) {
      return c && c.params && Object.keys(c.params).some(function (k) { return isFiles(c.params[k]); });
    });
    if (withFile) return Promise.reject(new Error('a batch carries no files: send each call with a file as its own write()'));
    function run(items) { return post({ calls: items }); }
    return run(list).then(function (r) {
      if (r.status !== 200 || !r.data || !r.data.results) return r;
      var results = r.data.results.slice();
      /* the calls `pred` picks are sent once more, if `before` says to */
      function redo(pred, before) {
        var idx = [];
        results.forEach(function (x, i) { if (pred(x)) idx.push(i); });
        if (!idx.length) return Promise.resolve();
        return before(results[idx[0]]).then(function (go) {
          if (!go) return;
          return run(idx.map(function (i) { return list[i]; })).then(function (r2) {
            if (r2.status !== 200 || !r2.data || !r2.data.results) return;
            idx.forEach(function (i, k) { results[i] = r2.data.results[k]; });
          });
        });
      }
      return redo(isCsrfResult, function () {
        return getTokens(true).then(function () { return true; });
      }).then(function () {
        return redo(isSigninResult, function (first) {
          if ((opts && opts.prompt === false) || typeof API.prompt !== 'function') return Promise.resolve(false);
          return API.prompt(first && first.error);
        });
      }).then(function () {
        r.data.results = results;
        return r;
      });
    });
  };

  /* SM1145: who is signed in to Odoo - { name } from the token fetch, or
   * null. Asks Odoo nothing. */
  API.who = function () {
    return getTokens(false).then(function (t) {
      return (t && t.identity) || null;
    }, function () { return null; });
  };

  /* fills every [data-ls-odoo-name] with the display name, as text; a page with
   * no such node makes no request for it */
  API.showName = function () {
    var d = doc();
    if (!d) return Promise.resolve();
    var nodes = d.querySelectorAll('[data-ls-odoo-name]');
    if (!nodes.length) return Promise.resolve();
    return API.who().then(function (id) {
      var named = !!(id && id.name);
      if (named) for (var i = 0; i < nodes.length; i++) nodes[i].textContent = String(id.name);
      banner(named);
    });
  };

  /* SM1160: the page's "Signed in as <name>" (the engine's odoo_signin_banner): the signed-in
   * part shows when there is a name, the sign-in link when there is not. Display only. */
  function banner(signedIn) {
    var d = doc();
    [].slice.call(d.querySelectorAll('[data-ls-odoo-in]')).forEach(function (n) { n.hidden = !signedIn; });
    [].slice.call(d.querySelectorAll('[data-ls-odoo-out]')).forEach(function (n) { n.hidden = !!signedIn; });
  }

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

      function signedIn(r) {
        close(true);
        var who = doc().querySelectorAll('[data-ls-odoo-name]');
        for (var i = 0; i < who.length; i++) {
          who[i].textContent = (r.data.identity && r.data.identity.name) || '';
        }
      }

      /* The dialog's second step: ask for Odoo's code. The password fields go;
       * the sign-in itself is waiting at the server, not here. */
      function askCode(offerRemember) {
        var cform = el('form', { autocomplete: 'off' });
        var cmsg = el('p', { role: 'alert' }, 'Enter the 6-digit code from your authenticator app.');
        var code = el('input', { type: 'text', name: 'code', inputmode: 'numeric', autocomplete: 'one-time-code',
          maxlength: '12', 'aria-label': 'Authenticator code', required: 'required' });
        var remember = null;
        var rlabel = null;
        if (offerRemember) {
          remember = el('input', { type: 'checkbox', name: 'remember', id: 'ls-odoo-remember' });
          rlabel = el('label', { 'for': 'ls-odoo-remember' }, "Don't ask again on this device");
        }
        var verify = el('button', { type: 'submit' }, 'Verify');
        var cancel = el('button', { type: 'button' }, 'Cancel');
        [cmsg, code].concat(remember ? [remember, rlabel] : [], [verify, cancel]).forEach(function (n) { cform.appendChild(n); });
        box.removeChild(form);
        box.appendChild(cform);
        code.focus();

        cancel.addEventListener('click', function () {
          code.value = '';
          API.signOut().then(function () {}, function () {});   /* ends the half-open sign-in at Odoo */
          close(false);
        });
        cform.addEventListener('submit', function (ev) {
          ev.preventDefault();
          var c = code.value, rem = remember ? remember.checked : false;
          code.value = '';               /* gone from the page before the answer arrives */
          verify.disabled = true;
          API.signInCode(c, rem).then(function (r) {
            c = null;
            verify.disabled = false;
            if (r.status === 200 && r.data && r.data.ok) { signedIn(r); return; }
            if (r.data && r.data.kind === 'signin-required') {
              /* the half-open sign-in has run out: back to the password */
              box.removeChild(cform);
              box.appendChild(form);
              msg.textContent = r.data.error || 'The sign-in has run out. Sign in again.';
              login.focus();
              return;
            }
            cmsg.textContent = (r.data && r.data.error) || 'That code did not work.';
            code.focus();
          }, function () {
            c = null;
            verify.disabled = false;
            cmsg.textContent = 'Odoo could not be reached. Try again.';
          });
        });
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
          if (r.status === 200 && r.data && r.data.ok && r.data.second_factor === 'totp') {
            askCode(r.data.remember_offered === 1 || r.data.remember_offered === true);
            return;
          }
          if (r.status === 200 && r.data && r.data.ok) { signedIn(r); return; }
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
      if (!m || /^(state|prompt|signin|signout|name|in|out|banner)$/.test(m[1])) continue;
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
    API.showName();
    [].slice.call(d.querySelectorAll('[data-ls-odoo]')).forEach(function (el_) { API.load(el_); });
    [].slice.call(d.querySelectorAll('[data-ls-odoo-signin]')).forEach(function (b) {
      b.addEventListener('click', function (ev) {
        if (ev && ev.preventDefault) ev.preventDefault();
        API.prompt().then(function (ok) {
          if (ok) {
            tokens = null;                                   /* the sign-in changed who this is */
            API.showName();
            [].slice.call(d.querySelectorAll('[data-ls-odoo]')).forEach(function (r) { API.load(r); });
          }
        });
      });
    });
    [].slice.call(d.querySelectorAll('[data-ls-odoo-signout]')).forEach(function (b) {
      b.addEventListener('click', function (ev) {
        if (ev && ev.preventDefault) ev.preventDefault();
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
