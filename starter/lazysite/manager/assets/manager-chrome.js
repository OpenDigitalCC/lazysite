/* lazysite manager chrome - SM352.
 *
 * The version footer, which was an inline <script> at the bottom of every
 * manager page. It is here because a Content-Security-Policy worth setting
 * cannot coexist with inlining script on every response - t/lint/56 holds the
 * inventory and this is one more entry leaving it.
 *
* Lives beside manager.css in starter/lazysite/manager/assets/, which is the
 * one source directory the manifest maps to the served /manager/assets/. The
 * first version of this file went in starter/manager/assets/ and installed to
 * the same URL from a second source - which works, and is the shape this
 * project removes on sight.
 *
 * Deliberately NOT the manager's head script, which is a different problem and
 * is recorded as such in that inventory: 349 lines carrying four per-user
 * values, a nav built from plugin conditionals, a theme prelude that must run
 * before first paint, and a fetch wrapper that must replace window.fetch
 * before anything captures a reference to it. Two of those are ordering
 * constraints an external file cannot satisfy without a round trip in front of
 * the render.
 */
(function () {
  'use strict';

  function showVersion() {
    var el = document.getElementById('mg-version');
    if (!el) { return; }
    fetch('/cgi-bin/lazysite-manager-api.pl?action=version')
      .then(function (r) { return r.json(); })
      .then(function (d) {
        if (d && d.version) { el.textContent = 'lazysite v' + d.version; }
      })
      .catch(function () {});
  }

  /* SM724: the START PAGE - where a sign-in with no destination lands.
   *
   * One control, rendered into any container, for any account the caller may
   * set: the account sheet on every manager page (one's own), and the Users
   * page's editor sheet (another's, with manage_users). The choices come from
   * the API, computed from the TARGET account's grants - never from what this
   * page happens to show its viewer.
   */
  var API = '/cgi-bin/lazysite-manager-api.pl';

  function esc(s) {
    return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) {
      return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c];
    });
  }

  function mgStartPageControl(container, username) {
    if (!container) { return; }
    var q = API + '?action=start-page' + (username ? '&username=' + encodeURIComponent(username) : '');
    container.innerHTML = '<span class="mg-status">Loading&hellip;</span>';
    fetch(q, { credentials: 'same-origin' })
      .then(function (r) { return r.json(); })
      .then(function (d) {
        if (!d || !d.ok) { container.innerHTML = '<span class="mg-status">' + esc(d && d.error || 'Could not load the start page.') + '</span>'; return; }
        var cur = d.current || '';
        var kind = cur.indexOf('domain:') === 0 ? 'domain' : (cur ? 'manager' : '');
        var curHost = '', curPath = '/';
        if (kind === 'domain') {
          var rest = cur.slice(7), bar = rest.indexOf('|');
          curHost = bar < 0 ? rest : rest.slice(0, bar);
          curPath = bar < 0 ? '/' : (rest.slice(bar + 1) || '/');
        }
        var h = '<select class="mg-inp" data-role="start-select">';
        h += '<option value=""' + (kind ? '' : ' selected') + '>Default: the manager, with your account open</option>';
        if (d.choices && d.choices.pages && d.choices.pages.length) {
          h += '<optgroup label="Manager pages">';
          d.choices.pages.forEach(function (p) {
            h += '<option value="' + esc(p.value) + '"' + (p.value === cur ? ' selected' : '') + '>' + esc(p.label) + '</option>';
          });
          h += '</optgroup>';
        }
        if (d.choices && d.choices.domains && d.choices.domains.length) {
          h += '<optgroup label="A page on a site">';
          d.choices.domains.forEach(function (dm) {
            var v = 'domain:' + dm.host;
            h += '<option value="' + esc(v) + '"' + (kind === 'domain' && dm.host === curHost ? ' selected' : '') + '>' + esc(dm.label) + '</option>';
          });
          h += '</optgroup>';
        }
        h += '</select> ';
        h += '<input type="text" class="mg-inp" data-role="start-path" value="' + esc(curPath) + '" placeholder="/ (the page path on that site)"' + (kind === 'domain' ? '' : ' hidden') + '> ';
        h += '<button type="button" class="mg-btn mg-btn-sm" data-impact="commit" data-role="start-save">Save start page</button> ';
        h += '<span class="mg-status" data-role="start-msg"></span>';
        if (d.unreachable) {
          h += '<div class="mg-note mg-note-warn">The saved start page cannot be reached any more: ' + esc(d.unreachable) + '. Sign-in lands on the default until it is changed.</div>';
        }
        container.innerHTML = h;
        var sel = container.querySelector('[data-role=start-select]');
        var path = container.querySelector('[data-role=start-path]');
        var msg = container.querySelector('[data-role=start-msg]');
        sel.addEventListener('change', function () { path.hidden = sel.value.indexOf('domain:') !== 0; });
        container.querySelector('[data-role=start-save]').addEventListener('click', function () {
          var v = sel.value;
          if (v.indexOf('domain:') === 0) { v = v + '|' + (path.value || '/'); }
          var body = { value: v };
          if (username) { body.username = username; }
          msg.textContent = 'Saving…';
          fetch(API + '?action=start-page-set', { method: 'POST', credentials: 'same-origin',
            headers: { 'Content-Type': 'application/json' },   // the layout's fetch wrapper adds X-CSRF-Token
            body: JSON.stringify(body) })
            .then(function (r) { return r.json(); })
            .then(function (r) { msg.textContent = r && r.ok ? 'Saved. It applies at the next sign-in.' : (r && r.error || 'Failed.'); })
            .catch(function (e) { msg.textContent = 'Error: ' + e.message; });
        });
      })
      .catch(function (e) { container.innerHTML = '<span class="mg-status">Error: ' + esc(e.message) + '</span>'; });
  }
  window.mgStartPageControl = mgStartPageControl;

  /* The account sheet: the signed-in user's own settings, on every manager
   * page. Opened by clicking the name in the header, or by arriving with
   * ?account=1 - which is where a sign-in with no destination lands (the
   * fallback), with &start=unreachable when a chosen start page could not be
   * honoured, so the person is told why they are here. */
  function mgOpenAccount() {
    var sheet = document.getElementById('mg-account-sheet');
    if (!sheet) { return; }
    sheet.hidden = false;
    document.body.classList.add('mg-sheet-open');
    var body = document.getElementById('mg-account-body');
    var notice = /[?&]start=unreachable\b/.test(location.search)
      ? '<div class="mg-note mg-note-warn">Your start page could not be reached, so you have landed here instead. Choose another below.</div>' : '';
    body.innerHTML = notice + '<div class="mg-box"><div class="mg-sec">Start page</div>' +
      '<p class="mg-card-subtitle">Where you land when you sign in without a destination. A link you followed to sign in still wins.</p>' +
      '<div id="mg-start-page"></div></div>';
    mgStartPageControl(document.getElementById('mg-start-page'), '');
  }
  function mgCloseAccount() {
    var sheet = document.getElementById('mg-account-sheet');
    if (!sheet) { return; }
    sheet.hidden = true;
    document.body.classList.remove('mg-sheet-open');
  }
  window.mgOpenAccount = mgOpenAccount;
  window.mgCloseAccount = mgCloseAccount;

  function boot() {
    showVersion();
    if (/[?&]account=1\b/.test(location.search)) { mgOpenAccount(); }
    document.addEventListener('keydown', function (e) { if (e.key === 'Escape') { mgCloseAccount(); } });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
