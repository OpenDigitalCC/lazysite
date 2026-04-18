---
title: Theme Manager
auth: editor
search: false
query_params:
  - action
  - theme
---

<div>
<style>
.themes-wrap { font-family: system-ui, sans-serif; max-width: 700px; margin: 0 auto; }
.editor-nav { margin-bottom: 16px; }
.editor-nav a { margin-right: 16px; color: #07c; text-decoration: none; font-size: 14px; }
.editor-nav a:hover { text-decoration: underline; }
.editor-nav a.active { font-weight: 600; color: #333; border-bottom: 2px solid #07c; }
.theme-list { border: 1px solid #ccc; border-radius: 4px; margin-bottom: 16px; }
.theme-item { display: flex; align-items: center; padding: 8px 12px; border-bottom: 1px solid #eee; gap: 8px; }
.theme-item:last-child { border-bottom: none; }
.theme-item .name { flex: 1; font-weight: bold; }
.theme-item .active-badge { background: #0a0; color: #fff; font-size: 11px; padding: 1px 6px; border-radius: 3px; }
.theme-item button { padding: 3px 10px; font-size: 12px; cursor: pointer; }
.upload-section { border: 1px solid #ccc; border-radius: 4px; padding: 12px; background: #f8f8f8; }
.upload-section h3 { margin: 0 0 8px 0; font-size: 15px; }
.upload-section input[type=file] { margin-right: 8px; }
.status-msg { padding: 6px 10px; margin-bottom: 8px; border-radius: 4px; font-size: 13px; }
.status-msg.error { background: #fee; color: #c00; }
.status-msg.ok { background: #efe; color: #060; }
</style>
</div>

<div class="themes-wrap" id="app">

<nav class="editor-nav">
<a href="/editor/">Files</a>
<a href="/editor/themes" class="active">Themes</a>
<a href="/editor/users">Users</a>
<a href="/editor/cache">Cache</a>
</div>

<div id="status"></div>

<h2 style="font-size:18px; margin-bottom:12px;">Installed Themes</h2>

<div class="theme-list" id="theme-list">
<div class="theme-item"><span class="name">Loading...</span></div>
</div>

<div class="upload-section">
<h3>Upload Theme</h3>
<p style="font-size:13px; color:#666; margin:0 0 8px 0;">Upload a .zip file containing a theme directory.</p>
<input type="file" id="theme-file" accept=".zip">
<button onclick="uploadTheme()">Upload</button>
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

function loadThemes() {
  fetch(API + '?action=theme-list')
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      renderThemes(data.themes || [], data.active || '');
    })
    .catch(function(e) { showStatus('Failed to load themes: ' + e.message, true); });
}

function renderThemes(themes, active) {
  var list = document.getElementById('theme-list');
  if (themes.length === 0) {
    list.innerHTML = '<div class="theme-item"><span class="name" style="color:#888;">No themes installed</span></div>';
    return;
  }
  var html = '';
  for (var i = 0; i < themes.length; i++) {
    var t = themes[i];
    var isActive = t.name === active;
    html += '<div class="theme-item">';
    html += '<span class="name">' + escHtml(t.name) + '</span>';
    if (isActive) {
      html += '<span class="active-badge">active</span>';
    }
    if (!isActive) {
      html += '<button onclick="activateTheme(\'' + escHtml(t.name) + '\')">Activate</button>';
    }
    html += '<button onclick="renameTheme(\'' + escHtml(t.name) + '\')">Rename</button>';
    if (!isActive) {
      html += '<button onclick="deleteTheme(\'' + escHtml(t.name) + '\')">Delete</button>';
    }
    html += '</div>';
  }
  list.innerHTML = html;
}

function escHtml(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function activateTheme(name) {
  if (!confirm('Activate "' + name + '"? All cached pages will be cleared.')) return;
  fetch(API + '?action=theme-activate&path=' + encodeURIComponent(name), { method: 'POST' })
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      showStatus('Theme "' + name + '" activated.');
      loadThemes();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

function deleteTheme(name) {
  if (!confirm('Delete theme "' + name + '"? This cannot be undone.')) return;
  fetch(API + '?action=theme-delete&path=' + encodeURIComponent(name), { method: 'POST' })
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      showStatus('Theme deleted.');
      loadThemes();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

function renameTheme(name) {
  var newName = prompt('New name for theme "' + name + '":', name);
  if (!newName || newName === name) return;
  fetch(API + '?action=theme-rename&path=' + encodeURIComponent(name), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ new_name: newName })
  })
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      showStatus('Theme renamed.');
      loadThemes();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

function uploadTheme() {
  var fileInput = document.getElementById('theme-file');
  if (!fileInput.files.length) { showStatus('Select a .zip file first.', true); return; }
  var file = fileInput.files[0];
  if (!file.name.endsWith('.zip')) { showStatus('File must be a .zip archive.', true); return; }

  var reader = new FileReader();
  reader.onload = function(e) {
    var arrayBuffer = e.target.result;
    var bytes = new Uint8Array(arrayBuffer);
    var binary = '';
    for (var i = 0; i < bytes.length; i++) {
      binary += String.fromCharCode(bytes[i]);
    }
    var base64 = btoa(binary);

    fetch(API + '?action=theme-upload&filename=' + encodeURIComponent(file.name), {
      method: 'POST',
      body: arrayBuffer
    })
      .then(function(r) { return r.json(); })
      .then(function(data) {
        if (!data.ok) { showStatus(data.error, true); return; }
        showStatus('Theme uploaded: ' + (data.name || file.name));
        fileInput.value = '';
        loadThemes();
      })
      .catch(function(e) { showStatus('Upload failed: ' + e.message, true); });
  };
  reader.readAsArrayBuffer(file);
}

loadThemes();
</script>
