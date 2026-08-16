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
<span class="mg-card-title">Blocked IPs (auto-blocker)</span>
<button class="mg-btn mg-btn-sm" onclick="loadBlocked()">Refresh</button>
</div>
<div class="mg-card-body" id="blocked-body">Loading&hellip;</div>
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
    h += '<div class="mg-sec">Who&rsquo;s calling</div><div class="mg-stat-tiles">';
    defs.forEach(function (p) {
      var c = d.classes[p[0]] || { hits: 0, visitors: 0 };
      h += '<div class="mg-stat-tile"><div class="mg-stat-value">' + fmtNum(c.hits) + '</div>'
         + '<div class="mg-stat-label">' + sesc(p[1])
         + ' <span class="mg-muted">(' + fmtNum(c.visitors) + ' IP' + (c.visitors === 1 ? '' : 's') + ')</span>'
         + '</div></div>';
    });
    h += '</div>';
    // Proportional split bar - a visual quick-read of the audience mix.
    var mix = [['human','#2e8b57'],['logged_in','#3a7bd5'],['ai','#8e44ad'],['bot','#d98a1f'],['noise','#b03a3a']];
    var mixTotal = mix.reduce(function (s, p) { return s + ((d.classes[p[0]] || {}).hits || 0); }, 0);
    if (mixTotal > 0) {
      h += '<div class="mg-split-bar" style="display:flex;height:14px;border-radius:7px;overflow:hidden;margin:0.4rem 0">';
      mix.forEach(function (p) {
        var hits = (d.classes[p[0]] || {}).hits || 0;
        if (hits <= 0) return;
        var pct = (hits / mixTotal * 100);
        var lbl = (defs.filter(function (x) { return x[0] === p[0]; })[0] || [p[0], p[0]])[1];
        h += '<span style="width:' + pct.toFixed(2) + '%;background:' + p[1] + '" '
           + 'title="' + sesc(lbl) + ': ' + fmtNum(hits) + ' (' + pct.toFixed(1) + '%)"></span>';
      });
      h += '</div>';
    }
    h += '<p class="mg-muted">Classified from the log alone (user-agent + path) - an estimate, not '
       + 'authenticated. &ldquo;Logged-in&rdquo; and &ldquo;AI&rdquo; are attributed per request, not per session.</p>';
  }
  if (d.anonymised) h += '<p class="mg-muted">* visitor IPs are anonymised (last octet zeroed) before counting.</p>';

  // Per-day bar chart
  if (d.per_day && d.per_day.length) {
    var max = d.per_day.reduce(function (m, x) { return x.count > m ? x.count : m; }, 0) || 1;
    h += '<div class="mg-sec">Hits per day</div><div class="mg-bars">';
    d.per_day.forEach(function (x) {
      var pct = Math.round(x.count / max * 100);
      h += '<div class="mg-bar-row"><span class="mg-bar-label">' + sesc(x.day) + '</span>'
         + '<span class="mg-bar"><span class="mg-bar-fill" style="width:' + pct + '%"></span></span>'
         + '<span class="mg-bar-val">' + fmtNum(x.count) + '</span></div>';
    });
    h += '</div>';
  }

  // SM213: month-on-month trend (filled async from the durable stats index).
  h += '<div id="mom-block"></div>';

  h += '<div class="mg-stat-cols">';
  h += pageTable('Top pages', d.top_pages);
  h += refBlock(d.referrers);
  h += '</div>';

  // Status codes
  if (d.status) {
    var codes = Object.keys(d.status).sort();
    h += '<div class="mg-sec">Status codes</div><div class="mg-checks">';
    codes.forEach(function (c) { h += '<span class="mg-tag mg-tag-auto">' + sesc(c) + ': ' + fmtNum(d.status[c]) + '</span>'; });
    h += '</div>';
  }

  // Recent server errors - synthesised categories + counts only (no raw lines,
  // addresses or paths).
  if (d.errors && d.errors.available) {
    h += '<div class="mg-sec">Recent server errors</div>';
    var cats = d.errors.categories || [];
    if (!cats.length) {
      h += '<p class="mg-muted">No recent errors.</p>';
    } else {
      h += '<div class="mg-checks">';
      cats.forEach(function (c) {
        h += '<span class="mg-tag mg-tag-auto">' + sesc(c.label) + ': ' + fmtNum(c.count) + '</span>';
      });
      h += '</div>';
    }
  }

  // Source - the disk path is never shown, and the raw log is never downloadable.
  h += '<p class="mg-muted" style="margin-top:1rem">' + fmtNum(d.scanned_lines)
     + ' log lines scanned' + (d.capped ? ' (capped)' : '') + '.</p>';
  body.innerHTML = h;
  loadMonthly();
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

loadStats();
loadBlocked();
</script>
