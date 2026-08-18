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

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', showVersion);
  } else {
    showVersion();
  }
})();
