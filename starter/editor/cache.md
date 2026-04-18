---
title: Cache Manager
auth: editor
search: false
---

<div>
<style>
.cache-wrap { font-family: system-ui, sans-serif; max-width: 800px; margin: 0 auto; }
.editor-nav { margin-bottom: 16px; }
.editor-nav a { margin-right: 16px; color: #07c; text-decoration: none; font-size: 14px; }
.editor-nav a:hover { text-decoration: underline; }
.editor-nav a.active { font-weight: 600; color: #333; border-bottom: 2px solid #07c; }
.cache-toolbar { display: flex; gap: 8px; margin-bottom: 12px; align-items: center; }
.cache-toolbar button { padding: 4px 14px; cursor: pointer; }
.cache-stats { font-size: 13px; color: #666; margin-bottom: 12px; }
.cache-list { border: 1px solid #ccc; border-radius: 4px; }
.cache-item { display: flex; align-items: center; padding: 6px 12px; border-bottom: 1px solid #eee; gap: 8px; }
.cache-item:last-child { border-bottom: none; }
.cache-item .path { flex: 1; font-family: monospace; font-size: 13px; }
.cache-item .age { color: #888; font-size: 12px; min-width: 80px; text-align: right; }
.cache-item .source-status { font-size: 11px; padding: 1px 6px; border-radius: 3px; min-width: 50px; text-align: center; }
.cache-item .source-status.current { background: #efe; color: #060; }
.cache-item .source-status.stale { background: #ffd; color: #860; }
.cache-item .source-status.orphan { background: #fee; color: #c00; }
.cache-item button { padding: 2px 8px; font-size: 12px; cursor: pointer; }
.status-msg { padding: 6px 10px; margin-bottom: 8px; border-radius: 4px; font-size: 13px; }
.status-msg.error { background: #fee; color: #c00; }
.status-msg.ok { background: #efe; color: #060; }
</style>
</div>

<div class="cache-wrap" id="app">

<nav class="editor-nav">
<a href="/editor/">Files</a>
<a href="/editor/plugins">Plugins</a>
<a href="/editor/themes">Themes</a>
<a href="/editor/users">Users</a>
<a href="/editor/cache" class="active">Cache</a>
</div>

<div id="status"></div>

<div class="cache-toolbar">
<button onclick="loadCache()">Refresh</button>
<button onclick="clearAll()" style="color:#c00;">Clear All Cache</button>
</div>

<div class="cache-stats" id="cache-stats"></div>

<div class="cache-list" id="cache-list">
<div class="cache-item"><span class="path">Loading...</span></div>
</div>

</div>

<script>
var API = '/cgi-bin/lazysite-editor-api.pl';

function showStatus(msg, isError) {
  var el = document.getElementById('status');
  el.className = 'status-msg ' + (isError ? 'error' : 'ok');
  el.textContent = msg;
  if (!isError) setTimeout(function() { el.textContent = ''; el.className = ''; }, 3000);
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
    list.innerHTML = '<div class="cache-item"><span class="path" style="color:#888;">No cached files</span></div>';
    return;
  }

  files.sort(function(a, b) { return a.path.localeCompare(b.path); });
  var now = Math.floor(Date.now() / 1000);

  var html = '';
  for (var i = 0; i < files.length; i++) {
    var f = files[i];
    var age = now - (f.mtime || 0);
    var statusClass = f.has_source ? 'current' : 'orphan';
    var statusLabel = f.has_source ? 'Has source' : 'Orphan';
    html += '<div class="cache-item">';
    html += '<span class="path">' + escHtml(f.path) + '</span>';
    html += '<span class="source-status ' + statusClass + '">' + statusLabel + '</span>';
    html += '<span class="age">' + formatAge(age) + ' ago</span>';
    html += '<button onclick="invalidate(\'' + escHtml(f.path) + '\')">Invalidate</button>';
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
