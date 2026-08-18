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

  /* SM098 / SM352: native form submission, for EVERY form on the page.
   *
   * This was an inline script per form, interpolating the form's name to
   * select it. It never needed to: `data-form` is already on the element, so
   * iterating `.lazysite-form` does the same job for one form or five, and the
   * name stops being a reason to generate code. That is what let this join the
   * bundle rather than needing a nonce or a hash.
   *
   * The behaviour is unchanged - post via fetch, disable the button, replace
   * the form with the success message, restore the button on failure. */
  function bindFormSubmit(form) {
    form.addEventListener('submit', function (e) {
      e.preventDefault();
      var btn = form.querySelector('button[type=submit]');
      var status = form.querySelector('.form-status');
      if (btn) { btn.disabled = true; }
      if (status) { status.textContent = 'Sending...'; }
      fetch(form.action, { method: 'POST', body: new FormData(form) })
        .then(function (r) {
          if (!r.ok) { throw new Error('Server returned ' + r.status); }
          return r.json();
        })
        .then(function (data) {
          if (data.ok) {
            form.innerHTML = '<p class="form-success">'
              + (data.message || 'Thank you - message sent.') + '</p>';
          } else {
            if (status) { status.textContent = data.error || 'An error occurred.'; }
            if (btn) { btn.disabled = false; }
          }
        })
        .catch(function (err) {
          if (status) { status.textContent = 'Could not send: ' + err.message; }
          if (btn) { btn.disabled = false; }
        });
    });
  }

  /* SM098: multi-step navigation. The `lsf-js` class is added HERE and not in
   * the markup, which is the progressive enhancement: without this script
   * running, every step shows and the nav is hidden, so a visitor with no
   * JavaScript gets one long usable form rather than a dead one. */
  function bindMultiStep(form) {
    form.classList.add('lsf-js');
    var steps = Array.prototype.slice.call(form.querySelectorAll('.lsf-step'));
    if (!steps.length) { return; }
    var back = form.querySelector('.lsf-back');
    var next = form.querySelector('.lsf-next');
    var cur = form.querySelector('.lsf-cur');
    var i = 0;

    function show(n) {
      i = Math.max(0, Math.min(steps.length - 1, n));
      for (var k = 0; k < steps.length; k++) {
        steps[k].classList.toggle('lsf-active', k === i);
      }
      if (cur) { cur.textContent = (i + 1); }
      if (back) { back.style.display = (i === 0) ? 'none' : ''; }
      if (next) { next.style.display = (i === steps.length - 1) ? 'none' : ''; }
    }

    function stepValid() {
      var els = steps[i].querySelectorAll('input, select, textarea');
      for (var k = 0; k < els.length; k++) {
        if (!els[k].checkValidity()) { els[k].reportValidity(); return false; }
      }
      return true;
    }

    if (next) {
      next.addEventListener('click', function () { if (stepValid()) { show(i + 1); } });
    }
    if (back) {
      back.addEventListener('click', function () { show(i - 1); });
    }
    show(0);
  }

  function bindForms() {
    var forms = document.querySelectorAll('.lazysite-form');
    for (var k = 0; k < forms.length; k++) {
      bindFormSubmit(forms[k]);
      if (forms[k].hasAttribute('data-multistep')) { bindMultiStep(forms[k]); }
    }
  }

  function start() {
    hideChromeInFrame();
    syncAuthControls();
    bindForms();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }
})();
