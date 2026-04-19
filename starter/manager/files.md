---
title: Files
auth: manager
search: false
---

<div id="app">

<div id="status"></div>

<div class="mg-breadcrumb" id="breadcrumb"></div>

<div class="mg-file-toolbar">
<input type="search" id="file-filter" class="mg-file-filter" placeholder="Filter files..." oninput="filterFiles(this.value)">
<button class="mg-btn" onclick="newFile()">New File</button>
<button class="mg-btn" onclick="newFolder()">New Folder</button>
</div>

<div class="mg-file-list" id="file-list">
<div class="mg-file-item"><span class="mg-file-name">Loading...</span></div>
</div>

</div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';
var currentDir = '/';

function showStatus(msg, isError) {
  var el = document.getElementById('status');
  el.className = 'mg-status ' + (isError ? 'mg-status-error' : 'mg-status-success');
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

function buildBreadcrumb(dirPath, linkFn) {
  var parts = dirPath.replace(/^\/+|\/+$/g, '').split('/').filter(Boolean);
  var items = [linkFn('/', '/')];
  var accumulated = '';
  for (var i = 0; i < parts.length; i++) {
    accumulated += '/' + parts[i];
    items.push(linkFn(accumulated + '/', parts[i]));
  }
  return items.join(' &rsaquo; ');
}

function updateBreadcrumb() {
  var html = buildBreadcrumb(currentDir, function(path, label) {
    return '<a href="#" onclick="loadDir(\'' + path + '\'); return false;">' + label + '</a>';
  });
  document.getElementById('breadcrumb').innerHTML = html;
}

function renderFiles(files) {
  var list = document.getElementById('file-list');
  if (files.length === 0) {
    list.innerHTML = '<div class="mg-file-item"><span class="mg-file-name" style="color:#888;">Empty directory</span></div>';
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
    html += '<div class="mg-file-item" data-name="' + escHtml(f.name) + '">';
    html += '<span class="mg-file-icon">' + icon + '</span>';
    if (f.type === 'dir') {
      html += '<span class="mg-file-name"><a href="#" onclick="loadDir(\'' + escHtml(f.path) + '/\'); return false;">' + escHtml(f.name) + '/</a></span>';
    } else {
      html += '<span class="mg-file-name"><a href="/manager/edit?path=' + encodeURIComponent(f.path) + '">' + escHtml(f.name) + '</a></span>';
    }
    if (f.size !== undefined) {
      html += '<span class="mg-file-meta">' + formatSize(f.size) + '</span>';
    }
    if (f.mtime) {
      html += '<span class="mg-file-meta">' + relativeTime(f.mtime) + '</span>';
    }
    html += '<span class="mg-file-actions"><button class="mg-btn mg-btn-sm mg-btn-danger" onclick="deleteItem(\'' + escHtml(f.path) + '\', \'' + f.type + '\')">Delete</button></span>';
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
  var items = document.querySelectorAll('.mg-file-item');
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

var initDir = decodeURIComponent(location.hash.replace(/^#/, '')) || '/';
loadDir(initDir);
</script>
