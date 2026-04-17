---
title: Search
subtitle: Search this site.
query_params:
  - q
---

<div id="search-container">
  <form id="search-form" onsubmit="return false">
    <input type="search"
           id="search-input"
           placeholder="Search..."
           autocomplete="off"
           value="[% query.q | html %]"
           aria-label="Search query">
    <button type="submit" onclick="runSearch()">Search</button>
  </form>

  <div id="search-status"></div>
  <div id="search-results"></div>
</div>

<script>
(function() {
  // --- Configuration ---
  var INDEX_URL   = '/search-index';
  var MAX_RESULTS = 20;
  var EXCERPT_LEN = 200;

  // --- State ---
  var index = null;

  // --- Markdown stripping ---
  function stripMarkdown(text) {
    return text
      .replace(/^---[\s\S]*?---\n?/, '')
      .replace(/^#+\s+/gm, '')
      .replace(/\*\*(.+?)\*\*/g, '$1')
      .replace(/\*(.+?)\*/g, '$1')
      .replace(/`{1,3}[^`\n]*`{1,3}/g, '')
      .replace(/^```[\s\S]*?```$/gm, '')
      .replace(/^:::[^\n]*/gm, '')
      .replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
      .replace(/!\[[^\]]*\]\([^)]+\)/g, '')
      .replace(/\s+/g, ' ')
      .trim();
  }

  // --- Highlighting ---
  function highlight(text, terms) {
    var escaped = terms.map(function(t) {
      return t.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    });
    var re = new RegExp('(' + escaped.join('|') + ')', 'gi');
    return text.replace(re, '<mark>$1</mark>');
  }

  // --- Scoring ---
  function score(page, terms) {
    var s = 0;
    var title    = (page.title    || '').toLowerCase();
    var subtitle = (page.subtitle || '').toLowerCase();
    var body     = stripMarkdown(page.excerpt || '').toLowerCase();
    var tags     = (page.tags     || []).join(' ').toLowerCase();

    for (var i = 0; i < terms.length; i++) {
      var t = terms[i].toLowerCase();
      if (title.indexOf(t) !== -1)    s += 10;
      if (subtitle.indexOf(t) !== -1) s += 5;
      if (tags.indexOf(t) !== -1)     s += 4;
      var headings = (page.excerpt || '')
        .split('\n')
        .filter(function(l) { return /^#+\s/.test(l); })
        .join(' ')
        .toLowerCase();
      if (headings.indexOf(t) !== -1) s += 3;
      if (body.indexOf(t) !== -1)     s += 1;
    }
    return s;
  }

  // --- Excerpt extraction ---
  function getExcerpt(page, terms) {
    var body = stripMarkdown(page.excerpt || '');
    if (!body) return '';

    var lower = body.toLowerCase();
    for (var i = 0; i < terms.length; i++) {
      var idx = lower.indexOf(terms[i].toLowerCase());
      if (idx !== -1) {
        var start = Math.max(0, idx - 60);
        var end   = Math.min(body.length, idx + EXCERPT_LEN);
        var excerpt = body.slice(start, end);
        if (start > 0) excerpt = '...' + excerpt;
        if (end < body.length) excerpt += '...';
        return excerpt;
      }
    }

    return body.slice(0, EXCERPT_LEN) +
      (body.length > EXCERPT_LEN ? '...' : '');
  }

  // --- Render results ---
  function renderResults(results, terms, query) {
    var container = document.getElementById('search-results');
    var status    = document.getElementById('search-status');

    if (!results.length) {
      status.textContent = 'No results for "' + query + '".';
      container.innerHTML = '';
      return;
    }

    status.textContent = results.length + ' result' +
      (results.length === 1 ? '' : 's') + ' for "' + query + '"';

    container.innerHTML = results.map(function(r) {
      var excerpt = getExcerpt(r.page, terms);
      var title   = highlight(r.page.title || r.page.url, terms);
      var exh     = highlight(excerpt, terms);
      var tags    = (r.page.tags || [])
        .map(function(t) { return '<span class="search-tag">' + t + '</span>'; })
        .join(' ');

      return '<article class="search-result">' +
        '<h2><a href="' + r.page.url + '">' + title + '</a></h2>' +
        (r.page.subtitle
          ? '<p class="search-subtitle">' + r.page.subtitle + '</p>'
          : '') +
        (exh ? '<p class="search-excerpt">' + exh + '</p>' : '') +
        (tags ? '<p class="search-tags">' + tags + '</p>' : '') +
        (r.page.date
          ? '<time class="search-date">' + r.page.date + '</time>'
          : '') +
        '</article>';
    }).join('');
  }

  // --- Main search ---
  function runSearch() {
    var input = document.getElementById('search-input');
    var query = (input ? input.value : '').trim();
    var status = document.getElementById('search-status');

    if (!query) {
      status.textContent = '';
      document.getElementById('search-results').innerHTML = '';
      return;
    }

    var terms = query.split(/\s+/).filter(Boolean);

    function doSearch() {
      var scored = index
        .map(function(page) {
          return { page: page, score: score(page, terms) };
        })
        .filter(function(r) { return r.score > 0; })
        .sort(function(a, b) { return b.score - a.score; })
        .slice(0, MAX_RESULTS);

      renderResults(scored, terms, query);
    }

    if (index) {
      doSearch();
      return;
    }

    status.textContent = 'Loading index...';

    fetch(INDEX_URL)
      .then(function(r) { return r.json(); })
      .then(function(data) {
        index = data;
        doSearch();
      })
      .catch(function() {
        status.textContent = 'Search unavailable.';
      });
  }

  // Run search on page load if query param present
  document.addEventListener('DOMContentLoaded', function() {
    var q = '[% query.q | html %]';
    if (q) {
      var input = document.getElementById('search-input');
      if (input) input.value = q;
      runSearch();
    }

    var form = document.getElementById('search-form');
    if (form) {
      form.addEventListener('submit', function(e) {
        e.preventDefault();
        runSearch();
      });
    }
  });

  window.runSearch = runSearch;
})();
</script>

<style>
.search-result {
    border-bottom: 1px solid #eee;
    padding: 1rem 0;
    margin-bottom: 0.5rem;
}
.search-result h2 { font-size: 1.1rem; margin: 0 0 0.3rem; }
.search-result h2 a { text-decoration: none; }
.search-result h2 a:hover { text-decoration: underline; }
.search-subtitle { color: #666; margin: 0.2rem 0; font-size: 0.95rem; }
.search-excerpt { margin: 0.4rem 0; font-size: 0.9rem; line-height: 1.5; }
.search-tags { margin: 0.3rem 0; }
.search-tag {
    display: inline-block;
    background: #f0f0f0;
    border-radius: 3px;
    padding: 0.1rem 0.4rem;
    font-size: 0.8rem;
    margin-right: 0.3rem;
}
.search-date { color: #888; font-size: 0.8rem; }
mark { background: #fff3cd; padding: 0.1em 0; }
#search-status { color: #666; margin: 0.5rem 0; font-size: 0.9rem; }
#search-form { display: flex; gap: 0.5rem; margin-bottom: 1rem; }
#search-input {
    flex: 1;
    padding: 0.5rem;
    font-size: 1rem;
    border: 1px solid #ccc;
    border-radius: 3px;
}
</style>
