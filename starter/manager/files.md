---
title: Files
auth: manager
search: false
---

<div id="app">

<div id="status"></div>

<div class="mg-breadcrumb" id="breadcrumb"></div>

<div class="mg-file-filter-row">
<input type="search" id="file-filter" class="mg-file-filter" placeholder="Filter files..." oninput="filterFiles(this.value)">
</div>

<div class="mg-file-actions-row">
<div class="mg-file-actions-left">
<button class="mg-btn" onclick="newFile()">Add File</button>
<button class="mg-btn" onclick="newFolder()">Add Folder</button>
<input type="file" id="upload-input" multiple style="display:none" onchange="uploadFiles(this.files)">
<button class="mg-btn" onclick="triggerUpload()">Upload</button>
</div>
<div class="mg-file-actions-right">
<button class="mg-btn" id="zip-btn" style="display:none" onclick="zipSelected()">Download selected</button>
<button class="mg-btn mg-btn-danger" id="del-btn" style="display:none" onclick="deleteSelected()">Delete selected</button>
</div>
</div>

<table class="mg-file-table">
<thead>
<tr>
<th class="mg-col-check"><input type="checkbox" id="select-all" title="Select all files and empty folders" onchange="toggleSelectAll(this)"></th>
<th class="mg-col-icon"></th>
<th class="mg-col-name">Name</th>
<th class="mg-col-size">Size</th>
<th class="mg-col-age">Modified</th>
<th class="mg-col-dl"></th>
</tr>
</thead>
<tbody id="file-rows">
<tr><td></td><td></td><td>Loading...</td><td></td><td></td><td></td></tr>
</tbody>
</table>

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
  // SM019b: directory navigation resets the Select-all state so
  // it cannot leak stale "checked" across directories. Row
  // checkboxes are re-rendered below, so they reset naturally.
  var sa = document.getElementById('select-all');
  if (sa) { sa.checked = false; sa.indeterminate = false; }
  fetch(API + '?action=list&path=' + encodeURIComponent(currentDir))
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      renderFiles(data.entries || []);
      updateSelection();
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

// SM019b: renders rows into the #file-rows tbody. Every row has
// the same six cells so columns align; empty cells are used where
// a row type has no content (directory with no download link,
// non-empty dir with no checkbox, etc).
function renderFiles(files) {
  var tbody = document.getElementById('file-rows');
  if (!files.length) {
    tbody.innerHTML = '<tr><td></td><td></td><td style="color:var(--mg-text-light)">Empty directory</td><td></td><td></td><td></td></tr>';
    return;
  }
  // Directories first, then files; each group alphabetical.
  files.sort(function(a, b) {
    if (a.type === 'dir' && b.type !== 'dir') return -1;
    if (a.type !== 'dir' && b.type === 'dir') return 1;
    return a.name.localeCompare(b.name);
  });
  var html = '';
  for (var i = 0; i < files.length; i++) {
    var f = files[i];
    var icon = f.type === 'dir' ? '&#128193;' : '&#128196;';
    html += '<tr data-name="' + escHtml(f.name) + '">';

    // Checkbox cell: empty dirs get one, files get one, non-empty
    // dirs get an empty cell for alignment.
    if (f.type === 'file') {
      html += '<td><input type="checkbox" class="mg-file-select" data-kind="file" value="' + escHtml(f.path) + '" onchange="updateSelection()"></td>';
    } else if (f.type === 'dir' && f.empty) {
      html += '<td><input type="checkbox" class="mg-file-select" data-kind="dir" value="' + escHtml(f.path) + '" onchange="updateSelection()"></td>';
    } else {
      html += '<td></td>';
    }

    html += '<td class="mg-file-icon">' + icon + '</td>';

    if (f.type === 'dir') {
      html += '<td class="mg-file-name"><a href="#" onclick="loadDir(\'' + escHtml(f.path) + '/\'); return false;">' + escHtml(f.name) + '/</a></td>';
    } else if (isEditable(f.name)) {
      html += '<td class="mg-file-name"><a href="/manager/edit?path=' + encodeURIComponent(f.path) + '">' + escHtml(f.name) + '</a></td>';
    } else {
      html += '<td class="mg-file-name">' + escHtml(f.name) + '</td>';
    }

    html += '<td class="mg-col-size">' + formatSize(f.size || 0) + '</td>';
    html += '<td class="mg-col-age">' + (f.mtime ? relativeTime(f.mtime) : '') + '</td>';

    if (f.type === 'file') {
      html += '<td class="mg-file-dl"><a href="' + API + '?action=file-download&path=' + encodeURIComponent(f.path) + '" download="' + escHtml(f.name) + '" title="Download">&darr;</a></td>';
    } else {
      html += '<td></td>';
    }

    html += '</tr>';
  }
  tbody.innerHTML = html;
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
  var rows = document.querySelectorAll('.mg-file-table tbody tr');
  query = query.toLowerCase();
  for (var i = 0; i < rows.length; i++) {
    var name = rows[i].getAttribute('data-name') || '';
    rows[i].style.display = name.toLowerCase().indexOf(query) >= 0 ? '' : 'none';
  }
  // SM019a/b: visible set changed, so Select-all / action buttons
  // need to re-derive against the new set. Existing selections
  // are preserved (subset-building workflow).
  updateSelection();
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

// SM019b: uses the new action=mkdir so the resulting directory
// has no hidden .gitkeep inside. That keeps the "empty dirs are
// deletable" semantics honest: a freshly-created folder is
// genuinely empty and gets a selection checkbox on refresh.
function newFolder() {
  var name = prompt('Folder name:');
  if (!name) return;
  var path = currentDir + name;
  path = path.replace(/\/+$/, '');
  fetch(API + '?action=mkdir&path=' + encodeURIComponent(path), {
    method: 'POST'
  })
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      showStatus('Folder created.');
      loadDir(currentDir);
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

// SM019b: batch delete. Runs requests sequentially so the error
// list is meaningful if only some succeed. Matches the
// uploadFiles progress-warning / final-status pattern.
function deleteSelected() {
  var checks = document.querySelectorAll(
    '.mg-file-table tbody tr:not([style*="display: none"]) '
  + '.mg-file-select:checked');
  if (!checks.length) return;

  var paths = [];
  for (var i = 0; i < checks.length; i++) paths.push(checks[i].value);

  var msg = 'Delete ' + paths.length + ' item'
          + (paths.length === 1 ? '' : 's') + '?\n\n'
          + paths.join('\n');
  if (!confirm(msg)) return;

  var errors = [];
  if (typeof mgShowWarning === 'function') {
    mgShowWarning('Deleting ' + paths.length + ' item(s)...', false);
  }

  function step(i) {
    if (i >= paths.length) {
      if (typeof mgClearWarning === 'function') mgClearWarning();
      if (errors.length) {
        showStatus('Some deletes failed: ' + errors.join('; '), true);
      } else {
        showStatus(paths.length + ' item(s) deleted.');
      }
      loadDir(currentDir);
      return;
    }
    fetch(API + '?action=delete&path=' + encodeURIComponent(paths[i]),
          { method: 'POST' })
      .then(function(r) { return r.json(); })
      .then(function(data) {
        if (!data.ok) {
          errors.push(paths[i] + ': ' + (data.error || 'unknown'));
        }
        step(i + 1);
      })
      .catch(function(e) {
        errors.push(paths[i] + ': ' + e.message);
        step(i + 1);
      });
  }
  step(0);
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

// Zip-download excludes empty-directory selections: the zip
// action validates paths as files server-side and would skip
// them anyway, but filtering here avoids a warn-log per dir.
function zipSelected() {
  var checks = document.querySelectorAll(
    '.mg-file-table tbody tr:not([style*="display: none"]) '
  + '.mg-file-select:checked');
  var qs = [];
  for (var i = 0; i < checks.length; i++) {
    if (checks[i].getAttribute('data-kind') === 'file') {
      qs.push('paths=' + encodeURIComponent(checks[i].value));
    }
  }
  if (!qs.length) return;
  var url = API + '?action=file-zip-download&' + qs.join('&');
  window.location = url;
}

// SM019b: the "visible" selector targets the table body and
// keys off inline display:none set by filterFiles. If
// filterFiles is refactored to use a CSS class, this selector
// needs to change too.
function visibleFileChecks() {
  return document.querySelectorAll(
    '.mg-file-table tbody tr:not([style*="display: none"]) '
  + '.mg-file-select');
}

function toggleSelectAll(src) {
  var checks = visibleFileChecks();
  for (var i = 0; i < checks.length; i++) {
    checks[i].checked = src.checked;
  }
  updateSelection();
}

// Drives both action buttons (Download-selected, Delete-selected)
// and reconciles the Select-all checkbox's three states.
function updateSelection() {
  var allChecks = visibleFileChecks();
  var checkedAll = [];
  var checkedFiles = 0;
  for (var i = 0; i < allChecks.length; i++) {
    if (allChecks[i].checked) {
      checkedAll.push(allChecks[i]);
      if (allChecks[i].getAttribute('data-kind') === 'file') checkedFiles++;
    }
  }

  var zipBtn = document.getElementById('zip-btn');
  if (zipBtn) zipBtn.style.display = checkedFiles ? '' : 'none';

  var delBtn = document.getElementById('del-btn');
  if (delBtn) delBtn.style.display = checkedAll.length ? '' : 'none';

  var sa = document.getElementById('select-all');
  if (sa) {
    if (checkedAll.length === 0) {
      sa.checked = false;
      sa.indeterminate = false;
    } else if (checkedAll.length === allChecks.length) {
      sa.checked = true;
      sa.indeterminate = false;
    } else {
      sa.checked = false;
      sa.indeterminate = true;
    }
  }
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
