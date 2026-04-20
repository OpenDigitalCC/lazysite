---
title: Theme Manager
auth: manager
search: false
query_params:
  - action
  - theme
---

<div id="status" class="mg-status"></div>

<div class="mg-card">
<div class="mg-card-header">
<span class="mg-card-title">Installed Themes</span>
</div>
<p class="mg-card-subtitle" style="margin:0 8px 8px;">Activating a theme sets it as the site default for all visitors and clears the page cache.</p>
<div id="theme-list">
<div class="mg-file-item"><span class="mg-file-name">Loading...</span></div>
</div>
</div>

<div class="mg-card">
<div class="mg-card-header">
<span class="mg-card-title">Upload Theme</span>
</div>
<div class="mg-card-body">
<p class="mg-card-subtitle" style="margin:0 0 8px 0;">Upload a .zip file containing a theme directory.</p>
<div style="display:flex;gap:0.5rem;align-items:center;">
<input type="file" id="theme-file" accept=".zip">
<button class="mg-btn mg-btn-outline" onclick="uploadTheme()">Upload</button>
</div>
</div>
</div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';

function showStatus(msg, isError) {
  var el = document.getElementById('status');
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

function loadThemes() {
  showStatus('');
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
  var visible = themes.filter(function(t) { return t.name !== 'manager'; });
  if (visible.length === 0) {
    list.innerHTML = '<div class="mg-file-item"><span class="mg-file-name mg-empty">No themes installed</span></div>';
    return;
  }
  var html = '';
  for (var i = 0; i < visible.length; i++) {
    var t = visible[i];
    var isActive = t.name === active;
    html += '<div class="mg-file-item">';
    html += '<span class="mg-file-name">' + escHtml(t.name) + '</span>';
    if (isActive) {
      html += '<span class="mg-badge mg-badge-success">active</span>';
    }
    html += '<div class="mg-file-actions">';
    if (isActive) {
      html += '<button class="mg-btn mg-btn-sm" onclick="deactivateTheme()">Deactivate</button>';
    } else {
      html += '<button class="mg-btn mg-btn-sm mg-btn-primary" onclick="activateTheme(\'' + escHtml(t.name) + '\')">Activate</button>';
    }
    html += '<button class="mg-btn mg-btn-sm" onclick="renameTheme(\'' + escHtml(t.name) + '\')">Rename</button>';
    if (!isActive) {
      html += '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="deleteTheme(\'' + escHtml(t.name) + '\')">Delete</button>';
    }
    html += '</div>';
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

function deactivateTheme() {
  if (!confirm('Deactivate theme and use the built-in fallback?')) return;
  fetch(API + '?action=theme-activate&path=', { method: 'POST' })
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      showStatus('Theme deactivated. Using built-in fallback.');
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
