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
<button class="mg-btn" onclick="newFile()">Add File</button>
<button class="mg-btn" onclick="newFolder()">Add Folder</button>
<button class="mg-btn" onclick="triggerUpload()">Upload</button>
<button class="mg-btn" id="zip-btn" style="display:none" onclick="zipSelected()">Download selected</button>
<input type="file" id="upload-input" multiple style="display:none" onchange="uploadFiles(this.files)">
</div>

<div class="mg-file-list" id="file-list">
<div class="mg-file-item"><span class="mg-file-name">Loading...</span></div>
</div>

</div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';
var currentDir = '/';

// SM019: must mirror %TEXT_EXTENSIONS in lazysite-manager-api.pl.
// Files whose extension is not in this set are rendered as a plain
// name (no edit link) and can only be downloaded.
var TEXT_EXTENSIONS = {
  md: 1, txt: 1, html: 1, htm: 1, css: 1, js: 1,
  json: 1, jsonl: 1, xml: 1, yaml: 1, yml: 1,
  csv: 1, tsv: 1, conf: 1, ini: 1, log: 1,
  pl: 1, pm: 1, sh: 1, bash: 1, env: 1, example: 1
};

function isEditable(name) {
  var m = name.match(/\.([^.]+)$/);
  if (!m) return true;
  return TEXT_EXTENSIONS[m[1].toLowerCase()] ? true : false;
}

function showStatus(msg, isError) {
  var el = document.getElementById('status');
  if (isError) {
    if (typeof mgShowWarning === 'function') mgShowWarning(msg, true);
    if (el) { el.textContent = ''; el.className = ''; }
    return;
  }
  if (typeof mgClearWarning === 'function') mgClearWarning();
  if (!el) return;
  if (!msg) { el.textContent = ''; el.className = ''; return; }
  el.className = 'mg-status mg-status-success';
  el.textContent = msg;
  setTimeout(function() { showStatus(''); }, 3000);
}

function loadDir(dir) {
  showStatus('');
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
    if (f.type === 'dir') {
      html += '<span class="mg-file-icon">' + icon + '</span>';
      html += '<span class="mg-file-name"><a href="#" onclick="loadDir(\'' + escHtml(f.path) + '/\'); return false;">' + escHtml(f.name) + '/</a></span>';
    } else {
      // SM019: file rows get a selection checkbox for zip download;
      // directory rows do not (download-folder is out of scope).
      html += '<input type="checkbox" class="mg-file-select" value="' + escHtml(f.path) + '" onchange="updateZipButton()">';
      html += '<span class="mg-file-icon">' + icon + '</span>';
      if (isEditable(f.name)) {
        html += '<span class="mg-file-name"><a href="/manager/edit?path=' + encodeURIComponent(f.path) + '">' + escHtml(f.name) + '</a></span>';
      } else {
        html += '<span class="mg-file-name">' + escHtml(f.name) + '</span>';
      }
    }
    if (f.size !== undefined) {
      html += '<span class="mg-file-meta">' + formatSize(f.size) + '</span>';
    }
    if (f.mtime) {
      html += '<span class="mg-file-meta">' + relativeTime(f.mtime) + '</span>';
    }
    html += '<span class="mg-file-actions">';
    if (f.type !== 'dir') {
      html += '<a class="mg-file-download" href="' + API + '?action=file-download&path=' + encodeURIComponent(f.path) + '" download="' + escHtml(f.name) + '" title="Download">&darr;</a> ';
    }
    html += '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="deleteItem(\'' + escHtml(f.path) + '\', \'' + f.type + '\')">Delete</button>';
    html += '</span>';
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

// SM019: upload + zip-download handlers. The global fetch wrapper in
// view.tt already attaches X-CSRF-Token to every POST to the manager
// API, so multipart uploads just use fetch() directly - no
// query-string token needed.
function triggerUpload() {
  document.getElementById('upload-input').click();
}

function uploadFiles(files) {
  if (!files || !files.length) return;
  var dir = currentDir;
  var total = files.length;
  if (typeof mgShowWarning === 'function') {
    mgShowWarning('Uploading ' + total + ' file(s)...', false);
  }
  var fd = new FormData();
  fd.append('overwrite', '0');
  for (var i = 0; i < files.length; i++) {
    fd.append('file', files[i], files[i].name);
  }
  var url = API + '?action=file-upload&path=' + encodeURIComponent(dir);
  fetch(url, { method: 'POST', body: fd })
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) {
        showStatus(data.error || 'Upload failed', true);
        return;
      }
      if (data.skipped && data.skipped.length) {
        handleSkipped(data.skipped, dir, files);
      } else {
        if (typeof mgClearWarning === 'function') mgClearWarning();
        var savedCount = data.saved ? data.saved.length : 0;
        var errs = data.errors || [];
        if (errs.length) {
          var firstErr = errs[0].error || 'upload error';
          showStatus('Uploaded ' + savedCount + ' of ' + total + ' (' + firstErr + ')', errs.length > 0 && savedCount === 0);
        } else {
          showStatus('Uploaded ' + savedCount + ' file(s).');
        }
        loadDir(dir);
      }
      document.getElementById('upload-input').value = '';
    })
    .catch(function(e) { showStatus('Upload error: ' + e.message, true); });
}

function handleSkipped(skipped, dir, files) {
  var msg = 'These files already exist:\n\n' + skipped.join('\n') + '\n\nOverwrite?';
  if (!confirm(msg)) {
    showStatus('Upload cancelled for ' + skipped.length + ' file(s).');
    loadDir(dir);
    return;
  }
  var skipSet = {};
  for (var i = 0; i < skipped.length; i++) skipSet[skipped[i]] = true;
  var toRetry = [];
  for (var j = 0; j < files.length; j++) {
    if (skipSet[files[j].name]) toRetry.push(files[j]);
  }
  var fd = new FormData();
  fd.append('overwrite', '1');
  for (var i = 0; i < toRetry.length; i++) {
    fd.append('file', toRetry[i], toRetry[i].name);
  }
  var url = API + '?action=file-upload&path=' + encodeURIComponent(dir);
  fetch(url, { method: 'POST', body: fd })
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (typeof mgClearWarning === 'function') mgClearWarning();
      loadDir(dir);
    })
    .catch(function(e) { showStatus('Overwrite error: ' + e.message, true); });
}

function zipSelected() {
  var checks = document.querySelectorAll('.mg-file-select:checked');
  if (!checks.length) return;
  var qs = [];
  for (var i = 0; i < checks.length; i++) {
    qs.push('paths=' + encodeURIComponent(checks[i].value));
  }
  var url = API + '?action=file-zip-download&' + qs.join('&');
  window.location = url;
}

function updateZipButton() {
  var checks = document.querySelectorAll('.mg-file-select:checked');
  var btn = document.getElementById('zip-btn');
  if (btn) btn.style.display = checks.length ? '' : 'none';
}

// SM019: honour ?path= first, fall back to #hash. The edit.md
// breadcrumb from SM018 links with ?path=, so this is what makes
// those breadcrumbs land in the right directory.
function readInitDir() {
  var qs = location.search;
  if (qs && qs.length > 1) {
    var params = qs.substr(1).split('&');
    for (var i = 0; i < params.length; i++) {
      var kv = params[i].split('=');
      if (kv[0] === 'path') {
        return decodeURIComponent(kv[1] || '') || '/';
      }
    }
  }
  var h = decodeURIComponent(location.hash.replace(/^#/, ''));
  return h || '/';
}

loadDir(readInitDir());
</script>
