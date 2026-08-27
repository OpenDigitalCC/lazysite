---
title: Visitor statistics
auth: manager
search: false
---

<div id="status" class="mg-status"></div>

<div class="mg-card">
<div class="mg-card-header">
<span class="mg-card-title">Summary</span>
<button class="mg-btn mg-btn-sm" onclick="loadStats()">Refresh</button>
</div>
<div class="mg-card-body" id="stats-body">Loading&hellip;</div>
</div>

<div class="mg-card">
<div class="mg-card-header">
<span class="mg-card-title">Visitor journeys</span>
<button class="mg-btn mg-btn-sm" id="card-trails-toggle" aria-controls="trails-card-body"
        aria-expanded="false">Show</button>
</div>
<div class="mg-card-body" id="trails-card-body" hidden>
<div class="mg-line">
  <label for="trail-day">Day</label>
  <select id="trail-day" class="mg-inp" style="max-width:12rem"></select>
</div>
<div id="trails-body">Loading&hellip;</div>
</div>
</div>

<div class="mg-card">
<div class="mg-card-header">
<span class="mg-card-title">Blocked IPs (auto-blocker)</span>
<button class="mg-btn mg-btn-sm" id="card-blocked-toggle" aria-controls="blocked-body"
        aria-expanded="false">Show</button>
<button class="mg-btn mg-btn-sm" onclick="loadBlocked()">Refresh</button>
</div>
<div class="mg-card-body" id="blocked-body" hidden>Loading&hellip;</div>
</div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';
var statsScript = null;

function sesc(s) { var d = document.createElement('div'); d.textContent = (s == null ? '' : String(s)); return d.innerHTML; }
function showStatus(msg, isErr) {
  var s = document.getElementById('status');
  if (!s) return;
  s.textContent = msg;
  s.className = 'mg-status' + (isErr ? ' mg-status-error' : ' mg-status-ok');
}

function fmtBytes(b) {
  b = +b || 0;
  var u = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0;
  while (b >= 1024 && i < u.length - 1) { b /= 1024; i++; }
  return (i ? b.toFixed(1) : b) + ' ' + u[i];
}
function fmtNum(n) { return (+n || 0).toLocaleString(); }

// Find the stats plugin (must be enabled), then run its refresh action.
function loadStats() {
  var body = document.getElementById('stats-body');
  body.textContent = 'Scanning the access log…';
  fetch(API + '?action=plugin-list').then(function (r) { return r.json(); }).then(function (d) {
    if (!d.ok) { body.textContent = d.error || 'Failed to load plugins.'; return; }
    var p = (d.plugins || []).filter(function (x) { return x.id === 'stats'; })[0];
    if (!p) { body.innerHTML = 'The Visitor Stats plugin is not installed.'; return; }
    if (!p._enabled) {
      body.innerHTML = 'Enable the <b>Visitor Statistics</b> plugin on the '
        + '<a href="/manager/plugins">Plugin Manager</a> page, then set its access-log path on the '
        + '<a href="/manager/plugin-config">Plugin Config</a> page.';
      return;
    }
    statsScript = p._script;
    initTrails(p);   // SM399: the descriptor already carries the days; no second round trip
    fetch(API + '?action=plugin-action&plugin=stats', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ script: statsScript, action_id: 'refresh' })
    }).then(function (r) { return r.json(); }).then(renderStats)
      .catch(function (e) { body.textContent = 'Error: ' + e.message; });
  }).catch(function (e) { body.textContent = 'Error: ' + e.message; });
}

function renderStats(d) {
  var body = document.getElementById('stats-body');
  if (!d || !d.ok) {
    body.innerHTML = '<p class="mg-muted">' + sesc((d && d.error) || 'No stats available.') + '</p>'
      + '<p class="mg-muted">Visits are recorded automatically (the first-party access log); '
      + 'this message appears only when that is turned off on the '
      + '<a href="/manager/plugin-config">Plugin Config</a> page and the web-server log is not readable.</p>';
    return;
  }
  var h = '';
  // Headline = genuine human audience only.
  //
  // SM329: 'Page views' says what the number is. It used to count every image
  // and stylesheet on the page, so it fell sharply the day that was fixed - and
  // a headline number that drops without explanation reads as lost traffic. The
  // assets are shown beside it rather than dropped silently, so the subtraction
  // is visible on the page an operator actually reads.
  h += '<div class="mg-stat-tiles">'
     + tile('Page views', fmtNum(d.hits))
     + tile('Unique visitors' + (d.anonymised ? ' *' : ''), fmtNum(d.unique_visitors))
     + tile('Images and files', fmtNum(d.asset_hits || 0))
     + tile('Data served', fmtBytes(d.bytes))
     + tile('Window', d.window_days + ' days')
     + '</div>';

  // Traffic breakdown - separates people from AI / bots / noise / operator.
  if (d.classes) {
    var defs = [['human', 'People'], ['logged_in', 'Logged-in'], ['ai', 'AI assistants'],
                ['bot', 'Bots'], ['noise', 'Noise / probes']];
    // SM424: OPEN by default. This and Hits per day are the two an operator
    // opens the page for, so collapsing them by default would trade one
    // annoyance for another - the block exists so they CAN be shut, not so
    // that the answer starts hidden.
    var au = '<div class="mg-stat-tiles">';
    defs.forEach(function (p) {
      var c = d.classes[p[0]] || { hits: 0, visitors: 0 };
      au += '<div class="mg-stat-tile"><div class="mg-stat-value">' + fmtNum(c.hits) + '</div>'
          + '<div class="mg-stat-label">' + sesc(p[1])
          + ' <span class="mg-muted">(' + fmtNum(c.visitors) + ' IP' + (c.visitors === 1 ? '' : 's') + ')</span>'
          + '</div></div>';
    });
    au += '</div>';
    // Proportional split bar - a visual quick-read of the audience mix.
    var mix = [['human','#2e8b57'],['logged_in','#3a7bd5'],['ai','#8e44ad'],['bot','#d98a1f'],['noise','#b03a3a']];
    var mixTotal = mix.reduce(function (s, p) { return s + ((d.classes[p[0]] || {}).hits || 0); }, 0);
    if (mixTotal > 0) {
      au += '<div class="mg-split-bar" style="display:flex;height:14px;border-radius:7px;overflow:hidden;margin:0.4rem 0">';
      mix.forEach(function (p) {
        var hits = (d.classes[p[0]] || {}).hits || 0;
        if (hits <= 0) return;
        var pct = (hits / mixTotal * 100);
        var lbl = (defs.filter(function (x) { return x[0] === p[0]; })[0] || [p[0], p[0]])[1];
        au += '<span style="width:' + pct.toFixed(2) + '%;background:' + p[1] + '" '
            + 'title="' + sesc(lbl) + ': ' + fmtNum(hits) + ' (' + pct.toFixed(1) + '%)"></span>';
      });
      au += '</div>';
    }
    au += '<p class="mg-muted">Classified from the log alone (user-agent + path) - an estimate, not '
        + 'authenticated. &ldquo;Logged-in&rdquo; and &ldquo;AI&rdquo; are attributed per request, not per session.</p>';
    h += block( 'audience', 'Who\u2019s calling', au, 1 );
  }
  if (d.anonymised) h += '<p class="mg-muted">* visitor IPs are anonymised (last octet zeroed) before counting.</p>';

  // Per-day bar chart
  if (d.per_day && d.per_day.length) {
    var max = d.per_day.reduce(function (m, x) { return x.count > m ? x.count : m; }, 0) || 1;
    var pd = '<div class="mg-bars">';
    d.per_day.forEach(function (x) {
      var pct = Math.round(x.count / max * 100);
      pd += '<div class="mg-bar-row"><span class="mg-bar-label">' + sesc(x.day) + '</span>'
          + '<span class="mg-bar"><span class="mg-bar-fill" style="width:' + pct + '%"></span></span>'
          + '<span class="mg-bar-val">' + fmtNum(x.count) + '</span></div>';
    });
    h += block( 'perday', 'Hits per day', pd + '</div>', 1 );
  }

  // SM213: month-on-month trend (filled async from the durable stats index).
  // SM424: MONTH ON MONTH IS A SECOND ROUND TRIP. `analyse_visitors&index=1`
  // ran on every page load whether anyone looked at the deltas or not. It is
  // now a block like the rest, and blockLoaders fetches it the first time it
  // is opened.
  h += block( 'monthly', 'Month on month',
      '<div id="mom-block"><p class="mg-muted">Loading&hellip;</p></div>', 0 );

  h += block( 'pages', 'Top pages and referrers',
      '<div class="mg-stat-cols">'
    + pageTable('Top pages', d.top_pages)
    + refBlock(d.referrers)
    + '</div>', 1 );   // open by default: the one most operators come for

  // SM363: how people MOVED, which SM336 computed and nothing displayed.
  // `exit` is the most actionable field a content owner can have - it names
  // where the argument fails - and `depth` turns "60% bounced" into which page
  // they bounced off.
  if (d.journeys) {
    var j = d.journeys;
    var depthKeys = Object.keys(j.depth || {});
    if (d.sessions || depthKeys.length || (j.entry || []).length) {
      // SM424: ONE block for the whole subject rather than a bare heading
      // followed by a second collapsible. Depth, entry and exit answer the
      // same question - what a visit looked like - so an operator who does
      // not want that question does not want any of it.
      var vis = '<div class="mg-checks"><span class="mg-tag mg-tag-auto">visits: '
              + fmtNum(d.sessions) + '</span>';
      // A visit ends on thirty minutes of silence or a day change, so the ones
      // still open are not counted yet. Said here rather than left to look
      // like an undercount.
      depthKeys.sort().forEach(function (k) {
        vis += '<span class="mg-tag mg-tag-auto">' + sesc(k) + ' page(s): '
             + fmtNum(j.depth[k]) + '</span>';
      });
      vis += '</div><div class="mg-stat-cols">'
           + pageTable('Where visits started', j.entry)
           + pageTable('Where visits ended', j.exit)
           + '</div>';
      h += block( 'visits', 'Visits', vis, 0 );
    }
  }

  // SM363: devices, and - where the operator has switched it on - the search
  // terms visitors typed. Both were computed, stored per day and carried in
  // this payload while the page rendered neither, so an operator who enabled
  // search terms saw nothing happen and reasonably concluded it did not work.
  if (d.devices && Object.keys(d.devices).length) {
    var dev = '<div class="mg-checks">';
    Object.keys(d.devices).sort(function (a, b) { return d.devices[b] - d.devices[a]; })
      .forEach(function (k) {
        dev += '<span class="mg-tag mg-tag-auto">' + sesc(k) + ': ' + fmtNum(d.devices[k]) + '</span>';
      });
    h += block( 'devices', 'Devices', dev + '</div>', 0 );
  }

  // ABSENT, not empty, when the switch is off - an empty list reads as "nobody
  // searched" and the truth is "nobody was asked". So no block at all.
  //
  // sesc() on every term is load-bearing here and nowhere else on this page:
  // these are the visitor's own words, taken from a query string, and they are
  // the first field the manager renders whose content a stranger chooses. They
  // are NOT put in an href - a search term is not a URL.
  if (d.search_terms && d.search_terms.length) {
    var st = '<table class="mg-table"><thead><tr><th>Term</th><th>Searches</th></tr>'
           + '</thead><tbody>';
    d.search_terms.forEach(function (t) {
      st += '<tr><td style="word-break:break-all">' + sesc(t.key) + '</td><td>'
          + fmtNum(t.count) + '</td></tr>';
    });
    st += '</tbody></table>';
    st += '<p class="mg-muted">A term is only recorded once ' + fmtNum(3)
        + ' separate visits have used it, so a one-off is never stored.</p>';
    h += block( 'search', 'What visitors searched for', st, 0 );
  }

  // Status codes
  if (d.status) {
    var codes = Object.keys(d.status).sort();
    var sc = '<div class="mg-checks">';
    codes.forEach(function (c) { sc += '<span class="mg-tag mg-tag-auto">' + sesc(c) + ': ' + fmtNum(d.status[c]) + '</span>'; });
    h += block( 'status', 'Status codes', sc + '</div>', 0 );
  }

  // Recent server errors - synthesised categories + counts only (no raw lines,
  // addresses or paths).
  if (d.errors && d.errors.available) {
    var cats = d.errors.categories || [];
    var er = '';
    if (!cats.length) {
      er = '<p class="mg-muted">No recent errors.</p>';
    } else {
      er = '<div class="mg-checks">';
      cats.forEach(function (c) {
        er += '<span class="mg-tag mg-tag-auto">' + sesc(c.label) + ': ' + fmtNum(c.count) + '</span>';
      });
      er += '</div>';
    }
    h += block( 'errors', 'Recent server errors', er, 0 );
  }

  // Source - the disk path is never shown, and the raw log is never downloadable.
  h += '<p class="mg-muted" style="margin-top:1rem">' + fmtNum(d.scanned_lines)
     + ' log lines scanned' + (d.capped ? ' (capped)' : '') + '.</p>';
  body.innerHTML = h;
  bindBlocks();
}

// SM213: best-effort month-on-month indicator from the durable per-day store's
// index. Silent if the operator lacks the analytics capability or there is no
// data yet - the dashboard is an indicator, not a full analytics view.
function loadMonthly() {
  var el = document.getElementById('mom-block');
  if (!el) return;
  fetch(API + '?action=analyse_visitors&index=1')
    .then(function (r) { return r.json(); })
    .then(function (d) {
      if (!d || !d.ok || !d.months || !d.months.length) return;
      var m = d.months.slice(-12);
      var max = m.reduce(function (a, x) { return x.pageviews > a ? x.pageviews : a; }, 0) || 1;
      var h = '<div class="mg-sec">Month on month <span class="mg-muted">(people pageviews)</span></div>';
      if (d.data_from) h += '<p class="mg-muted" style="margin:0 0 0.4rem">Aggregates held since ' + sesc(d.data_from) + '.</p>';
      h += '<div class="mg-bars">';
      m.forEach(function (x) {
        var pct = Math.round((x.pageviews || 0) / max * 100);
        var delta = '';
        if (x.delta_pageviews != null) {
          var up = x.delta_pageviews >= 0;
          delta = ' <span style="color:' + (up ? '#2e8b57' : '#b03a3a') + '">'
                + (up ? '▲' : '▼') + ' ' + fmtNum(Math.abs(x.delta_pageviews)) + '</span>';
        }
        h += '<div class="mg-bar-row"><span class="mg-bar-label">' + sesc(x.month) + '</span>'
           + '<span class="mg-bar"><span class="mg-bar-fill" style="width:' + pct + '%"></span></span>'
           + '<span class="mg-bar-val">' + fmtNum(x.pageviews) + delta + '</span></div>';
      });
      h += '</div>';
      el.innerHTML = h;
    })
    .catch(function () { /* best-effort: leave the block empty */ });
}

function tile(label, value) {
  return '<div class="mg-stat-tile"><div class="mg-stat-value">' + sesc(value)
       + '</div><div class="mg-stat-label">' + sesc(label) + '</div></div>';
}
// SM424: ONE BLOCK AT A TIME. The operator's report was that this page renders
// every block at once, so somebody looking for one of them scrolls past all of
// them - and the page grows with each block added.
//
// <details> rather than a JS accordion: it is keyboard-operable and readable by
// a screen reader without anything written here, and a block that fails to
// render leaves the rest of the page intact rather than taking the accordion
// with it.
//
// The open set is remembered per viewer, because an operator who checks
// Referrers every morning should not reopen it every morning. localStorage can
// throw outright (a private window, site data blocked), so every read and write
// is guarded and the page renders correctly with no stored value at all.
// NEVER STORED means the default applies, which is not the same as SHUT - a
// first visit must show what the page is for. The distinction lives here so
// the blocks inside the report and the two whole cards below cannot disagree
// about it.
function blockOpen(key, openByDefault) {
  try {
    var v = localStorage.getItem('lzs-stats-' + key);
    return (v === null) ? !!openByDefault : (v === 'open');
  } catch (e) { return !!openByDefault; }
}
function statsToggle(key, isOpen) {
  try { localStorage.setItem('lzs-stats-' + key, isOpen ? 'open' : 'shut'); }
  catch (e) { /* nothing to remember with - the block still opens */ }
}
function block(key, title, inner, openByDefault) {
  var isOpen = blockOpen(key, openByDefault);
  // The key travels in data-block; the listener is bound by bindBlocks below.
  return '<details class="mg-stat-block" data-block="' + sesc(key) + '"'
       + (isOpen ? ' open' : '')
       + '><summary class="mg-sec">' + sesc(title) + '</summary>'
       + inner + '</details>';
}

// INLINE HANDLERS ARE THE MANAGER'S CSP DEBT - a nonce does not reach an
// attribute, so anything bound that way breaks the moment the policy is
// enforced. These blocks are rebuilt on every render, so the binding happens
// after the write rather than once at load.
// A block whose contents cost a request of their own. The report itself is one
// payload assembled from buckets the ingest has already parsed, so splitting
// THAT would multiply the ingest rather than divide it - but these are separate
// calls, and they should follow the operator rather than run regardless.
var blockLoaders = { monthly: loadMonthly };
var blockLoaded  = {};
function blockMaybeLoad(key, isOpen) {
  if (!isOpen || blockLoaded[key] || !blockLoaders[key]) return;
  blockLoaded[key] = 1;
  blockLoaders[key]();
}
function bindBlocks() {
  var els = document.querySelectorAll('details[data-block]');
  Array.prototype.forEach.call(els, function (el) {
    var key = el.getAttribute('data-block');
    el.addEventListener('toggle', function () {
      statsToggle(key, el.open);
      blockMaybeLoad(key, el.open);
    });
    // A block this viewer left open is open on arrival, and no toggle event
    // fires for that - so it would sit on "Loading..." for ever.
    blockMaybeLoad(key, el.open);
  });
}

function bindCard(key, bodyId, load) {
  var btn = document.getElementById(key + '-toggle');
  if (btn) {
    btn.addEventListener('click', function () { cardToggle(key, bodyId, load); });
  }
}

// SM424: the same rule for a WHOLE CARD. Trails and the blocked-address list
// are their own cards below the report, and an operator who came for hits per
// day scrolls past both. They collapse the same way and remember the same way,
// and the fetch is DEFERRED to the first open - a card nobody expands costs no
// request at all, which the previous unconditional loadBlocked() did on every
// page load whether anyone looked or not.
var cardLoaded = {};
function cardSet(key, bodyId, open, load) {
  var el = document.getElementById(bodyId);
  if (!el) return;
  var btn = document.getElementById(key + '-toggle');
  el.hidden = !open;
  if (btn) {
    btn.textContent = open ? 'Hide' : 'Show';
    btn.setAttribute('aria-expanded', open ? 'true' : 'false');
  }
  if (open && !cardLoaded[key]) { cardLoaded[key] = 1; load(); }
}
function cardToggle(key, bodyId, load) {
  var el = document.getElementById(bodyId);
  if (!el) return;
  var open = el.hidden;    // hidden now means this click opens it
  statsToggle(key, open);
  cardSet(key, bodyId, open, load);
}

function pageTable(title, rows) {
  var h = '<div class="mg-stat-col"><div class="mg-sec">' + sesc(title) + '</div>';
  if (!rows || !rows.length) { return h + '<p class="mg-muted">None.</p></div>'; }
  h += '<table class="mg-table"><thead><tr><th>Page</th><th>Hits</th></tr></thead><tbody>';
  rows.forEach(function (r) {
    h += '<tr><td style="word-break:break-all">'
       + '<a href="' + encodeURI(r.key) + '" target="_blank" rel="noopener">' + sesc(r.key) + '</a>'
       + '</td><td>' + fmtNum(r.count) + '</td></tr>';
  });
  return h + '</tbody></table></div>';
}
function refBlock(ref) {
  ref = ref || { external: [], internal: 0, direct: 0 };
  var h = '<div class="mg-stat-col"><div class="mg-sec">Referrers</div>';
  h += '<div class="mg-checks" style="margin-bottom:.5rem">'
     + '<span class="mg-tag mg-tag-auto">Direct: ' + fmtNum(ref.direct) + '</span>'
     + '<span class="mg-tag mg-tag-auto">Internal: ' + fmtNum(ref.internal) + '</span></div>';
  var ext = ref.external || [];
  if (!ext.length) { return h + '<p class="mg-muted">No external referrers.</p></div>'; }
  h += '<table class="mg-table"><thead><tr><th>External referrer</th><th>Hits</th></tr></thead><tbody>';
  ext.forEach(function (r) {
    h += '<tr><td style="word-break:break-all">' + sesc(r.key) + '</td><td>' + fmtNum(r.count) + '</td></tr>';
  });
  return h + '</tbody></table></div>';
}

// SM128: the bad-URL auto-blocker's current blocks, with per-IP unblock.
function loadBlocked() {
  var el = document.getElementById('blocked-body');
  fetch(API + '?action=bad-url-blocks').then(function (r) { return r.json(); }).then(function (d) {
    if (!d || !d.ok) { el.innerHTML = '<p class="mg-muted">' + sesc((d && d.error) || 'Unavailable.') + '</p>'; return; }
    var ips = Object.keys(d.blocks || {});
    if (!ips.length) { el.innerHTML = '<p class="mg-muted">No IPs are currently blocked.</p>'; return; }
    ips.sort(function (a, b) { return (d.blocks[b].since || 0) - (d.blocks[a].since || 0); });
    var h = '<table class="mg-table"><thead><tr><th>IP</th><th>Probes</th><th>Since</th><th></th></tr></thead><tbody>';
    ips.forEach(function (ip) {
      var b = d.blocks[ip];
      var since = b.since ? new Date(b.since * 1000).toLocaleString() : '';
      h += '<tr><td><code>' + sesc(ip) + '</code></td><td>' + fmtNum(b.count)
         + '</td><td>' + sesc(since) + '</td><td>'
         + '<button class="mg-btn mg-btn-sm" onclick="unblockIp(\'' + sesc(ip).replace(/'/g, '') + '\')">Unblock</button>'
         + '</td></tr>';
    });
    el.innerHTML = h + '</tbody></table>';
  }).catch(function (e) { el.textContent = 'Error: ' + e.message; });
}

function unblockIp(ip) {
  fetch(API + '?action=bad-url-unblock&ip=' + encodeURIComponent(ip), { method: 'POST' })
    .then(function (r) { return r.json(); })
    .then(function (d) {
      if (!d || !d.ok) { showStatus((d && d.error) || 'Unblock failed', true); return; }
      showStatus('Unblocked ' + ip + '.');
      loadBlocked();
    })
    .catch(function (e) { showStatus('Error: ' + e.message, true); });
}

// SM399: the journeys panel - the ONE question the aggregates above cannot
// answer.
//
// Everything else on this page is a marginal count. "Where visits started" and
// "Where visits ended" are already rendered from the aggregates over every
// visit, so they are deliberately NOT repeated here: trails are capped and
// expire, so a second copy would disagree with the first on a busy site and an
// operator would have no way to tell which was wrong. What is left is the
// order, which no aggregate can reconstruct once the event ring rolls.
//
// NO INLINE HANDLERS. The rest of this page uses onclick attributes, which are
// the whole of what breaks under an enforcing CSP (script-src-attr, and a nonce
// does not apply to them). New UI does not add to that debt: the listeners here
// are bound from this script block, which already passes.
var trailDays = [];

function fmtGap(sec) {
  sec = +sec || 0;
  if (sec < 60) return sec + 's';
  var m = Math.floor(sec / 60);
  return m + 'm' + (sec % 60 ? ' ' + (sec % 60) + 's' : '');
}

// The day list comes from the plugin descriptor, which builds it from the trail
// files that EXIST - so a day is only offered while its file is really there.
function initTrails(plugin) {
  var sel = document.getElementById('trail-day');
  var body = document.getElementById('trails-body');
  if (!sel || !body) return;
  var act = (plugin.actions || []).filter(function (a) { return a.id === 'trails'; })[0];
  trailDays = (act && act.choices) ? act.choices.map(function (c) { return c.id; }) : [];
  if (!trailDays.length) {
    body.innerHTML = '<p class="mg-muted">No journeys recorded yet. Visits are written when they '
      + 'finish - a visit ends on thirty minutes of silence - so a day appears here shortly after '
      + 'its first completed visit.</p>';
    sel.innerHTML = '';
  } else {
    sel.innerHTML = trailDays.map(function (d) {
      return '<option value="' + sesc(d) + '">' + sesc(d) + '</option>';
    }).join('');
    sel.addEventListener('change', function () { loadTrails(sel.value); });
  }
  // SM424: the day LIST rides along on the descriptor the summary already
  // fetched, so filling the select costs nothing and is done either way. The
  // day's journeys are a second round trip, and that one waits until somebody
  // opens the card.
  cardSet( 'card-trails', 'trails-card-body',
      blockOpen( 'card-trails', 0 ), trailsLoadCurrent );
}

function trailsLoadCurrent() {
  var sel = document.getElementById('trail-day');
  if (sel && sel.value) loadTrails(sel.value);
}

function loadTrails(day) {
  var body = document.getElementById('trails-body');
  if (!body || !statsScript || !day) return;
  body.textContent = 'Loading journeys…';
  fetch(API + '?action=plugin-action&plugin=stats', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ script: statsScript, action_id: 'trails', params: { choice: day } })
  }).then(function (r) { return r.json(); }).then(renderTrails)
    .catch(function (e) { body.textContent = 'Error: ' + e.message; });
}

function renderTrails(d) {
  var body = document.getElementById('trails-body');
  if (!d || !d.ok) {
    body.innerHTML = '<p class="mg-muted">' + sesc((d && d.error) || 'No journeys for that day.') + '</p>';
    return;
  }
  var h = '<div class="mg-checks">'
        + '<span class="mg-tag mg-tag-auto">visits recorded: ' + fmtNum(d.visits) + '</span>'
        + '<span class="mg-tag mg-tag-auto">kept for ' + fmtNum(d.retention_days) + ' days</span>'
        + '</div>';

  var j = d.journeys || [];
  if (j.length) {
    // Counted over the WHOLE day, not over the sample below - said on the page
    // because a reader cannot otherwise tell which of the two numbers a row is
    // derived from.
    h += '<div class="mg-sec">Routes taken (all ' + fmtNum(d.summary_covers) + ' visits)</div>';
    h += '<table class="mg-table"><thead><tr><th>Route</th><th>Visits</th></tr></thead><tbody>';
    j.forEach(function (r) {
      h += '<tr><td><code>' + sesc(r.key) + '</code></td><td>' + fmtNum(r.count) + '</td></tr>';
    });
    h += '</tbody></table>';
  }

  var t = d.trails || [];
  if (t.length) {
    h += '<div class="mg-sec">Individual visits'
       + (d.truncated ? ' - first ' + fmtNum(d.returned) + ' of ' + fmtNum(d.visits) : '')
       + '</div>';
    if (d.truncated) {
      h += '<p class="mg-muted">This list is a sample. The routes above count the whole day.</p>';
    }
    h += '<table class="mg-table"><thead><tr><th>Path taken</th><th>Pages</th>'
       + '<th>Seen as</th></tr></thead><tbody>';
    t.forEach(function (v) {
      var steps = (v.steps || []).map(function (st) {
        return '<code>' + sesc(st.p) + '</code>'
             + (st.gap != null ? ' <span class="mg-muted">(' + fmtGap(st.gap) + ')</span>' : '');
      }).join(' <span class="mg-muted">&rarr;</span> ');
      var cls = ((v.steps || [])[0] || {}).c || '';
      h += '<tr><td>' + steps + '</td><td>' + fmtNum(v.depth) + '</td><td>'
         + (cls ? '<span class="mg-tag mg-tag-auto">' + sesc(cls) + '</span>' : '')
         + '</td></tr>';
    });
    h += '</tbody></table>';
    h += '<p class="mg-muted">The time after a page is the gap before the next request, so it is '
       + 'a lower bound on how long that page was open - and there is none for the last page, '
       + 'because nothing followed it. Read it as &ldquo;at least this long before moving on&rdquo;, '
       + 'not as reading time.</p>';
  } else if (!j.length) {
    h += '<p class="mg-muted">No completed visits recorded for that day.</p>';
  }
  body.innerHTML = h;
}

loadStats();
// Both cards honour what this viewer last chose; neither fetches until it is
// actually open.
bindCard( 'card-blocked', 'blocked-body', loadBlocked );
bindCard( 'card-trails',  'trails-card-body', trailsLoadCurrent );
cardSet( 'card-blocked', 'blocked-body', blockOpen( 'card-blocked', 0 ), loadBlocked );
</script>
