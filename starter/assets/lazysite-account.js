/* lazysite-account.js - SM1043 (SM1034 phase 1a): the member's own account page.
 *
 * Binds the built-in ::: account-* components on /account to the control API's
 * me-* actions. Every one of those acts on the signed-in caller and nobody else:
 * this script never sends an account name, because the server would not read
 * one. It sends the session cookie (same origin) and the CSRF token the
 * `csrf-token` action mints for that session, on every POST.
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

  var BIND = { summary: summary, password: password, sessions: sessions };
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
