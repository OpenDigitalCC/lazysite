---
title: Files
auth: manager
search: false
---

<div id="app">

<div id="status"></div>

<div class="mg-breadcrumb" id="breadcrumb"></div>

<div class="mg-file-filter-row">
<input type="search" id="file-filter" class="mg-file-filter" placeholder="Filter files..." oninput="applyFilters()">
<select id="type-filter" class="mg-file-typefilter" onchange="applyFilters()" title="Filter by file type">
<option value="">All types</option>
</select>
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
<th class="mg-col-name">Name</th>
<th class="mg-col-access">Access</th>
<th class="mg-col-mod">Modified</th>
<th class="mg-col-check"><input type="checkbox" id="select-all" title="Select all files and empty folders" onchange="toggleSelectAll(this)"></th>
<th class="mg-col-exp"></th>
</tr>
</thead>
<tbody id="file-rows">
<tr><td colspan="5">Loading...</td></tr>
</tbody>
</table>

</div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';
var currentDir = '/';
var PRINCIPALS = { users: [], groups: [] };   // SM077: assignable users + @groups

// SM019: must mirror %TEXT_EXTENSIONS in lazysite-manager-api.pl.
var TEXT_EXTENSIONS = {
  md: 1, txt: 1, html: 1, htm: 1, css: 1, js: 1,
  json: 1, jsonl: 1, xml: 1, yaml: 1, yml: 1,
  csv: 1, tsv: 1, conf: 1, ini: 1, log: 1,
  pl: 1, pm: 1, sh: 1, bash: 1, env: 1, example: 1, brief: 1
};

function isEditable(name) {
  var m = name.match(/\.([^.]+)$/);
  if (!m) return true;
  return TEXT_EXTENSIONS[m[1].toLowerCase()] ? true : false;
}

function joinPath(dir, name) {
  var d = String(dir || '').replace(/\/+$/, '');
  var n = String(name || '').replace(/^\/+/, '');
  return d + '/' + n;
}

function escHtml(s) {
  s = (s == null ? '' : String(s));
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
          .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
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

// SM077: fetch the assignable principals once (best-effort) for the pickers.
function loadPrincipals() {
  return fetch(API + '?action=principals')
    .then(function(r) { return r.json(); })
    .then(function(d) { if (d && d.ok) PRINCIPALS = { users: d.users || [], groups: d.groups || [] }; })
    .catch(function() { /* pickers fall back to the file's current entries */ });
}

function loadDir(dir) {
  showStatus('');
  currentDir = dir || '/';
  updateBreadcrumb();
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
  var items = [linkFn('/', 'Site root')];
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

function relativeTime(mtime) {
  var diff = Math.floor(Date.now() / 1000) - mtime;
  if (diff < 60)    return 'just now';
  if (diff < 3600)  return Math.floor(diff/60) + 'm ago';
  if (diff < 86400) return Math.floor(diff/3600) + 'h ago';
  return Math.floor(diff/86400) + 'd ago';
}

function absTime(mtime) {
  var d = new Date(mtime * 1000);
  function p(n) { return (n < 10 ? '0' : '') + n; }
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate())
       + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
}

// MODIFIED cell: relative shown, absolute on hover. (Audit history now lives
// in the config card, not on the date.)
function modifiedCell(f) {
  if (!f.mtime) return '';
  var when = '<span title="' + escHtml(absTime(f.mtime)) + '">' + escHtml(relativeTime(f.mtime)) + '</span>';
  // Size after the date (files only - directories have no meaningful size).
  if (f.type === 'file' && f.size != null) {
    when += ' <span class="mg-file-size">&middot; ' + escHtml(formatSize(f.size)) + '</span>';
  }
  return when;
}

// ACCESS cell: owner + colour-coded r / w (+ g when a @group is listed).
// A read/write list means access is RESTRICTED to it (red); no list = open
// within the account scope (green).
function accessBadge(f) {
  var rRestricted = f.read  && f.read.length;
  var wRestricted = f.write && f.write.length;
  var owner = f.owner
    ? '<span class="mg-owner-name" title="Owner">' + escHtml(f.owner) + '</span>'
    : '<span class="mg-rwflag-none" title="Unrestricted (account scope governs)">&mdash;</span>';
  var r = '<span class="mg-rwflag ' + (rRestricted ? 'mg-rwflag-no' : 'mg-rwflag-ok')
        + '" title="read ' + (rRestricted ? 'restricted to: ' + escHtml(f.read.join(', ')) : 'open') + '">r</span>';
  var w = '<span class="mg-rwflag ' + (wRestricted ? 'mg-rwflag-no' : 'mg-rwflag-ok')
        + '" title="write ' + (wRestricted ? 'restricted to: ' + escHtml(f.write.join(', ')) : 'open') + '">w</span>';
  var listed = (f.read || []).concat(f.write || []);
  var hasGroup = false;
  for (var i = 0; i < listed.length; i++) { if (/^@/.test(listed[i])) { hasGroup = true; break; } }
  var g = hasGroup ? ' <span class="mg-rwflag-g" title="a @group is granted access">g</span>' : '';
  return owner + g + ' ' + r + w;
}

function lockGlyph(f) {
  if (!f.lock) return '';
  var who = f.lock.origin === 'dav'
    ? 'locked via WebDAV'
    : 'locked by ' + (f.lock.locked_by || 'another user');
  return '<span class="mg-lock" title="' + escHtml(who) + '">&#128274;</span>';
}

// The "+ add" dropdown: every known principal (users + @groups).
function addOptions() {
  var all = [];
  (PRINCIPALS.users  || []).forEach(function(u) { all.push(u); });
  (PRINCIPALS.groups || []).forEach(function(g) { all.push('@' + g); });
  return all.sort().map(function(k) {
    return '<option value="' + escHtml(k) + '">' + escHtml(k) + '</option>';
  }).join('');
}

// One principal chip with r / w rights toggles and a remove control.
function chipHtml(name, r, w) {
  return '<span class="mg-chip" data-name="' + escHtml(name) + '">'
       + '<span class="mg-chip-name">' + escHtml(name) + '</span>'
       + '<button type="button" class="mg-chip-right ' + (r ? 'on' : 'off') + '" data-right="r" onclick="toggleRight(this)" title="read">r</button>'
       + '<button type="button" class="mg-chip-right ' + (w ? 'on' : 'off') + '" data-right="w" onclick="toggleRight(this)" title="write">w</button>'
       + '<button type="button" class="mg-chip-x" onclick="removeChip(this)" title="remove">&times;</button>'
       + '</span>';
}

// Initial chips for a file: the union of its read + write lists, each chip
// carrying which rights it holds.
function buildRights(f) {
  var read = {}, write = {}, order = [];
  (f.read  || []).forEach(function(p) { if (!read[p] && !write[p]) order.push(p); read[p] = 1; });
  (f.write || []).forEach(function(p) { if (!read[p] && !write[p]) order.push(p); write[p] = 1; });
  return order.map(function(p) { return chipHtml(p, read[p], write[p]); }).join('');
}

function toggleRight(btn) {
  var on = btn.className.indexOf('on') >= 0;
  btn.className = 'mg-chip-right ' + (on ? 'off' : 'on');
}

function removeChip(btn) {
  var chip = btn.parentNode;
  chip.parentNode.removeChild(chip);
}

// Add a principal from the dropdown (default: read on, write off).
function addPrincipal(sel) {
  var name = sel.value;
  if (!name) return;
  var rights = sel.parentNode.parentNode.querySelector('.mg-rights');
  var existing = rights.querySelector('.mg-chip[data-name="' + name.replace(/"/g, '\\"') + '"]');
  if (!existing) rights.insertAdjacentHTML('beforeend', chipHtml(name, 1, 0));
  sel.value = '';
}

function ownerOptions(owner) {
  var h = '<option value="">(unrestricted)</option>';
  var users = (PRINCIPALS.users || []).slice();
  if (owner && users.indexOf(owner) < 0) users.push(owner);
  users.sort().forEach(function(u) {
    h += '<option value="' + escHtml(u) + '"' + (u === owner ? ' selected' : '') + '>' + escHtml(u) + '</option>';
  });
  return h;
}

function briefButton(f) {
  if (f.is_brief) return '';
  if (f.has_brief) {
    return '<a class="mg-btn" href="/manager/edit?path=' + encodeURIComponent(f.path + '.brief') + '">&#128221; Edit brief</a>';
  }
  return '<button class="mg-btn" onclick="addBrief(this)">&#128221; Add brief</button>';
}

// The per-file config card (collapsed by default; one open at a time).
function permsCard(f) {
  return '<tr class="mg-perms-row" style="display:none"><td colspan="5" class="mg-perms-cell">'
    + '<div class="mg-perms-card">'
    +   '<div class="mg-perms-head">'
    +     '<span class="mg-perms-title">' + escHtml(f.name) + '</span>'
    +     '<a class="mg-perms-history" href="/manager/audit?target=' + encodeURIComponent(f.path) + '" title="This file\'s audit history">&#128340; History</a>'
    +   '</div>'
    +   '<div class="mg-perms-owner"><label>Owner</label>'
    +     '<select class="mg-perm-owner">' + ownerOptions(f.owner) + '</select></div>'
    +   '<div class="mg-perms-rights-label">People &amp; groups with access</div>'
    +   '<div class="mg-rights">' + buildRights(f) + '</div>'
    +   '<div class="mg-rights-add">'
    +     '<select class="mg-rights-pick" onchange="addPrincipal(this)">'
    +       '<option value="">+ add person or @group&hellip;</option>' + addOptions()
    +     '</select>'
    +   '</div>'
    +   '<div class="mg-perms-hint">Toggle <b>r</b> / <b>w</b> per person. Nobody listed = open within the account scope; no owner and nobody listed clears the ACL.</div>'
    +   '<div class="mg-perms-actions">'
    +     '<a class="mg-btn" href="' + API + '?action=file-download&path=' + encodeURIComponent(f.path) + '" download="' + escHtml(f.name) + '">&#11015; Download</a> '
    +     briefButton(f) + ' '
    +     '<button class="mg-btn" onclick="moveFile(this)">&#8644; Move&hellip;</button>'
    +     '<button class="mg-btn mg-btn-primary mg-perms-save" onclick="savePerms(this)">Save permissions</button>'
    +   '</div>'
    + '</div>'
    + '</td></tr>';
}

// SM077: clean row (icon + name on the left; Access / Modified / select /
// expander on the right). Advanced functions live in the expand card.
function renderFiles(files) {
  var tbody = document.getElementById('file-rows');
  if (!files.length) {
    tbody.innerHTML = '<tr><td colspan="5" style="color:var(--mg-text-light)">Empty directory</td></tr>';
    return;
  }
  files.sort(function(a, b) {
    if (a.type === 'dir' && b.type !== 'dir') return -1;
    if (a.type !== 'dir' && b.type === 'dir') return 1;
    return a.name.localeCompare(b.name);
  });
  var html = '';
  for (var i = 0; i < files.length; i++) {
    var f = files[i];
    var isDir = f.type === 'dir';
    var icon = isDir ? '&#128193;' : '&#128196;';
    html += '<tr data-name="' + escHtml(f.name) + '"'
          + ' data-path="' + escHtml(f.path || '') + '"'
          + ' data-ext="' + escHtml(f.ext || '') + '"'
          + ' data-kind="' + (isDir ? 'dir' : 'file') + '"'
          + ' data-generated="' + (f.generated ? '1' : '0') + '">';

    // NAME (left): icon + name only.
    var name;
    if (isDir) {
      name = '<a href="#" onclick="loadDir(\'' + escHtml(f.path) + '/\'); return false;">' + escHtml(f.name) + '/</a>';
    } else {
      name = isEditable(f.name)
        ? '<a href="/manager/edit?path=' + encodeURIComponent(f.path) + '">' + escHtml(f.name) + '</a>'
        : escHtml(f.name);
      if (f.is_brief) name += ' <span class="mg-brief-tag" title="Authoring brief (private, never served)">brief</span>';
    }
    html += '<td class="mg-file-name"><span class="mg-file-icon">' + icon + '</span> ' + name + '</td>';

    // ACCESS / MODIFIED.
    html += '<td class="mg-col-access">' + (isDir ? '' : accessBadge(f)) + '</td>';
    html += '<td class="mg-col-mod">' + modifiedCell(f) + '</td>';

    // SELECT (files + empty dirs).
    if (f.type === 'file' || (isDir && f.empty)) {
      html += '<td class="mg-col-check"><input type="checkbox" class="mg-file-select" data-kind="' + (isDir ? 'dir' : 'file') + '" value="' + escHtml(f.path) + '" onchange="updateSelection()"></td>';
    } else {
      html += '<td class="mg-col-check"></td>';
    }

    // EXPANDER (files): lock glyph + chevron.
    if (isDir) {
      html += '<td class="mg-col-exp"></td>';
    } else {
      html += '<td class="mg-col-exp">' + lockGlyph(f)
            + '<a href="#" class="mg-chev" onclick="togglePerms(this); return false;" title="File settings &amp; permissions">&#9662;</a></td>';
    }
    html += '</tr>';

    if (!isDir) html += permsCard(f);
  }
  tbody.innerHTML = html;
  populateTypeFilter(files);
}

// Expand/collapse the config card; only one open at a time.
function togglePerms(el) {
  var row = el.closest('tr');
  var card = row.nextElementSibling;
  if (!card || card.className.indexOf('mg-perms-row') < 0) return;
  var willOpen = card.style.display === 'none';
  var allCards = document.querySelectorAll('.mg-perms-row');
  for (var i = 0; i < allCards.length; i++) allCards[i].style.display = 'none';
  var allChev = document.querySelectorAll('.mg-chev');
  for (var j = 0; j < allChev.length; j++) { allChev[j].innerHTML = '&#9662;'; allChev[j].classList.remove('mg-chev-open'); }
  if (willOpen) { card.style.display = ''; el.innerHTML = '&#9652;'; el.classList.add('mg-chev-open'); }
}

function savePerms(btn) {
  var card = btn.closest('tr');
  var row  = card.previousElementSibling;
  var path = row.getAttribute('data-path');
  var owner = card.querySelector('.mg-perm-owner').value;

  // Derive read[] / write[] from the per-principal rights chips.
  var read = [], write = [];
  var chips = card.querySelectorAll('.mg-rights .mg-chip');
  for (var i = 0; i < chips.length; i++) {
    var name = chips[i].getAttribute('data-name');
    var rights = chips[i].querySelectorAll('.mg-chip-right.on');
    for (var j = 0; j < rights.length; j++) {
      if (rights[j].getAttribute('data-right') === 'r') read.push(name);
      if (rights[j].getAttribute('data-right') === 'w') write.push(name);
    }
  }

  var action, body;
  if (!owner && !read.length && !write.length) {
    action = 'acl-remove'; body = {};
  } else {
    action = 'acl-set'; body = { owner: owner, read: read, write: write };
  }
  fetch(API + '?action=' + action + '&path=' + encodeURIComponent(path), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  })
    .then(function(r) { return r.json(); })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error || 'Could not save permissions', true); return; }
      showStatus('Permissions updated.');
      loadDir(currentDir);
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

function moveFile(btn) {
  var card = btn.closest('tr');
  var row  = card.previousElementSibling;
  var path = row.getAttribute('data-path');
  mgPrompt('New path for this file:', path).then(function(dest) {
    if (!dest || dest === path) return;
    fetch(API + '?action=move&path=' + encodeURIComponent(path) + '&to=' + encodeURIComponent(dest), { method: 'POST' })
    .then(function(r) { return r.json(); })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error || 'Move failed', true); return; }
      showStatus('Moved to ' + dest + '.');
      loadDir(currentDir);
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
  });
}

function addBrief(btn) {
  var card = btn.closest('tr');
  var row  = card.previousElementSibling;
  createBrief(row.getAttribute('data-path'));
}

function populateTypeFilter(files) {
  var sel = document.getElementById('type-filter');
  if (!sel) return;
  var current = sel.value;
  var exts = {}, hasGen = false, hasDir = false;
  for (var i = 0; i < files.length; i++) {
    var f = files[i];
    if (f.type === 'dir') { hasDir = true; continue; }
    if (f.ext) exts[f.ext] = 1;
    if (f.generated) hasGen = true;
  }
  var opts = ['<option value="">All types</option>'];
  if (hasDir) opts.push('<option value="__dir">Folders</option>');
  if (hasGen) opts.push('<option value="__generated">Generated HTML</option>');
  var keys = Object.keys(exts).sort();
  for (var k = 0; k < keys.length; k++) {
    opts.push('<option value="' + escHtml(keys[k]) + '">.' + escHtml(keys[k]) + '</option>');
  }
  sel.innerHTML = opts.join('');
  sel.value = current;
  if (sel.value !== current) sel.value = '';
}

function createBrief(filePath) {
  var bpath = filePath + '.brief';
  var stem = filePath.split('/').pop();
  var tmpl = '# Brief - ' + stem + '\n\nintent: \n\n## Log\n\n- '
           + isoDate() + ' · created · · \n';
  fetch(API + '?action=save&path=' + encodeURIComponent(bpath), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ content: tmpl, mtime: null })
  })
    .then(function(r) { return r.json(); })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error || 'Could not create brief', true); return; }
      window.location = '/manager/edit?path=' + encodeURIComponent(bpath);
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

function isoDate() { return new Date().toISOString().slice(0, 10); }

// Combined text + type filter. Operates on file/dir rows (those carry
// data-name); config cards are kept collapsed so they never orphan.
function applyFilters() {
  var q = (document.getElementById('file-filter').value || '').toLowerCase();
  var type = (document.getElementById('type-filter') || {}).value || '';
  var cards = document.querySelectorAll('.mg-perms-row');
  for (var c = 0; c < cards.length; c++) cards[c].style.display = 'none';
  var chev = document.querySelectorAll('.mg-chev');
  for (var v = 0; v < chev.length; v++) chev[v].innerHTML = '&#9662;';
  var rows = document.querySelectorAll('.mg-file-table tbody tr[data-name]');
  for (var i = 0; i < rows.length; i++) {
    var row = rows[i];
    var name = (row.getAttribute('data-name') || '').toLowerCase();
    var okText = name.indexOf(q) >= 0;
    var okType = true;
    if (type === '__dir')            okType = row.getAttribute('data-kind') === 'dir';
    else if (type === '__generated') okType = row.getAttribute('data-generated') === '1';
    else if (type)                   okType = (row.getAttribute('data-ext') || '') === type;
    row.style.display = (okText && okType) ? '' : 'none';
  }
  updateSelection();
}

function formatSize(bytes) {
  if (bytes < 1024) return bytes + ' B';
  if (bytes < 1048576) return (bytes / 1024).toFixed(1) + ' KB';
  return (bytes / 1048576).toFixed(1) + ' MB';
}

function newFile() {
  mgPrompt('File name (e.g. page.md):', '').then(function(name) {
    if (!name) return;
    var path = joinPath(currentDir, name);
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
  });
}

function newFolder() {
  mgPrompt('Folder name:', '').then(function(name) {
    if (!name) return;
    var path = joinPath(currentDir, name).replace(/\/+$/, '');
    fetch(API + '?action=mkdir&path=' + encodeURIComponent(path), { method: 'POST' })
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      showStatus('Folder created.');
      loadDir(currentDir);
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
  });
}

function deleteSelected() {
  var checks = document.querySelectorAll(
    '.mg-file-table tbody tr:not([style*="display: none"]) .mg-file-select:checked');
  if (!checks.length) return;
  var paths = [];
  for (var i = 0; i < checks.length; i++) paths.push(checks[i].value);
  var msg = 'Delete ' + paths.length + ' item' + (paths.length === 1 ? '' : 's') + '?\n\n' + paths.join('\n');
  mgConfirm(msg, { danger: true, ok: 'Delete' }).then(function(__ok) {
  if (!__ok) return;
  var errors = [];
  if (typeof mgShowWarning === 'function') mgShowWarning('Deleting ' + paths.length + ' item(s)...', false);
  function step(i) {
    if (i >= paths.length) {
      if (typeof mgClearWarning === 'function') mgClearWarning();
      if (errors.length) showStatus('Some deletes failed: ' + errors.join('; '), true);
      else showStatus(paths.length + ' item(s) deleted.');
      loadDir(currentDir);
      return;
    }
    fetch(API + '?action=delete&path=' + encodeURIComponent(paths[i]), { method: 'POST' })
      .then(function(r) { return r.json(); })
      .then(function(data) {
        if (!data.ok) errors.push(paths[i] + ': ' + (data.error || 'unknown'));
        step(i + 1);
      })
      .catch(function(e) { errors.push(paths[i] + ': ' + e.message); step(i + 1); });
  }
  step(0);
  });
}

function triggerUpload() { document.getElementById('upload-input').click(); }

function uploadFiles(files) {
  if (!files || !files.length) return;
  var dir = currentDir;
  var total = files.length;
  if (typeof mgShowWarning === 'function') mgShowWarning('Uploading ' + total + ' file(s)...', false);
  var fd = new FormData();
  fd.append('overwrite', '0');
  for (var i = 0; i < files.length; i++) fd.append('file', files[i], files[i].name);
  var url = API + '?action=file-upload&path=' + encodeURIComponent(dir);
  fetch(url, { method: 'POST', body: fd })
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error || 'Upload failed', true); return; }
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
  mgConfirm(msg, { ok: 'Overwrite' }).then(function(__ok) {
  if (!__ok) { showStatus('Upload cancelled for ' + skipped.length + ' file(s).'); loadDir(dir); return; }
  var skipSet = {};
  for (var i = 0; i < skipped.length; i++) skipSet[skipped[i]] = true;
  var toRetry = [];
  for (var j = 0; j < files.length; j++) if (skipSet[files[j].name]) toRetry.push(files[j]);
  var fd = new FormData();
  fd.append('overwrite', '1');
  for (var k = 0; k < toRetry.length; k++) fd.append('file', toRetry[k], toRetry[k].name);
  fetch(API + '?action=file-upload&path=' + encodeURIComponent(dir), { method: 'POST', body: fd })
    .then(function(r) { return r.json(); })
    .then(function() { if (typeof mgClearWarning === 'function') mgClearWarning(); loadDir(dir); })
    .catch(function(e) { showStatus('Overwrite error: ' + e.message, true); });
  });
}

function zipSelected() {
  var checks = document.querySelectorAll(
    '.mg-file-table tbody tr:not([style*="display: none"]) .mg-file-select:checked');
  var qs = [];
  for (var i = 0; i < checks.length; i++) {
    if (checks[i].getAttribute('data-kind') === 'file') qs.push('paths=' + encodeURIComponent(checks[i].value));
  }
  if (!qs.length) return;
  window.location = API + '?action=file-zip-download&' + qs.join('&');
}

function visibleFileChecks() {
  return document.querySelectorAll(
    '.mg-file-table tbody tr:not([style*="display: none"]) .mg-file-select');
}

function toggleSelectAll(src) {
  var checks = visibleFileChecks();
  for (var i = 0; i < checks.length; i++) checks[i].checked = src.checked;
  updateSelection();
}

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
    if (checkedAll.length === 0) { sa.checked = false; sa.indeterminate = false; }
    else if (checkedAll.length === allChecks.length) { sa.checked = true; sa.indeterminate = false; }
    else { sa.checked = false; sa.indeterminate = true; }
  }
}

function readInitDir() {
  var qs = location.search;
  if (qs && qs.length > 1) {
    var params = qs.substr(1).split('&');
    for (var i = 0; i < params.length; i++) {
      var kv = params[i].split('=');
      if (kv[0] === 'path') return decodeURIComponent(kv[1] || '') || '/';
    }
  }
  var h = decodeURIComponent(location.hash.replace(/^#/, ''));
  return h || '/';
}

loadPrincipals().then(function() { loadDir(readInitDir()); });
</script>
