/* lazysite-account.js - SM1043 (SM1034 phase 1a): the member's own account page.
 *
 * Binds the built-in ::: account-* components on /account to the control API's
 * me-* actions. SM1352: it also binds the passkey regions of the sign-in
 * and setup-link pages, which talk to the auth wrapper (lazysite-auth.pl) instead,
 * because nobody is signed in there yet (the setup link names its own account).
 * Every me-* action acts on the signed-in caller and nobody else: this script
 * never sends one an account name, because the server would not read one. It
 * sends the session cookie (same origin) and the CSRF token the `csrf-token`
 * action mints for that session, on every POST.
 *
 * VALUES GO IN AS TEXT, ALWAYS - textContent, never innerHTML - as in
 * lazysite-data.js. A display name, a browser string, a notice: all of it is
 * somebody's text, and none of it is markup.
 *
 * Shipped, vendored into the site's /assets/ like every engine asset; no
 * dependencies, no CDN, no build. The processor adds it to a page that carries
 * a data-ls-account region, so a component never has to.
 */
(function () {
  'use strict';

  var API = '/cgi-bin/lazysite-manager-api.pl';
  var csrf = null;

  function q(root, sel) { return root.querySelector(sel); }
  function qa(root, sel) { return Array.prototype.slice.call(root.querySelectorAll(sel)); }

  function say(region, text, bad) {
    var el = q(region, '[data-ls-status]');
    if (!el) return;
    el.textContent = text || '';
    el.classList.toggle('lz-account-error', !!bad);
  }

  function call(action, opts) {
    opts = opts || {};
    var url = API + '?action=' + encodeURIComponent(action);
    var init = { credentials: 'same-origin', headers: { 'Accept': 'application/json' } };
    if (opts.body) {
      init.method = 'POST';
      init.headers['Content-Type'] = 'application/json';
      init.headers['X-CSRF-Token'] = csrf || '';
      init.body = JSON.stringify(opts.body);
    }
    return fetch(url, init).then(function (r) {
      return r.json().catch(function () { return { ok: false, error: 'The server answered with something that is not JSON (' + r.status + ').' }; });
    }, function () {
      return { ok: false, error: 'The server could not be reached.' };
    });
  }

  function token() {
    if (csrf) return Promise.resolve(csrf);
    return call('csrf-token').then(function (r) { csrf = (r && r.token) || ''; return csrf; });
  }

  function post(action, body) {
    return token().then(function () { return call(action, { body: body || {} }); });
  }

  function when(t) {
    var d = new Date((t || 0) * 1000);
    return isNaN(d.getTime()) ? '' : d.toLocaleString();
  }

  // --- summary --------------------------------------------------------------
  var me = null;
  function loadMe() {
    if (me) return Promise.resolve(me);
    return call('me').then(function (r) { me = r; return r; });
  }

  function summary(region) {
    loadMe().then(function (r) {
      if (!r || !r.ok) { say(region, (r && r.error) || 'Your account could not be read.', true); return; }
      var set = function (f, v) { qa(region, '[data-ls-field="' + f + '"]').forEach(function (el) { el.textContent = v; }); };
      set('user', r.user || '');
      set('display_name', r.display_name || '');
      set('email', r.email || '');
      set('groups', (r.groups || []).join(', '));
      set('mfa', r.mfa_enrolled ? 'On' : (r.mfa_pending ? 'Being set up' : 'Off'));
    });
  }

  // --- password -------------------------------------------------------------
  function password(region) {
    var form = q(region, 'form[data-ls-form]');
    if (!form) return;
    loadMe().then(function (r) {
      if (!r || !r.ok) return;
      var min = r.password_min_length || 12;
      var hint = q(region, '[data-ls-field="policy"]');
      if (hint) hint.textContent = 'At least ' + min + ' characters.';
      var nw = q(form, '[data-ls-minlength]');
      if (nw) nw.setAttribute('minlength', String(min));
      var u = q(form, '[data-ls-field="user"]');
      if (u) u.value = r.user || '';
    });
    form.addEventListener('submit', function (ev) {
      ev.preventDefault();
      var cur = form.elements.current_password.value;
      var nw = form.elements.new_password.value;
      var again = form.elements.confirm_password.value;
      if (nw !== again) { say(region, 'The two new passwords are not the same.', true); return; }
      var btn = q(form, 'button[type="submit"]');
      if (btn) btn.disabled = true;
      say(region, 'Changing your password…');
      post('me-password', { current_password: cur, new_password: nw }).then(function (res) {
        if (btn) btn.disabled = false;
        if (res && res.ok) {
          form.reset();
          say(region, res.message || 'Password changed.');
          document.dispatchEvent(new CustomEvent('lz-account-changed'));
        } else {
          say(region, (res && res.error) || 'The password was not changed.', true);
        }
      });
    });
  }

  // --- sessions -------------------------------------------------------------
  function sessions(region) {
    var body = q(region, '[data-ls-rows]');
    var empty = q(region, '[data-ls-empty]');
    function render() {
      call('me-sessions').then(function (r) {
        if (!r || !r.ok) { say(region, (r && r.error) || 'Your sessions could not be read.', true); return; }
        while (body && body.firstChild) body.removeChild(body.firstChild);
        var rows = r.sessions || [];
        if (empty) empty.hidden = rows.length > 0;
        rows.forEach(function (s) {
          var tr = document.createElement('tr');
          [when(s.issued) + (s.current ? ' (this session)' : ''), s.ip || '', s.ua || ''].forEach(function (v) {
            var td = document.createElement('td'); td.textContent = v; tr.appendChild(td);
          });
          var td = document.createElement('td');
          var b = document.createElement('button');
          b.type = 'button';
          b.textContent = s.current ? 'Sign out here' : 'Sign out';
          b.addEventListener('click', function () {
            post('me-session-revoke', { sid: s.sid }).then(function (res) {
              if (res && res.ok && res.current) { window.location.href = '/login'; return; }
              say(region, (res && res.ok) ? 'That session is signed out.' : ((res && res.error) || 'It was not signed out.'), !(res && res.ok));
              render();
            });
          });
          td.appendChild(b); tr.appendChild(td);
          if (body) body.appendChild(tr);
        });
      });
    }
    var all = q(region, '[data-ls-everywhere]');
    if (all) all.addEventListener('click', function () {
      post('me-sign-out-everywhere', {}).then(function (res) {
        if (res && res.ok) { window.location.href = '/login'; return; }
        say(region, (res && res.error) || 'Nothing was signed out.', true);
      });
    });
    document.addEventListener('lz-account-changed', render);
    render();
  }

  // --- bell (SM1034 phase 1b) ----------------------------------------------
  // A notice's link is followed only if it is a site path or http(s); anything
  // else (javascript:, data:) is shown as text and not linked.
  function safeHref(u) {
    if (typeof u !== 'string') return null;
    if (/^\/(?!\/)/.test(u)) return u;
    if (/^https?:\/\//i.test(u)) return u;
    return null;
  }

  function bell(region) {
    var list = q(region, '[data-ls-rows]');
    var empty = q(region, '[data-ls-empty]');
    var count = q(region, '[data-ls-field="unread"]');
    function render() {
      call('me-notices').then(function (r) {
        if (!r || !r.ok) { say(region, (r && r.error) || 'Your notices could not be read.', true); return; }
        while (list && list.firstChild) list.removeChild(list.firstChild);
        var rows = r.notices || [];
        if (empty) empty.hidden = rows.length > 0;
        if (count) count.textContent = r.unread ? (r.unread + ' unread') : '';
        rows.forEach(function (n) {
          var li = document.createElement('li');
          if (!n.read) li.className = 'lz-account-unread';
          var when = document.createElement('span');
          when.className = 'lz-account-when';
          when.textContent = (n.ts ? new Date(n.ts * 1000).toLocaleString() : '') + ' ';
          li.appendChild(when);
          var href = safeHref(n.url);
          var text = document.createElement(href ? 'a' : 'span');
          if (href) text.setAttribute('href', href);
          text.textContent = n.message || n.type || '';
          li.appendChild(text);
          [['Read', 0], ['Dismiss', 1]].forEach(function (b) {
            if (b[1] === 0 && n.read) return;
            var btn = document.createElement('button');
            btn.type = 'button';
            btn.textContent = b[0];
            btn.addEventListener('click', function () {
              post('me-notices-seen', { id: n.id, dismiss: b[1] }).then(function (res) {
                if (!(res && res.ok)) say(region, (res && res.error) || 'Nothing was marked.', true);
                render();
              });
            });
            li.appendChild(document.createTextNode(' '));
            li.appendChild(btn);
          });
          if (list) list.appendChild(li);
        });
      });
    }
    var all = q(region, '[data-ls-mark-all]');
    if (all) all.addEventListener('click', function () {
      post('me-notices-seen', {}).then(function (res) {
        if (!(res && res.ok)) say(region, (res && res.error) || 'Nothing was marked.', true);
        render();
      });
    });
    render();
  }

  // --- two-factor (SM1042, SM1034 phase 1c) -----------------------------------
  // The QR is computed by the bundled library and drawn from integers, as the
  // ::: qr component does: the otpauth URI is never inserted as markup.
  function drawQR(el, text) {
    function draw() {
      if (!window.qrcode) { el.textContent = '(QR unavailable - enter the key below in your app)'; return; }
      var qr = window.qrcode(0, 'M'); qr.addData(text); qr.make();
      var n = qr.getModuleCount(), cell = 4, m = 4, sz = (n + 2 * m) * cell;
      var NS = 'http://www.w3.org/2000/svg';
      var svg = document.createElementNS(NS, 'svg');
      svg.setAttribute('width', String(sz)); svg.setAttribute('height', String(sz));
      svg.setAttribute('viewBox', '0 0 ' + sz + ' ' + sz);
      var bg = document.createElementNS(NS, 'rect');
      bg.setAttribute('width', String(sz)); bg.setAttribute('height', String(sz)); bg.setAttribute('fill', '#fff');
      svg.appendChild(bg);
      for (var y = 0; y < n; y++) for (var x = 0; x < n; x++) {
        if (!qr.isDark(y, x)) continue;
        var r = document.createElementNS(NS, 'rect');
        r.setAttribute('x', String((x + m) * cell)); r.setAttribute('y', String((y + m) * cell));
        r.setAttribute('width', String(cell)); r.setAttribute('height', String(cell));
        svg.appendChild(r);
      }
      while (el.firstChild) el.removeChild(el.firstChild);
      el.appendChild(svg);
    }
    if (window.qrcode) { draw(); return; }
    var s = document.createElement('script');
    s.src = '/assets/qrcode.js';
    s.onload = draw;
    s.onerror = draw;
    document.head.appendChild(s);
  }

  function twofa(region) {
    var forms = {};
    qa(region, '[data-ls-2fa]').forEach(function (el) { forms[el.getAttribute('data-ls-2fa')] = el; });
    var state = q(region, '[data-ls-field="mfa-state"]');
    function show(which) {
      Object.keys(forms).forEach(function (k) {
        if (k === 'confirm') return;    // lives inside 'setup', shown with it
        forms[k].hidden = which.indexOf(k) < 0;
      });
    }
    function refresh() {
      me = null;
      loadMe().then(function (r) {
        if (!r || !r.ok) { say(region, (r && r.error) || 'Your account could not be read.', true); return; }
        if (r.mfa_enrolled) { if (state) state.textContent = 'Two-factor is on.'; show(['off']); }
        else if (r.mfa_pending) { if (state) state.textContent = 'Two-factor is being set up and is not on yet.'; show(['enrol', 'cancel']); }
        else { if (state) state.textContent = 'Two-factor is off.'; show(['enrol']); }
      });
    }
    function list(el, codes) {
      while (el.firstChild) el.removeChild(el.firstChild);
      (codes || []).forEach(function (c) { var li = document.createElement('li'); li.textContent = c; el.appendChild(li); });
    }
    if (forms.enrol) forms.enrol.addEventListener('submit', function (ev) {
      ev.preventDefault();
      post('me-2fa-enrol', { current_password: forms.enrol.elements.current_password.value }).then(function (res) {
        forms.enrol.reset();
        if (!(res && res.ok)) { say(region, (res && res.error) || 'Two-factor was not set up.', true); return; }
        var sec = q(region, '[data-ls-field="secret"]');
        if (sec) sec.textContent = res.secret || '';
        var codes = q(region, '[data-ls-codes]');
        if (codes) list(codes, res.recovery_codes);
        var qrel = q(region, '[data-ls-qr]');
        if (qrel && res.otpauth_uri) drawQR(qrel, res.otpauth_uri);
        qa(region, '[data-ls-setup-only]').forEach(function (e) { e.hidden = false; });
        show(['setup', 'cancel']);
        say(region, 'Scan the code, then enter the code your app shows.');
      });
    });
    var confirm = q(region, 'form[data-ls-2fa="confirm"]');
    if (confirm) confirm.addEventListener('submit', function (ev) {
      ev.preventDefault();
      post('me-2fa-confirm', { code: confirm.elements.code.value }).then(function (res) {
        if (!(res && res.ok)) { say(region, (res && res.error) || 'That code did not match.', true); return; }
        confirm.reset();
        say(region, res.message || 'Two-factor is on.');
        refresh();
      });
    });
    if (forms.cancel) forms.cancel.addEventListener('submit', function (ev) {
      ev.preventDefault();
      post('me-2fa-disable', { current_password: forms.cancel.elements.current_password.value }).then(function (res) {
        forms.cancel.reset();
        say(region, (res && (res.message || res.error)) || '', !(res && res.ok));
        refresh();
      });
    });
    if (forms.off) {
      var act = 'me-2fa-disable';
      qa(forms.off, '[data-ls-2fa-act]').forEach(function (b) {
        b.addEventListener('click', function () { act = b.getAttribute('data-ls-2fa-act'); });
      });
      forms.off.addEventListener('submit', function (ev) {
        ev.preventDefault();
        var body = { current_password: forms.off.elements.current_password.value, code: forms.off.elements.code.value };
        post(act, body).then(function (res) {
          forms.off.reset();
          if (!(res && res.ok)) { say(region, (res && res.error) || 'Nothing was changed.', true); return; }
          if (act === 'me-recovery-codes') {
            var setup = forms.setup, codes = q(region, '[data-ls-codes]');
            if (codes) list(codes, res.recovery_codes);
            if (setup) {
              setup.hidden = false;
              qa(setup, '[data-ls-setup-only]').forEach(function (e) { e.hidden = true; });
            }
            say(region, 'New recovery codes - store them now; the old ones no longer work.');
          } else {
            say(region, res.message || 'Two-factor is off.');
            refresh();
          }
        });
      });
    }
    refresh();
  }

  // --- passkeys (SM1352) ------------------------------------------------------
  // WebAuthn, the plain way: the browser makes or uses the key, and this sends
  // the server what it answered, as base64url. Enrolment takes the key from
  // getPublicKey() (SPKI) with attestation 'none'. Sign-in and the setup link
  // post a form, so the server's landing and refusals are the ordinary ones.
  var AUTH = '/cgi-bin/lazysite-auth.pl';
  function b64u(buf) {
    var b = new Uint8Array(buf), s = '';
    for (var i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
    return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  }
  function unb64u(str) {
    var s = atob(String(str || '').replace(/-/g, '+').replace(/_/g, '/'));
    var b = new Uint8Array(s.length);
    for (var i = 0; i < s.length; i++) b[i] = s.charCodeAt(i);
    return b.buffer;
  }
  function passkeysUsable() {
    return !!(window.PublicKeyCredential && navigator.credentials && navigator.credentials.create);
  }
  function authChallenge(fields) {
    var body = Object.keys(fields).map(function (k) { return encodeURIComponent(k) + '=' + encodeURIComponent(fields[k]); }).join('&');
    return fetch(AUTH + '?action=passkey-challenge', {
      method: 'POST', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'Accept': 'application/json' }, body: body
    }).then(function (r) { return r.json(); }, function () { return { ok: false, error: 'The server could not be reached.' }; });
  }
  function createOptions(c) {
    return { publicKey: {
      challenge: unb64u(c.challenge),
      rp: { id: c.rp_id, name: c.rp_name || c.rp_id },
      user: { id: unb64u(c.user_id), name: c.user_name, displayName: c.user_display || c.user_name },
      pubKeyCredParams: (c.algorithms || [-7]).map(function (a) { return { type: 'public-key', alg: a }; }),
      excludeCredentials: (c.exclude || []).map(function (id) { return { type: 'public-key', id: unb64u(id) }; }),
      authenticatorSelection: { residentKey: 'required', requireResidentKey: true, userVerification: 'preferred' },
      attestation: 'none', timeout: c.timeout || 300000
    } };
  }
  function created(cred) {
    var r = cred.response;
    if (!r.getPublicKey || !r.getAuthenticatorData || !r.getPublicKeyAlgorithm) return null;
    var pk = r.getPublicKey();
    if (!pk) return null;
    return { id: b64u(cred.rawId), client_data: b64u(r.clientDataJSON), authenticator_data: b64u(r.getAuthenticatorData()),
      public_key: b64u(pk), alg: r.getPublicKeyAlgorithm() };
  }
  function fillAndSend(form, fields) {
    Object.keys(fields).forEach(function (k) {
      var el = form.elements['pk_' + k];
      if (el) el.value = fields[k];
    });
    form.submit();
  }

  function passkeySignin(region) {
    if (!passkeysUsable()) return;
    region.hidden = false;
    var form = q(region, 'form[data-ls-passkey-form]'), go = q(region, '[data-ls-passkey-go]');
    if (!form || !go) return;
    go.addEventListener('click', function () {
      say(region, '');
      authChallenge({ purpose: 'signin' }).then(function (c) {
        if (!(c && c.ok)) { say(region, (c && c.error) || 'A passkey cannot be used here just now.', true); return null; }
        return navigator.credentials.get({ publicKey: {
          challenge: unb64u(c.challenge), rpId: c.rp_id, timeout: c.timeout || 300000, userVerification: 'preferred' } });
      }).then(function (cred) {
        if (!cred) return;
        var r = cred.response;
        fillAndSend(form, { id: b64u(cred.rawId), client_data: b64u(r.clientDataJSON),
          authenticator_data: b64u(r.authenticatorData), signature: b64u(r.signature) });
      }).catch(function () { say(region, 'No passkey was used. Try again, or sign in with your password.', true); });
    });
  }

  function passkeyClaim(region) {
    if (!passkeysUsable()) return;
    region.hidden = false;
    var form = q(region, 'form[data-ls-passkey-form]'), go = q(region, '[data-ls-passkey-go]');
    if (!form || !go) return;
    go.addEventListener('click', function () {
      say(region, '');
      authChallenge({ purpose: 'claim', username: form.elements.username.value }).then(function (c) {
        if (!(c && c.ok)) { say(region, (c && c.error) || 'A passkey cannot be added here just now.', true); return null; }
        return navigator.credentials.create(createOptions(c));
      }).then(function (cred) {
        if (!cred) return;
        var f = created(cred);
        if (!f) { say(region, 'This browser cannot add a passkey this way. Set a password instead.', true); return; }
        fillAndSend(form, f);
      }).catch(function () { say(region, 'No passkey was made. Try again, or set a password.', true); });
    });
  }

  function passkeys(region) {
    var state = q(region, '[data-ls-field="passkey-state"]'), ul = q(region, '[data-ls-passkeys]');
    var add = q(region, 'form[data-ls-passkey="add"]'), pwrow = q(region, '[data-ls-passkey-password]');
    function refresh() {
      call('me-passkeys').then(function (r) {
        if (!r || !r.ok) { say(region, (r && r.error) || 'Your passkeys could not be read.', true); return; }
        if (!r.available) { if (state) state.textContent = r.needs || 'Passkeys are not available on this site.'; if (add) add.hidden = true; return; }
        var n = (r.passkeys || []).length;
        if (state) state.textContent = n ? 'You have ' + n + ' passkey' + (n === 1 ? '' : 's') + '.' : 'You have no passkeys.';
        if (ul) {
          while (ul.firstChild) ul.removeChild(ul.firstChild);
          (r.passkeys || []).forEach(function (p) {
            var li = document.createElement('li');
            li.textContent = (p.label || 'Passkey') + ' - added ' + when(p.created) + (p.used ? ', last used ' + when(p.used) : '') + ' ';
            var b = document.createElement('button');
            b.type = 'button';
            b.textContent = 'Remove this passkey';
            b.addEventListener('click', function () {
              post('me-passkey-remove', { id: p.id }).then(function (res) {
                say(region, (res && (res.message || res.error)) || '', !(res && res.ok));
                refresh();
              });
            });
            li.appendChild(b);
            ul.appendChild(li);
          });
        }
        if (pwrow) pwrow.hidden = !r.has_password;
        if (add) add.hidden = !passkeysUsable();
        if (!passkeysUsable()) say(region, 'This browser cannot make a passkey.');
      });
    }
    if (add) add.addEventListener('submit', function (ev) {
      ev.preventDefault();
      var label = add.elements.label.value;
      post('me-passkey-begin', { current_password: add.elements.current_password.value }).then(function (c) {
        add.elements.current_password.value = '';
        if (!(c && c.ok)) { say(region, (c && c.error) || 'A passkey cannot be added just now.', true); return null; }
        return navigator.credentials.create(createOptions(c));
      }).then(function (cred) {
        if (!cred) return null;
        var f = created(cred);
        if (!f) { say(region, 'This browser cannot add a passkey this way.', true); return null; }
        f.label = label;
        return post('me-passkey-add', f);
      }).then(function (res) {
        if (!res) return;
        say(region, (res.message || res.error) || '', !res.ok);
        if (res.ok) add.reset();
        refresh();
      }).catch(function () { say(region, 'No passkey was made.', true); });
    });
    refresh();
  }

  // --- app notices on this device (SM1363) -------------------------------------
  // The browser subscribes through the site's app worker with the site's public
  // key, and the endpoint it hands back is all the server keeps: a notice comes
  // with no content, and the worker opens this page when it is tapped.
  function push(region) {
    var state = q(region, '[data-ls-field="push-state"]');
    var on = q(region, '[data-ls-push="on"]'), off = q(region, '[data-ls-push="off"]');
    var key = null;
    function show(text, which) {
      if (state) state.textContent = text;
      if (on) on.hidden = which !== 'on';
      if (off) off.hidden = which !== 'off';
    }
    function reg() {
      if (!('serviceWorker' in navigator) || !('PushManager' in window)) return Promise.resolve(null);
      return navigator.serviceWorker.getRegistration().then(function (g) { return g || null; }, function () { return null; });
    }
    function refresh() {
      call('me-push').then(function (r) {
        if (!r || !r.ok) { say(region, (r && r.error) || 'Your devices could not be read.', true); return; }
        if (!r.available) { show(r.needs || 'App notices are not available on this site.', ''); return; }
        key = r.key;
        reg().then(function (g) {
          if (!g) { show('Open this page from the site\'s installed app to get notices on this device.', ''); return; }
          g.pushManager.getSubscription().then(function (sub) {
            var mine = !!sub && (r.devices || []).indexOf(sub.endpoint) >= 0;
            show(mine ? 'Notices are on for this device.' : 'Notices are off for this device.', mine ? 'off' : 'on');
          });
        });
      });
    }
    if (on) on.addEventListener('click', function () {
      reg().then(function (g) {
        if (!g || !key) return null;
        return g.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: unb64u(key) });
      }).then(function (sub) {
        if (!sub) return null;
        return post('me-push-subscribe', { endpoint: sub.endpoint });
      }).then(function (res) {
        if (res) say(region, res.message || res.error || '', !res.ok);
        refresh();
      }).catch(function () { say(region, 'Notices were not turned on. The browser may have been told not to allow them.', true); });
    });
    if (off) off.addEventListener('click', function () {
      reg().then(function (g) { return g ? g.pushManager.getSubscription() : null; }).then(function (sub) {
        if (!sub) return null;
        return post('me-push-unsubscribe', { endpoint: sub.endpoint }).then(function (res) {
          return sub.unsubscribe().then(function () { return res; }, function () { return res; });
        });
      }).then(function (res) {
        if (res) say(region, res.message || res.error || '', !res.ok);
        refresh();
      });
    });
    refresh();
  }

  var BIND = { summary: summary, password: password, sessions: sessions, bell: bell, '2fa': twofa,
    passkeys: passkeys, 'passkey-signin': passkeySignin, 'passkey-claim': passkeyClaim, push: push };
  window.lzAccountBind = BIND;    // phase 1b and 1c add their regions here

  function start() {
    qa(document, '[data-ls-account]').forEach(function (region) {
      var f = BIND[region.getAttribute('data-ls-account')];
      if (f && !region.hasAttribute('data-ls-bound')) {
        region.setAttribute('data-ls-bound', '1');
        f(region);
      }
    });
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();
