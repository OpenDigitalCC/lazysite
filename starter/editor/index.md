---
title: lazysite Editor
subtitle: Content editor
auth: editor
search: false
---

<div>
<style>
.editor-wrap { font-family: system-ui, sans-serif; max-width: 900px; margin: 0 auto; }
.editor-toolbar { display: flex; gap: 8px; margin-bottom: 12px; align-items: center; }
.editor-toolbar button { padding: 4px 12px; cursor: pointer; }
.breadcrumb { font-size: 14px; color: #555; margin-bottom: 8px; }
.breadcrumb a { color: #07c; text-decoration: none; }
.breadcrumb a:hover { text-decoration: underline; }
.file-list { border: 1px solid #ccc; border-radius: 4px; }
.file-item { display: flex; align-items: center; padding: 6px 12px; border-bottom: 1px solid #eee; }
.file-item:last-child { border-bottom: none; }
.file-item .name { flex: 1; }
.file-item .name a { text-decoration: none; color: #07c; }
.file-item .name a:hover { text-decoration: underline; }
.file-item .icon { margin-right: 8px; font-size: 16px; }
.file-item .meta { color: #888; font-size: 13px; margin-right: 12px; }
.file-item .actions button { padding: 2px 8px; font-size: 12px; cursor: pointer; }
.editor-nav { margin-bottom: 16px; }
.editor-nav a { margin-right: 16px; color: #07c; text-decoration: none; font-size: 14px; }
.editor-nav a:hover { text-decoration: underline; }
.editor-nav a.active { font-weight: 600; color: #333; border-bottom: 2px solid #07c; }
.status-msg { padding: 8px; margin-bottom: 8px; border-radius: 4px; font-size: 14px; }
.status-msg.error { background: #fee; color: #c00; }
.status-msg.ok { background: #efe; color: #060; }
</style>
</div>

<div class="editor-wrap" id="app">

<nav class="editor-nav">
<a href="/editor/" class="active">Files</a>
<a href="/editor/plugins">Plugins</a>
<a href="/editor/themes">Themes</a>
<a href="/editor/users">Users</a>
<a href="/editor/cache">Cache</a>
</nav>

<div id="status"></div>

<div class="breadcrumb" id="breadcrumb"></div>

<div class="editor-toolbar">
<input type="search" id="file-filter" placeholder="Filter files..." oninput="filterFiles(this.value)" style="flex:1;padding:4px 8px;border:1px solid #ccc;border-radius:3px;font-size:13px;">
<button onclick="newFile()">New File</button>
<button onclick="newFolder()">New Folder</button>
</div>

<div class="file-list" id="file-list">
<div class="file-item"><span class="name">Loading...</span></div>
</div>

</div>

<script>
var API = '/cgi-bin/lazysite-editor-api.pl';
var currentDir = '/';

function showStatus(msg, isError) {
  var el = document.getElementById('status');
  el.className = 'status-msg ' + (isError ? 'error' : 'ok');
  el.textContent = msg;
  if (!isError) setTimeout(function() { el.textContent = ''; el.className = ''; }, 3000);
}

function loadDir(dir) {
  currentDir = dir || '/';
  updateBreadcrumb();
  fetch(API + '?action=list&path=' + encodeURIComponent(currentDir))
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      renderFiles(data.entries || []);
    })
    .catch(function(e) { showStatus('Failed to load directory: ' + e.message, true); });
}

function updateBreadcrumb() {
  var parts = currentDir.split('/').filter(Boolean);
  var html = '<a href="#" onclick="loadDir(\'/\'); return false;">root</a>';
  var path = '';
  for (var i = 0; i < parts.length; i++) {
    path += '/' + parts[i];
    html += ' / <a href="#" onclick="loadDir(\'' + path + '/\'); return false;">' + parts[i] + '</a>';
  }
  document.getElementById('breadcrumb').innerHTML = html;
}

function renderFiles(files) {
  var list = document.getElementById('file-list');
  if (files.length === 0) {
    list.innerHTML = '<div class="file-item"><span class="name" style="color:#888;">Empty directory</span></div>';
    return;
  }
  var html = '';
  // Sort: directories first, then files
  files.sort(function(a, b) {
    if (a.type === 'dir' && b.type !== 'dir') return -1;
    if (a.type !== 'dir' && b.type === 'dir') return 1;
    return a.name.localeCompare(b.name);
  });
  for (var i = 0; i < files.length; i++) {
    var f = files[i];
    var icon = f.type === 'dir' ? '&#128193;' : '&#128196;';
    html += '<div class="file-item" data-name="' + escHtml(f.name) + '">';
    html += '<span class="icon">' + icon + '</span>';
    if (f.type === 'dir') {
      html += '<span class="name"><a href="#" onclick="loadDir(\'' + escHtml(f.path) + '/\'); return false;">' + escHtml(f.name) + '/</a></span>';
    } else {
      html += '<span class="name"><a href="/editor/edit?path=' + encodeURIComponent(f.path) + '">' + escHtml(f.name) + '</a></span>';
    }
    if (f.size !== undefined) {
      html += '<span class="meta">' + formatSize(f.size) + '</span>';
    }
    if (f.mtime) {
      html += '<span class="meta">' + relativeTime(f.mtime) + '</span>';
    }
    html += '<span class="actions"><button onclick="deleteItem(\'' + escHtml(f.path) + '\', \'' + f.type + '\')">Delete</button></span>';
    html += '</div>';
  }
  list.innerHTML = html;
}

function escHtml(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function relativeTime(mtime) {
  var diff = Math.floor(Date.now() / 1000) - mtime;
  if (diff < 60)    return 'just now';
  if (diff < 3600)  return Math.floor(diff/60) + 'm ago';
  if (diff < 86400) return Math.floor(diff/3600) + 'h ago';
  return Math.floor(diff/86400) + 'd ago';
}

function filterFiles(query) {
  var items = document.querySelectorAll('.file-item');
  query = query.toLowerCase();
  for (var i = 0; i < items.length; i++) {
    var name = items[i].getAttribute('data-name') || '';
    items[i].style.display = name.toLowerCase().indexOf(query) >= 0 ? '' : 'none';
  }
}

function formatSize(bytes) {
  if (bytes < 1024) return bytes + ' B';
  if (bytes < 1048576) return (bytes / 1024).toFixed(1) + ' KB';
  return (bytes / 1048576).toFixed(1) + ' MB';
}

function newFile() {
  var name = prompt('File name (e.g. page.md):');
  if (!name) return;
  var path = currentDir + name;
  fetch(API + '?action=save&path=' + encodeURIComponent(path), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ content: '---\ntitle: New Page\n---\n\nNew page content.\n', mtime: null })
  })
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      showStatus('File created.');
      loadDir(currentDir);
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

function newFolder() {
  var name = prompt('Folder name:');
  if (!name) return;
  var path = currentDir + name + '/.gitkeep';
  fetch(API + '?action=save&path=' + encodeURIComponent(path), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ content: '', mtime: null })
  })
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      showStatus('Folder created.');
      loadDir(currentDir);
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

function deleteItem(path, type) {
  var label = type === 'dir' ? 'folder' : 'file';
  if (!confirm('Delete ' + label + ' "' + path + '"?')) return;
  fetch(API + '?action=delete&path=' + encodeURIComponent(path), {
    method: 'POST'
  })
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      showStatus(label.charAt(0).toUpperCase() + label.slice(1) + ' deleted.');
      loadDir(currentDir);
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

loadDir('/');
</script>
