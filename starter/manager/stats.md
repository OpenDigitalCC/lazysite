---
title: Visitor Stats
auth: manager
search: false
---

<div id="status" class="mg-status"></div>

<div class="mg-card">
<div class="mg-card-header">
<span class="mg-card-title">Visitor statistics</span>
<button class="mg-btn mg-btn-sm" onclick="loadStats()">Refresh</button>
</div>
<div class="mg-card-body" id="stats-body">Loading&hellip;</div>
</div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';
var statsScript = null;

function sesc(s) { var d = document.createElement('div'); d.textContent = (s == null ? '' : String(s)); return d.innerHTML; }

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
      body.innerHTML = 'Enable the <b>Visitor Stats</b> plugin on the '
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
      + '<p class="mg-muted">Configure the access-log path on the <a href="/manager/plugin-config">Plugin Config</a> page.</p>';
    return;
  }
  var h = '';
  // Summary tiles
  h += '<div class="mg-stat-tiles">'
     + tile('Hits', fmtNum(d.hits))
     + tile('Unique visitors' + (d.anonymised ? ' *' : ''), fmtNum(d.unique_visitors))
     + tile('Data served', fmtBytes(d.bytes))
     + tile('Window', d.window_days + ' days')
     + '</div>';
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

  h += '<div class="mg-stat-cols">';
  h += topTable('Top pages', d.top_pages, 'Page');
  h += topTable('Top referrers', d.top_referrers, 'Referrer');
  h += '</div>';

  // Status codes
  if (d.status) {
    var codes = Object.keys(d.status).sort();
    h += '<div class="mg-sec">Status codes</div><div class="mg-checks">';
    codes.forEach(function (c) { h += '<span class="mg-tag mg-tag-auto">' + sesc(c) + ': ' + fmtNum(d.status[c]) + '</span>'; });
    h += '</div>';
  }

  h += '<p class="mg-muted" style="margin-top:1rem">Source: <code class="mg-code">' + sesc(d.log) + '</code> '
     + '&middot; ' + fmtNum(d.scanned_lines) + ' lines scanned' + (d.capped ? ' (capped)' : '') + '.</p>';
  body.innerHTML = h;
}

function tile(label, value) {
  return '<div class="mg-stat-tile"><div class="mg-stat-value">' + sesc(value)
       + '</div><div class="mg-stat-label">' + sesc(label) + '</div></div>';
}
function topTable(title, rows, col) {
  var h = '<div class="mg-stat-col"><div class="mg-sec">' + sesc(title) + '</div>';
  if (!rows || !rows.length) { return h + '<p class="mg-muted">None.</p></div>'; }
  h += '<table class="mg-table"><thead><tr><th>' + sesc(col) + '</th><th>Hits</th></tr></thead><tbody>';
  rows.forEach(function (r) {
    h += '<tr><td style="word-break:break-all">' + sesc(r.key) + '</td><td>' + fmtNum(r.count) + '</td></tr>';
  });
  return h + '</tbody></table></div>';
}

loadStats();
</script>
