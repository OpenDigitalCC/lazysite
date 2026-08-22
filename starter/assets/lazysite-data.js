/* lazysite-data.js - DP-3b: the helper a page's own markup uses to read a
 * table after render.
 *
 * WHY A SHIPPED HELPER AND NOT AN EXAMPLE IN THE DOCS. Every site that binds a
 * table live would otherwise write its own fetch-and-render, and each one would
 * get the same three things wrong: it would not escape what it inserts, it
 * would replace good content with an empty list when the request fails, and it
 * would fetch on page load whether or not the region is on screen. Those are
 * not exotic mistakes - they are what a reasonable person writes first.
 *
 * NO DEPENDENCIES, NO CDN, NO BUILD. Vendored into the site's assets like every
 * other shipped file, per the standing rule that a lazysite serves everything
 * it needs from its own origin.
 *
 * WHAT IT DOES NOT DO: it does not decide what a visitor may see. The endpoint
 * does that, from the session cookie, and a table that is not published answers
 * this script exactly as it answers anyone else - with nothing, and no hint
 * that the table exists.
 *
 * THE MARKUP CONTRACT. A region declares the binding; a <template> inside it
 * says what one row looks like:
 *
 *   <div data-ls-db="products" data-ls-db-order="-price" data-ls-db-limit="10">
 *     <template>
 *       <li class="product"><span data-ls-field="name"></span>
 *           <em data-ls-field="price"></em></li>
 *     </template>
 *     <p data-ls-empty>Nothing to show yet.</p>
 *   </div>
 *
 * VALUES GO IN AS TEXT, ALWAYS, via textContent on the element that names the
 * field. There is no interpolation into markup anywhere in this file, so a row
 * containing a script tag is a row containing a script tag - it renders as
 * those characters and does nothing. That is the single most important
 * property here: the rows come from a store that a form may write, so treating
 * them as markup would turn a contact form into a way to run script on every
 * visitor's page.
 */
(function () {
  'use strict';

  var ENDPOINT = '/cgi-bin/lazysite-data.pl';

  function qs(el) {
    var p = ['table=' + encodeURIComponent(el.getAttribute('data-ls-db'))];
    var map = { order: 'order_by', dir: 'order', limit: 'limit', offset: 'offset' };
    Object.keys(map).forEach(function (k) {
      var v = el.getAttribute('data-ls-db-' + k);
      if (v === null || v === '') return;
      /* `-field` is the descending spelling everywhere else in lazysite, so it
       * is the spelling here too rather than a second convention. */
      if (k === 'order' && v.charAt(0) === '-') {
        p.push('order_by=' + encodeURIComponent(v.slice(1)));
        p.push('order=desc');
        return;
      }
      p.push(map[k] + '=' + encodeURIComponent(v));
    });
    return ENDPOINT + '?' + p.join('&');
  }

  function fill(node, row) {
    var slots = node.querySelectorAll('[data-ls-field]');
    for (var i = 0; i < slots.length; i++) {
      var name = slots[i].getAttribute('data-ls-field');
      var v = row[name];
      /* null and the empty string are different things in the store and stay
       * different here: an absent value leaves whatever the template had, an
       * empty one blanks it. Collapsing them would make "not recorded" and
       * "recorded as nothing" look the same on the page. */
      if (v === undefined) continue;
      slots[i].textContent = v === null ? '' : String(v);
    }
    return node;
  }

  function render(el, rows) {
    var tpl = el.querySelector('template');
    if (!tpl) return;
    var empty = el.querySelector('[data-ls-empty]');

    var frag = document.createDocumentFragment();
    for (var i = 0; i < rows.length; i++) {
      frag.appendChild(fill(tpl.content.cloneNode(true), rows[i]));
    }

    /* Everything except the template and the empty-state is replaced. Removing
     * the template would make a second refresh render nothing at all, which is
     * the kind of bug that only shows up on the third minute of a live page. */
    var kill = [];
    for (var c = el.firstChild; c; c = c.nextSibling) {
      if (c === tpl || (empty && c === empty)) continue;
      kill.push(c);
    }
    kill.forEach(function (n) { el.removeChild(n); });

    el.insertBefore(frag, empty || null);
    if (empty) empty.hidden = rows.length > 0;
    el.setAttribute('data-ls-db-state', 'ready');
  }

  function load(el) {
    if (el.getAttribute('data-ls-db-state') === 'loading') return;
    el.setAttribute('data-ls-db-state', 'loading');

    var req = new XMLHttpRequest();
    req.open('GET', qs(el), true);
    req.setRequestHeader('Accept', 'application/json');
    req.onreadystatechange = function () {
      if (req.readyState !== 4) return;

      /* A FAILED REFRESH LEAVES WHAT IS ALREADY THERE. The page was rendered
       * with rows server-side (snapshot and live both do), and replacing good
       * content with an empty list because one request timed out is worse than
       * showing data a minute old - which is all a stale snapshot ever is. */
      if (req.status !== 200) {
        el.setAttribute('data-ls-db-state', 'stale');
        return;
      }
      var data;
      try { data = JSON.parse(req.responseText); } catch (e) {
        el.setAttribute('data-ls-db-state', 'stale');
        return;
      }
      if (!data || !data.ok || !data.rows) {
        el.setAttribute('data-ls-db-state', 'stale');
        return;
      }
      render(el, data.rows);
    };
    req.send();
  }

  /* ON VIEW, NOT ON LOAD. A table below the fold on a page nobody scrolls
   * should cost nothing. IntersectionObserver where it exists; everything else
   * loads immediately, which is the old behaviour and is correct, just less
   * frugal. */
  function watch(els) {
    if (!('IntersectionObserver' in window)) {
      els.forEach(load);
      return;
    }
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (!e.isIntersecting) return;
        io.unobserve(e.target);
        load(e.target);
      });
    }, { rootMargin: '200px' });
    els.forEach(function (el) { io.observe(el); });
  }

  function start() {
    var all = [].slice.call(document.querySelectorAll('[data-ls-db]'));
    if (!all.length) return;

    watch(all);

    /* `data-ls-db-every` is opt-in per region, in seconds. Nothing polls
     * unless an author asked it to: a page that refetches every few seconds
     * forever is a cost the visitor pays and the author never sees. */
    all.forEach(function (el) {
      var every = parseInt(el.getAttribute('data-ls-db-every'), 10);
      if (!every || every < 5) return;
      setInterval(function () {
        if (document.hidden) return;   /* a background tab is not watching */
        el.setAttribute('data-ls-db-state', 'ready');
        load(el);
      }, every * 1000);
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }
})();
