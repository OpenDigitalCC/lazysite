/* lazysite engine chrome - SM352.
 *
 * Three behaviours that were inline <script> blocks in the engine's own
 * output. They are here because a Content-Security-Policy worth setting cannot
 * coexist with the engine inlining script on every page - t/lint/56 holds the
 * inventory, and this file is three more entries leaving it.
 *
 * BUNDLED, and self-contained by design. Each behaviour looks for its own
 * elements and does nothing when they are absent, so ONE reference covers all
 * three wherever any of them is needed. That is what makes bundling honest
 * rather than merely convenient: a page loading this for the admin bar is not
 * running auth-sync code against elements that are not there, it is running a
 * loop over an empty NodeList.
 *
 * DEFERRED, so it never blocks the render. Every behaviour here adjusts an
 * element that is already on the page - none of them writes content - so
 * running after parse costs nothing and removes the parser stall an inline
 * script in <head> imposes.
 */
(function () {
  'use strict';

  /* SM: the site bar and its rule are chrome, not content. A page framed by
   * something else should show the content and not lazysite's furniture. */
  function hideChromeInFrame() {
    if (window === window.top) { return; }
    ['site-bar', 'site-rule', 'ls-admin-bar'].forEach(function (id) {
      var el = document.getElementById(id);
      if (el) { el.style.display = 'none'; }
    });
  }

  /* SM099: reveal the correct auth control from the lzs_session marker cookie.
   * DISPLAY ONLY - the signed HttpOnly cookie is still the gate, and this
   * cannot grant anything. It exists so a cached page shows the right control
   * to the visitor holding it. */
  function syncAuthControls() {
    var signedIn = /(?:^|;\s*)lzs_session=1(?:;|$)/.test(document.cookie);
    var show = document.querySelectorAll('[data-ls-auth-out]');
    var hide = document.querySelectorAll('[data-ls-auth-in]');
    var k;
    for (k = 0; k < show.length; k++) { show[k].style.display = signedIn ? '' : 'none'; }
    for (k = 0; k < hide.length; k++) { hide[k].style.display = signedIn ? 'none' : ''; }
  }

  function start() {
    hideChromeInFrame();
    syncAuthControls();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }
})();
