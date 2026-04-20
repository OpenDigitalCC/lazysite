---
title: Cache Manager
auth: manager
search: false
---

<div id="status" class="mg-status"></div>

<div style="display:flex;gap:8px;margin-bottom:12px;align-items:center;">
<button class="mg-btn" onclick="loadCache()">Refresh</button>
<button class="mg-btn mg-btn-danger" onclick="clearAll()">Clear All Cache</button>
</div>

<div class="mg-status" id="cache-stats"></div>

<div class="mg-file-list" id="cache-list">
<div class="mg-file-item"><span class="mg-file-name">Loading...</span></div>
</div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';

function showStatus(msg, isError) {
  var el = document.getElementById('status');
  // Errors go to the global mg-warning-bar so they are prominent and
  // consistent across every manager page. Successes stay inline and
  // auto-dismiss after 3s; they also clear any lingering warning from
  // a previous failed request.
  if (isError) {
    if (typeof mgShowWarning === 'function') mgShowWarning(msg, true);
    if (el) { el.textContent = ''; el.className = 'mg-status'; }
    return;
  }
  if (typeof mgClearWarning === 'function') mgClearWarning();
  if (!el) return;
  if (!msg) { el.textContent = ''; el.className = 'mg-status'; return; }
  el.className = 'mg-status mg-status-success';
  el.textContent = msg;
  setTimeout(function() { showStatus(''); }, 3000);
}

function escHtml(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function formatAge(seconds) {
  if (seconds < 60) return seconds + 's';
  if (seconds < 3600) return Math.floor(seconds / 60) + 'm';
  if (seconds < 86400) return Math.floor(seconds / 3600) + 'h ' + Math.floor((seconds % 3600) / 60) + 'm';
  return Math.floor(seconds / 86400) + 'd ' + Math.floor((seconds % 86400) / 3600) + 'h';
}

function loadCache() {
  showStatus('');
  fetch(API + '?action=cache-list')
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      renderCache(data.cached || []);
      renderStats(data);
    })
    .catch(function(e) { showStatus('Failed to load cache: ' + e.message, true); });
}

function renderStats(data) {
  var el = document.getElementById('cache-stats');
  var files = data.cached || [];
  el.textContent = files.length + ' cached files';
}

function renderCache(files) {
  var list = document.getElementById('cache-list');
  if (files.length === 0) {
    list.innerHTML = '<div class="mg-file-item"><span class="mg-file-name mg-empty">No cached files</span></div>';
    return;
  }

  files.sort(function(a, b) { return a.path.localeCompare(b.path); });
  var now = Math.floor(Date.now() / 1000);

  var html = '';
  for (var i = 0; i < files.length; i++) {
    var f = files[i];
    var age = now - (f.mtime || 0);
    var statusClass = f.has_source ? 'mg-badge-success' : 'mg-badge-muted';
    var statusLabel = f.has_source ? 'Has source' : 'Orphan';
    html += '<div class="mg-file-item">';
    html += '<span class="mg-file-name" style="font-family:var(--mg-mono);font-size:0.8rem;">' + escHtml(f.path) + '</span>';
    html += '<span class="mg-badge ' + statusClass + '">' + statusLabel + '</span>';
    html += '<span class="mg-file-meta">' + formatAge(age) + ' ago</span>';
    html += '<button class="mg-btn mg-btn-sm" onclick="invalidate(\'' + escHtml(f.path) + '\')">Invalidate</button>';
    html += '</div>';
  }
  list.innerHTML = html;
}

function invalidate(path) {
  fetch(API + '?action=cache-invalidate&path=' + encodeURIComponent(path), { method: 'POST' })
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      showStatus('Cache invalidated: ' + path);
      loadCache();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

function clearAll() {
  if (!confirm('Clear all cached files? Pages will be re-rendered on next request.')) return;
  fetch(API + '?action=cache-invalidate&path=*', { method: 'POST' })
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      showStatus('Cleared ' + (data.count || 0) + ' cached files.');
      loadCache();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

loadCache();
</script>
