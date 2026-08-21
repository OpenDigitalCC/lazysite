---
title: Files
auth: manager
search: false
---

<div id="app">

<div id="status"></div>

<div id="scope-switcher" style="display:none;margin:0 0 8px;"></div>

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
<button class="mg-btn" id="hist-overview-btn" style="display:none" onclick="openHistoryOverview()" title="All files under content history, with per-file revision statistics">&#128337; History overview</button>
<button class="mg-btn" id="zip-btn" style="display:none" onclick="zipSelected()">Download selected</button>
<button class="mg-btn mg-btn-danger" id="del-btn" style="display:none" onclick="deleteSelected()">Delete selected</button>
</div>

<div id="hist-overview" class="mg-git-overview" style="display:none">
<div class="mg-card-header"><span class="mg-card-title">Content history &mdash; all files</span>
<button class="mg-btn mg-btn-sm" onclick="closeHistoryOverview()">Close</button></div>
<div id="hist-overview-body" class="mg-card-body"><p class="mg-muted">Loading&hellip;</p></div>
</div>
</div>

<table class="mg-file-table">
<thead>
<tr>
<th class="mg-col-name mg-sortable" onclick="setSort('name')">Name <span class="mg-sort-ind" data-col="name"></span></th>
<th class="mg-col-access mg-sortable" onclick="setSort('access')">Access <span class="mg-sort-ind" data-col="access"></span></th>
<th class="mg-col-mod mg-sortable" onclick="setSort('mod')">Modified <span class="mg-sort-ind" data-col="mod"></span></th>
<th class="mg-col-check"><input type="checkbox" id="select-all" title="Select all files and empty folders" onchange="toggleSelectAll(this)"></th>
<th class="mg-col-exp"></th>
</tr>
</thead>
<tbody id="file-rows">
<tr><td colspan="5">Loading...</td></tr>
</tbody>
</table>
<div id="file-pager" class="mg-pager"></div>

<div class="mg-card" id="protected-card">
<div class="mg-card-header"><span class="mg-card-title">Protected sections</span>
<button class="mg-btn mg-btn-sm" onclick="loadProtectedSections()">Refresh</button></div>
<div class="mg-card-body">
<p class="mg-muted">Whole folders held back from the public. A <b>gated</b> section is
visible only to the people named on it; a <b>draft</b> section does not exist as far as
a visitor is concerned - it returns 404 and stays out of the sitemap, the feeds and
every listing, while a signed-in editor can still preview it.</p>
<table class="mg-file-table" id="protected-table" style="display:none">
<thead><tr><th>Section</th><th>Policy</th><th>Readable by</th><th>Contents</th><th></th></tr></thead>
<tbody id="protected-rows"></tbody>
</table>
<p class="mg-muted" id="protected-empty" style="display:none">Nothing is held back &mdash;
every folder on this site is public.</p>
</div>
</div>

<div class="mg-card" id="aliases-card">
<div class="mg-card-header"><span class="mg-card-title">Aliases</span>
<button class="mg-btn mg-btn-sm" onclick="loadAliases()">Refresh</button></div>
<div class="mg-card-body">
<p class="mg-muted">Alternate URLs that redirect to a page. Aliases are authored in each
page's front matter (<code>aliases:</code> for permanent 301 redirects,
<code>aliases_temp:</code> for temporary 302s) - this list is read-only.</p>
<table class="mg-file-table" id="alias-table" style="display:none">
<thead><tr><th>Alias</th><th>Redirects to</th><th>Type</th></tr></thead>
<tbody id="alias-rows"></tbody>
</table>
<p class="mg-muted" id="alias-empty" style="display:none">No aliases are defined yet.</p>
</div>
</div>

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
    .then(function(d) {
      if (!d || !d.ok) return;
      PRINCIPALS = { users: d.users || [], groups: d.groups || [] };
      // SM305: hand the same lists to the shared picker, so every control on
      // this page that names a principal is built from one source.
      if (window.mgSetPrincipals) mgSetPrincipals(PRINCIPALS.users, PRINCIPALS.groups);
    })
    .catch(function() { /* pickers fall back to the file's current entries */ });
}

function loadDir(dir) {
  showStatus('');
  currentDir = dir || '/';
  updateBreadcrumb();
  // The alias card is scoped to the folder, so it has to follow navigation.
  // It used to load once at page load and never again, which meant that after
  // the first click it described somewhere the operator had left.
  if (typeof loadAliases === 'function') loadAliases();
  var sa = document.getElementById('select-all');
  if (sa) { sa.checked = false; sa.indeterminate = false; }
  // SM103: recent-change markers - fetch what changed lately, then render.
  fetch(API + '?action=recent-changes')
    .then(function(r) { return r.json(); })
    .then(function(rc) { recentChanges = (rc && rc.ok && rc.changes) || {}; },
          function() { recentChanges = {}; })
    .then(function() {
      return fetch(API + '?action=list&path=' + encodeURIComponent(currentDir))
        .then(function(r) { return r.json(); })
        .then(function(data) {
          if (!data.ok) { showStatus(data.error, true); return; }
          renderFiles(data.entries || []);
          updateSelection();
        });
    })
    .catch(function(e) { showStatus('Failed to load directory: ' + e.message, true); });
}

// SM103: a small dot next to a row changed within the recent-changes window.
var recentChanges = {};
function recentDot(key) {
  var c = recentChanges[key];
  if (!c) return '';
  var when = c.ts ? new Date(c.ts).toLocaleString() : '';
  var title = 'Changed ' + when + (c.user ? ' by ' + c.user : '')
            + (c.action ? ' (' + c.action + ')' : '');
  return '<span class="mg-recent-dot" title="' + escHtml(title) + '" aria-label="'
       + escHtml(title) + '" style="display:inline-block;width:8px;height:8px;'
       + 'border-radius:50%;background:var(--mg-accent,#3a7bd5);margin-left:6px;'
       + 'vertical-align:middle;"></span>';
}

function buildBreadcrumb(dirPath, linkFn) {
  // SM154 (P3): for a domain-bound editor, the breadcrumb starts at their own
  // content root (they cannot go above it), so strip the scope prefix and label
  // the root icon with the domain rather than the site root.
  var root = scopeRoot();
  var full = '/' + dirPath.replace(/^\/+|\/+$/g, '');
  var accumulated, rest, rootTitle;
  if (root !== '/' && (full + '/').indexOf(root) === 0) {
    accumulated = root.replace(/\/+$/, '');
    rest = full.substr(accumulated.length).replace(/^\/+|\/+$/g, '');
    rootTitle = window.LAZYSITE_HOME_DOMAIN || 'Your site';
  } else {
    accumulated = '';
    rest = dirPath.replace(/^\/+|\/+$/g, '');
    rootTitle = 'Site root';
  }
  var items = [linkFn((accumulated || '') + '/',
    '<span class="mg-bc-root" title="' + escHtml(rootTitle) + '">&#128193;</span>', true)];
  var parts = rest.split('/').filter(Boolean);
  for (var i = 0; i < parts.length; i++) {
    accumulated += '/' + parts[i];
    items.push(linkFn(accumulated + '/', parts[i]));
  }
  return items.join(' &rsaquo; ');
}

function updateBreadcrumb() {
  // SEC-2026-07 (H5): path and a SEGMENT label are attacker-controllable (a
  // directory can be named with an XSS payload via mkdir). JSON.stringify(path)
  // yields a valid JS string literal; escHtml then makes it safe inside the
  // double-quoted HTML attribute (the browser decodes the entities back before
  // the JS engine parses it). A segment label is HTML-escaped for its text-node
  // context. The ROOT item's label (rawLabel=true) is trusted icon HTML built
  // above (its only dynamic part, the title, is already escaped there), so it is
  // passed through un-escaped - else the folder icon shows as raw <span> markup.
  var html = buildBreadcrumb(currentDir, function(path, label, rawLabel) {
    var text = rawLabel ? label : escHtml(label);
    return '<a href="#" onclick="loadDir(' + escHtml(JSON.stringify(path)) + '); return false;">' + text + '</a>';
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
// SM305: one implementation, in the shared layout script. Kept as a named
// wrapper because the per-file card builds its markup as a string and reads
// better for it.
function addOptions() {
  return window.mgPrincipalOptions ? mgPrincipalOptions({ groupPrefix: '@' }) : '';
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

// SM305: the section sheet's variant. Same picker, same chips, but no r/w
// toggles - "Protect this section" grants read and write together (it posts one
// list as both), so offering per-right toggles here would show a distinction
// the action does not make.
function nameChipHtml(name) {
  return '<span class="mg-chip" data-name="' + escHtml(name) + '">'
       + '<span class="mg-chip-name">' + escHtml(name) + '</span>'
       + '<button type="button" class="mg-chip-x" onclick="removeChip(this)" title="remove">&times;</button>'
       + '</span>';
}

function addSectionPrincipal(sel) {
  var name = sel.value;
  if (!name) return;
  var card = sel.closest('.mg-perms-card');
  var list = card && card.querySelector('.mg-sec-read');
  if (!list) return;
  if (!list.querySelector('.mg-chip[data-name="' + name.replace(/"/g, '\\"') + '"]')) {
    list.insertAdjacentHTML('beforeend', nameChipHtml(name));
  }
  sel.value = '';
}

// The names currently on a chip list, in the order they were added.
function chipNames(container) {
  if (!container) return [];
  return Array.prototype.map.call(
    container.querySelectorAll('.mg-chip'),
    function(c) { return c.getAttribute('data-name'); });
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

// Protection, shown where the folder is rather than only at the foot of the
// page. The "Protected sections" card still lists everything - it answers a
// different question - but an operator standing on a folder should be able to
// see its protection in the folder's own expansion.
var PROTECTED_BY_PREFIX = {};
var SITE_WIDE_RULE = null;

// The section rule covering a listing row, or null. Prefixes are
// docroot-relative without a leading slash; row paths carry one.
function protectionFor(f) {
  if (!f || f.type !== 'dir') return null;
  var rel = String(f.path || '').replace(/^\/+/, '');
  return PROTECTED_BY_PREFIX[rel] || null;
}

function protectionBlock(f) {
  var s = protectionFor(f);
  if (!s) {
    // Say nothing for an unprotected folder EXCEPT where a site-wide rule
    // covers it - otherwise the expansion would imply "open" on a site where
    // everything is gated, which is the wrong answer confidently given.
    if (!SITE_WIDE_RULE) return '';
    return '<div class="mg-perms-hint" style="margin-top:8px;">'
      + 'Covered by the site-wide rule (' + escHtml(SITE_WIDE_RULE.policy) + ') '
      + '- every page and asset on this site is held back.</div>';
  }
  var draft = s.policy === 'draft';
  var badge = draft
    ? '<span class="mg-alias-badge mg-alias-302" title="Hidden outright: 404 to the public, absent from the sitemap, feeds and every listing.">draft</span>'
    : '<span class="mg-alias-badge" title="Visible only to the people named in the read list; everyone else is sent to sign in.">gated</span>';
  var who = (s.read && s.read.length)
    ? escHtml(s.read.join(', '))
    : '<span class="mg-muted">nobody but the owner</span>';
  var contents = s.exists
    ? (s.pages + ' page' + (s.pages === 1 ? '' : 's')
       + (s.assets ? ', ' + s.assets + ' asset' + (s.assets === 1 ? '' : 's') : ''))
    : '<span class="mg-cap-dormant" title="The rule still gates this path, but there is no such folder.">no such folder</span>';
  return '<div class="mg-perms-rights-label" style="margin-top:10px;">Protection</div>'
    + '<div class="mg-perms-hint">' + badge
    + ' &middot; readable by ' + who
    + ' &middot; ' + contents
    + ( draft
        ? ' &middot; hidden outright: a visitor gets 404, and it is absent from the sitemap, feeds and every listing.'
        : ' &middot; a visitor who is not listed is sent to sign in.' )
    + '</div>';
}

// The per-file config card (collapsed by default; one open at a time).
function permsCard(f) {
  return '<tr class="mg-perms-row" style="display:none"><td colspan="5" class="mg-perms-cell">'
    + '<div class="mg-perms-card">'
    +   '<div class="mg-perms-head">'
    +     '<span class="mg-perms-title">' + escHtml(f.name) + '</span>'
    +     '<a class="mg-perms-history" href="/manager/audit?target=' + encodeURIComponent(f.path) + '" title="This file\'s audit history">&#128340; Audit</a>'
    +   '</div>'
    +   '<div class="mg-perms-owner"><label>Owner</label>'
    +     '<select class="mg-perm-owner">' + ownerOptions(f.owner) + '</select></div>'
    +   protectionBlock(f)
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
    +     '<button class="mg-btn" onclick="duplicateFile(this)">&#10697; Duplicate&hellip;</button>'
    +     ( /\.url$/.test(f.name) ? '<button class="mg-btn" onclick="migrateToLocal(this)">&#11015; Migrate to local</button>' : '' )
    +     ( GIT.enabled && isEditable(f.name) ? '<button class="mg-btn" onclick="toggleHistory(this)">&#128337; History</button>' : '' )
    +     '<button class="mg-btn mg-btn-danger" onclick="deleteOneFile(this)">&#128465; Delete</button>'
    +     '<button class="mg-btn mg-btn-primary mg-perms-save" onclick="savePerms(this)">Save permissions</button>'
    +   '</div>'
    +   '<div class="mg-git-panel" data-path="' + escHtml(f.path) + '" style="display:none;margin-top:10px;"></div>'
    + '</div>'
    + '</td></tr>';
}

// SM077: clean row (icon + name on the left; Access / Modified / select /
// expander on the right). Advanced functions live in the expand card.
// SM111: data-driven render so sort + filter + pagination compose.
var currentFiles = [];
var fileSort = { col: 'name', dir: 1 };
var filePage = 0;
var FILE_PAGE_SIZE = 50;

function renderFiles(files) {
  currentFiles = files || [];
  filePage = 0;
  populateTypeFilter(currentFiles);
  paintFiles();
}

// Unrestricted (0) sorts before restricted (1).
function accessRank(f) {
  return ((f.read && f.read.length) || (f.write && f.write.length)) ? 1 : 0;
}

function filteredSortedFiles() {
  var q = (document.getElementById('file-filter').value || '').toLowerCase();
  var type = (document.getElementById('type-filter') || {}).value || '';
  var list = currentFiles.filter(function(f) {
    if ((f.name || '').toLowerCase().indexOf(q) < 0) return false;
    if (type === '__dir')       return f.type === 'dir';
    if (type === '__generated') return !!f.generated;
    if (type)                   return (f.ext || '') === type;
    return true;
  });
  var col = fileSort.col, dir = fileSort.dir;
  list.sort(function(a, b) {
    if (a.type === 'dir' && b.type !== 'dir') return -1;   // dirs always first
    if (a.type !== 'dir' && b.type === 'dir') return 1;
    var c;
    if (col === 'mod')         c = (a.mtime || 0) - (b.mtime || 0);
    else if (col === 'access') c = accessRank(a) - accessRank(b);
    else                       c = a.name.localeCompare(b.name);
    if (c !== 0) return c * dir;
    return a.name.localeCompare(b.name);                   // stable name tiebreak
  });
  return list;
}

function paintFiles() {
  var tbody = document.getElementById('file-rows');
  var list = filteredSortedFiles();
  updateSortIndicators();
  if (!list.length) {
    tbody.innerHTML = '<tr><td colspan="5" style="color:var(--mg-text-light)">No matching files</td></tr>';
    renderPager(0, 0);
    updateSelection();
    return;
  }
  var pages = Math.max(1, Math.ceil(list.length / FILE_PAGE_SIZE));
  if (filePage >= pages) filePage = pages - 1;
  if (filePage < 0) filePage = 0;
  var start = filePage * FILE_PAGE_SIZE;
  var pageItems = list.slice(start, start + FILE_PAGE_SIZE);
  var html = '';
  for (var i = 0; i < pageItems.length; i++) html += rowHtml(pageItems[i]);
  tbody.innerHTML = html;
  renderPager(list.length, pages);
  updateSelection();
}

function rowHtml(f) {
  var isDir = f.type === 'dir';
  var icon = isDir ? '&#128193;' : '&#128196;';
  var html = '<tr data-name="' + escHtml(f.name) + '"'
        + ' data-path="' + escHtml(f.path || '') + '"'
        + ' data-ext="' + escHtml(f.ext || '') + '"'
        + ' data-kind="' + (isDir ? 'dir' : 'file') + '"'
        + ' data-generated="' + (f.generated ? '1' : '0') + '">';
  var name;
  if (isDir) {
    name = '<a href="#" onclick="loadDir(\'' + escHtml(f.path) + '/\'); return false;">' + escHtml(f.name) + '/</a>';
  } else {
    name = isEditable(f.name)
      ? '<a href="/manager/edit?path=' + encodeURIComponent(f.path) + '">' + escHtml(f.name) + '</a>'
      : escHtml(f.name);
    if (f.is_brief) name += ' <span class="mg-brief-tag" title="Authoring brief (private, never served)">brief</span>';
  }
  html += '<td class="mg-file-name"><span class="mg-file-icon">' + icon + '</span> ' + name + recentDot(f.path) + '</td>';
  html += '<td class="mg-col-access">' + (isDir ? '' : accessBadge(f)) + '</td>';
  html += '<td class="mg-col-mod">' + modifiedCell(f) + '</td>';
  if (f.type === 'file' || (isDir && f.empty)) {
    html += '<td class="mg-col-check"><input type="checkbox" class="mg-file-select" data-kind="' + (isDir ? 'dir' : 'file') + '" value="' + escHtml(f.path) + '" onchange="updateSelection()"></td>';
  } else {
    html += '<td class="mg-col-check"></td>';
  }
  if (isDir) {
    // SM162: folders get an actions dropdown too (rename/move, delete) - the
    // subset that applies to a directory (no per-file ACL / history / download).
    html += '<td class="mg-col-exp"><a href="#" class="mg-chev" onclick="togglePerms(this); return false;" title="Folder actions">&#9662;</a></td>';
  } else {
    html += '<td class="mg-col-exp">' + lockGlyph(f)
          + '<a href="#" class="mg-chev" onclick="togglePerms(this); return false;" title="File settings &amp; permissions">&#9662;</a></td>';
  }
  html += '</tr>';
  html += isDir ? folderCard(f) : permsCard(f);
  return html;
}

// SM162: the folder actions card - a hidden row (toggled by the folder's chevron)
// mirroring permsCard's shape so moveFile / deleteOneFile find the folder row via
// closest('tr').previousElementSibling. Only the folder-applicable actions:
// Rename/Move (a path move) and Delete (the server removes an EMPTY directory and
// reports a clear error for a non-empty one). No ACL editor, history, or download
// - those are file concepts.
function folderCard(f) {
  // SM267: a folder can be PROTECTED from here. Until this existed the panel
  // below could list and publish protected sections and there was no way to
  // create one - the store was reachable only by hand-editing acls.json, which
  // is the gap SM181 named and SM267 was carved out to close. Listing something
  // an operator cannot create is half a feature.
  var p = escHtml(f.path);
  return '<tr class="mg-perms-row" style="display:none"><td colspan="5" class="mg-perms-cell">'
    + '<div class="mg-perms-card">'
    +   '<div class="mg-perms-head"><span class="mg-perms-title">' + escHtml(f.name) + '/</span></div>'
    +   '<div class="mg-perms-hint">Folder actions. Delete removes an <b>empty</b> folder; empty its contents first otherwise.</div>'
    +   '<div class="mg-perms-actions">'
    +     '<button class="mg-btn" onclick="moveFile(this)">&#8644; Rename / Move&hellip;</button> '
    +     '<button class="mg-btn mg-btn-danger" onclick="deleteOneFile(this)">&#128465; Delete</button>'
    +   '</div>'
    +   '<div class="mg-perms-hint" style="margin-top:0.7em"><b>Protect this section</b> &mdash; '
    +     'applies to every page and asset under <code>' + p + '/</code>.</div>'
    +   '<div class="mg-perms-actions">'
    +     '<label><input type="radio" name="pol-' + p + '" value="gated" checked> '
    +       '<b>Gated</b> &mdash; only the people named below can see it; everyone else is asked to sign in</label><br>'
    +     '<label><input type="radio" name="pol-' + p + '" value="draft"> '
    +       '<b>Draft</b> &mdash; hidden completely: 404 to the public, and absent from the sitemap, feeds and search</label>'
    +   '</div>'
    +   '<div class="mg-form-row"><label>Who may read it</label>'
    // SM305: the same picker the per-file card uses. This was a bare text box
    // taking a comma-separated list, which is the one control on the page that
    // accepted a name nobody had - and it governed who may read protected
    // content, so a typo silently granted the section to nobody and reported
    // success. Named principals become chips; the empty list still means
    // "nobody but you", which the hint below states.
    +     '<div class="mg-rights mg-sec-read"></div></div>'
    +   '<div class="mg-rights-add">'
    +     mgPrincipalSelect({ onchange: 'addSectionPrincipal(this)',
                              placeholder: '+ add person or @group…',
                              style: 'max-width:18rem' })
    +   '</div>'
    +   '<div class="mg-perms-hint">Nobody listed means nobody but you.</div>'
    +   '<div class="mg-perms-actions">'
    +     '<button class="mg-btn mg-btn-primary" onclick="protectSection(this, \'' + p + '\')">Protect this section</button>'
    +   '</div>'
    + '</div>'
    + '</td></tr>';
}

// SM267: write the folder ACL that gates or hides a whole section. Uses the same
// acl-set the per-file editor uses - one writer, so a section and a file are
// governed by the same store and the same rules.
function protectSection(btn, path) {
  var card  = btn.closest('.mg-perms-card');
  var pol   = card.querySelector('input[name="pol-' + path + '"]:checked');
  var read  = card.querySelector('.mg-sec-read');
  var draft = pol && pol.value === 'draft';
  // SM305: the names come off the chips now, not a comma-separated text box.
  // Every one of them was chosen from the picker, so each is a principal the
  // site knows - the previous control accepted anything typed, and a mistyped
  // name granted the section to nobody while reporting success.
  var who   = chipNames(read).join(', ');

  var msg = draft
    ? 'Hide "' + path + '/" completely?\n\nEvery page and asset under it will '
      + 'return 404 to the public and disappear from the sitemap, the feeds and '
      + 'search. Signed-in editors can still see it.'
    : 'Restrict "' + path + '/" to ' + (who || 'you alone') + '?\n\nEveryone else '
      + 'is asked to sign in.';

  mgConfirm(msg, { ok: draft ? 'Hide it' : 'Restrict it' }).then(function(ok) {
    if (!ok) return;
    // The trailing slash is what makes this a SECTION rather than a file - the
    // store keys folder rules that way and the panel lists on it.
    fetch(API + '?action=acl-set&path=' + encodeURIComponent(path + '/'), {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ read: who, write: who, draft: draft })
    })
    .then(function(r) { return r.json(); })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error || 'Could not protect the section', true); return; }
      showStatus(draft ? 'Section hidden.' : 'Section restricted.');
      loadProtectedSections();
      loadDir(currentDir);
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
  });
}

function setSort(col) {
  if (fileSort.col === col) fileSort.dir = -fileSort.dir;
  else { fileSort.col = col; fileSort.dir = 1; }
  paintFiles();   // re-sort in place; stay on the current page
}

function updateSortIndicators() {
  var inds = document.querySelectorAll('.mg-sort-ind');
  for (var i = 0; i < inds.length; i++) {
    var col = inds[i].getAttribute('data-col');
    inds[i].innerHTML = (col === fileSort.col) ? (fileSort.dir > 0 ? '&#9650;' : '&#9660;') : '';
  }
}

function renderPager(total, pages) {
  var el = document.getElementById('file-pager');
  if (!el) return;
  if (pages <= 1) { el.innerHTML = ''; return; }
  var start = filePage * FILE_PAGE_SIZE + 1;
  var end = Math.min(total, (filePage + 1) * FILE_PAGE_SIZE);
  el.innerHTML =
    '<button class="mg-btn mg-btn-sm" ' + (filePage <= 0 ? 'disabled' : '') + ' onclick="gotoPage(' + (filePage - 1) + ')">&#8592; Prev</button>' +
    '<span class="mg-pager-info">' + start + '&ndash;' + end + ' of ' + total + '</span>' +
    '<button class="mg-btn mg-btn-sm" ' + (filePage >= pages - 1 ? 'disabled' : '') + ' onclick="gotoPage(' + (filePage + 1) + ')">Next &#8594;</button>';
}

function gotoPage(n) { filePage = n; paintFiles(); window.scrollTo(0, 0); }

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

function duplicateFile(btn) {
  var card = btn.closest('tr');
  var row  = card.previousElementSibling;
  var path = row.getAttribute('data-path');
  // Suggest "<name>-copy.<ext>" as the default target.
  var suggested = path.replace(/(\.[^./]+)?$/, function(ext) { return '-copy' + (ext || ''); });
  mgPrompt('Duplicate to:', suggested).then(function(dest) {
    if (!dest || dest === path) return;
    fetch(API + '?action=copy&path=' + encodeURIComponent(path) + '&to=' + encodeURIComponent(dest), { method: 'POST' })
    .then(function(r) { return r.json(); })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error || 'Duplicate failed', true); return; }
      showStatus('Duplicated to ' + dest + '.');
      loadDir(currentDir);
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
  });
}

// SM096: fetch a .url page's remote body and take local ownership as .md.
function migrateToLocal(btn) {
  var card = btn.closest('tr');
  var row  = card.previousElementSibling;
  var path = row.getAttribute('data-path');
  var name = row.getAttribute('data-name') || path;
  mgConfirm('Fetch "' + name + '" and save it as a local page? The remote content is downloaded once and the .url is replaced by a local .md you own.', { ok: 'Migrate' }).then(function(ok) {
    if (!ok) return;
    fetch(API + '?action=migrate-to-local&path=' + encodeURIComponent(path), { method: 'POST' })
    .then(function(r) { return r.json(); })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error || 'Migrate failed', true); return; }
      showStatus('Migrated to ' + d.to + '.');
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

// Delete a single file from its expand card (path read from the row, no escaping).
function deleteOneFile(btn) {
  var card = btn.closest('tr');
  var row  = card.previousElementSibling;
  var path = row && row.getAttribute('data-path');
  var name = (row && row.getAttribute('data-name')) || path;
  if (!path) return;
  mgConfirm('Delete "' + name + '"? This cannot be undone.', { danger: true, ok: 'Delete' }).then(function(ok) {
    if (!ok) return;
    fetch(API + '?action=delete&path=' + encodeURIComponent(path), { method: 'POST' })
      .then(function(r) { return r.json(); })
      .then(function(d) {
        if (!d.ok) { showStatus(d.error || 'Delete failed', true); return; }
        showStatus('Deleted ' + name + '.');
        loadDir(currentDir);
      })
      .catch(function(e) { showStatus('Error: ' + e.message, true); });
  });
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
// SM111: filter is now data-driven (re-render the filtered+sorted+paged list).
function applyFilters() {
  filePage = 0;
  paintFiles();
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

// SM267 (carved out of SM181): what is held back right now.
//
// SM181 built both policies and left them reachable only by hand-editing
// acls.json, so the product could hold a section back and had no screen that
// said which sections were held back. The failure mode of a good hiding
// mechanism is forgetting what you hid: a draft section left in place after
// launch is invisible by design and nothing says so.
//
// Publishing is TWO different acts and gets two different controls. Clearing
// `draft` makes a section public. Removing the entry drops the read list as
// well, which on a gated section is a wider act than it looks - so it is named
// for what it does and confirmed separately.
function loadProtectedSections() {
  fetch(API + '?action=protected-sections')
    .then(function(r) { return r.json(); })
    .then(function(d) {
      var table = document.getElementById('protected-table');
      var empty = document.getElementById('protected-empty');
      if (!table || !empty) return;
      var rows = (d && d.ok && d.sections) || [];
      // Keyed for the FOLDER ROWS to read. The card at the foot of the page
      // answers "what is protected on this site"; a folder's own expansion has
      // to answer "is THIS protected", and the operator should not have to
      // scroll to a different card and match paths by eye to find out.
      PROTECTED_BY_PREFIX = {};
      for (var k = 0; k < rows.length; k++) {
        if (!rows[k].site_wide) PROTECTED_BY_PREFIX[rows[k].prefix] = rows[k];
      }
      SITE_WIDE_RULE = null;
      for (var j = 0; j < rows.length; j++) { if (rows[j].site_wide) SITE_WIDE_RULE = rows[j]; }
      paintFiles();   // re-render so folder rows can show what they now know
      if (!rows.length) { table.style.display = 'none'; empty.style.display = ''; return; }
      var html = '';
      for (var i = 0; i < rows.length; i++) {
        var s = rows[i], p = escHtml(s.prefix);
        var draft = s.policy === 'draft';
        // SM287: the site-wide rule is a section like any other and covers
        // everything, so it must not read as a folder called "/". Named, not
        // just styled - somebody scanning this list for what is protected
        // should not have to interpret a slash.
        var label = s.site_wide
          ? '<strong>The whole site</strong> <span class="mg-muted">(every page and asset)</span>'
          : '<code>' + p + '</code>';
        var badge = draft
          ? '<span class="mg-alias-badge mg-alias-302" title="Hidden outright: 404 to the public, absent from the sitemap, feeds and every listing.">draft</span>'
          : '<span class="mg-alias-badge" title="Visible only to the people named in the read list; everyone else is sent to sign in.">gated</span>';
        var who = (s.read && s.read.length) ? escHtml(s.read.join(', '))
          : '<span class="mg-muted">nobody but the owner</span>';
        // An entry whose folder has gone still gates the path. Say so rather
        // than drop the row - an orphaned rule is exactly what this screen is
        // for.
        var contents = s.exists
          ? (s.pages + ' page' + (s.pages === 1 ? '' : 's')
             + (s.assets ? ', ' + s.assets + ' asset' + (s.assets === 1 ? '' : 's') : ''))
          : '<span class="mg-cap-dormant" title="The rule still gates this path, but there is no such folder.">no such folder</span>';
        html += '<tr><td>' + label + '</td>'
              + '<td>' + badge + '</td>'
              + '<td>' + who + '</td>'
              + '<td>' + contents + '</td>'
              + '<td class="mg-file-actions">'
              + (draft
                  ? '<button class="mg-btn mg-btn-sm" onclick="publishSection(\'' + p + '\',true)">Publish</button> '
                  : '')
              + '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="publishSection(\'' + p + '\',false)">Remove protection</button>'
              + '</td></tr>';
      }
      document.getElementById('protected-rows').innerHTML = html;
      table.style.display = '';
      empty.style.display = 'none';
    })
    .catch(function() { /* card stays empty */ });
}

// draftOnly: clear the draft flag and keep the read list (the section becomes
// public but the ACL survives). Otherwise remove the entry entirely.
function publishSection(prefix, draftOnly) {
  var msg = draftOnly
    ? 'Publish "' + prefix + '"? Every page and asset under it becomes visible to '
      + 'the public and enters the sitemap and feeds.'
    : 'Remove all protection from "' + prefix + '"? This drops the read list as '
      + 'well, so the section becomes public AND stops being access-controlled.';
  mgConfirm(msg, { ok: draftOnly ? 'Publish' : 'Remove protection' }).then(function(okd) {
    if (!okd) return;
    var q = draftOnly
      ? { action: 'acl-set', body: { draft: false } }
      : { action: 'acl-remove', body: null };
    var opts = { method: 'POST', headers: { 'Content-Type': 'application/json' } };
    if (q.body) opts.body = JSON.stringify(q.body);
    fetch(API + '?action=' + q.action + '&path=' + encodeURIComponent(prefix), opts)
      .then(function(r) { return r.json(); })
      .then(function(d) {
        if (!d.ok) { showStatus(d.error || 'Failed', true); return; }
        showStatus(draftOnly ? 'Section published.' : 'Protection removed.');
        loadProtectedSections();
      })
      .catch(function(e) { showStatus('Error: ' + e.message, true); });
  });
}

// SM134 follow-ups: read-only view of the alias-redirect map (aliases.json).
// Scoped to the folder being browsed: the card sits under a directory
// listing and should describe THAT directory. A site with a hundred redirects
// otherwise answered "which of these are mine?" by making the operator read
// all hundred.
//
// The folder-to-URL translation happens on the SERVER, because it needs the
// content root - a page at sites/alpha/blog/post.md answers to /blog/post -
// and a second copy of that mapping here is exactly what SM440 got wrong once
// already.
function loadAliases() {
  fetch(API + '?action=aliases-list&path=' + encodeURIComponent(currentDir))
    .then(function(r) { return r.json(); })
    .then(function(d) {
      if (!d.ok) return;   // leave the card in its empty state
      var rows = d.aliases || [];
      var table = document.getElementById('alias-table');
      var empty = document.getElementById('alias-empty');
      // Say WHERE the answer applies, so an empty card reads as "none here"
      // rather than "none at all" - a difference the operator cannot see.
      var here = (currentDir === '/' ? 'this site' : currentDir);
      if (empty) empty.textContent = 'No aliases point into ' + here + '.';
      if (!rows.length) { table.style.display = 'none'; empty.style.display = ''; return; }
      var html = '';
      for (var i = 0; i < rows.length; i++) {
        var a = rows[i];
        var badge = a.code === 302
          ? '<span class="mg-alias-badge mg-alias-302" title="Temporary redirect (aliases_temp:)">302</span>'
          : '<span class="mg-alias-badge" title="Permanent redirect (aliases:)">301</span>';
        html += '<tr><td>' + escHtml(a.alias) + '</td>'
              + '<td><a href="' + escHtml(a.target) + '">' + escHtml(a.target) + '</a></td>'
              + '<td>' + badge + '</td></tr>';
      }
      document.getElementById('alias-rows').innerHTML = html;
      table.style.display = '';
      empty.style.display = 'none';
    })
    .catch(function() { /* card stays empty */ });
}

// SM085: content history (git). The feature flag is fetched once at load;
// the per-file History control renders only when the feature is enabled.
var GIT = { enabled: false };
function loadGitStatus() {
  return fetch(API + '?action=git-status')
    .then(function(r) { return r.json(); })
    .then(function(d) {
      if (d && d.ok) GIT.enabled = !!d.enabled;
      // SM199: the site-level History overview button appears with the feature.
      var hb = document.getElementById('hist-overview-btn');
      if (hb) hb.style.display = GIT.enabled ? '' : 'none';
    })
    .catch(function() { /* control stays hidden */ });
}

// SM199: the file-list / table-of-contents over the whole history. Fetches
// per-file statistics (revisions, first + latest date, last author) and a
// site-level summary, rendered as a table sortable by revisions and latest.
var HIST_OVERVIEW = { rows: [], sort: 'latest', dir: -1 };
function openHistoryOverview() {
  var box = document.getElementById('hist-overview');
  var body = document.getElementById('hist-overview-body');
  if (!box || !body) return;
  box.style.display = '';
  body.innerHTML = '<p class="mg-muted">Loading&hellip;</p>';
  fetch(API + '?action=git-history-summary')
    .then(function(r) { return r.json(); })
    .then(function(d) {
      if (!d.ok) { body.innerHTML = '<p class="mg-muted">' + escHtml(d.error || 'No history available') + '</p>'; return; }
      if (!d.enabled) { body.innerHTML = '<p class="mg-muted">Content history is not enabled.</p>'; return; }
      HIST_OVERVIEW.rows = d.files || [];
      HIST_OVERVIEW.summary = d.summary || { files: 0, revisions: 0 };
      renderHistoryOverview();
    })
    .catch(function(e) { body.innerHTML = '<p class="mg-muted">Error: ' + escHtml(e.message) + '</p>'; });
}
function closeHistoryOverview() {
  var box = document.getElementById('hist-overview');
  if (box) box.style.display = 'none';
}
function sortHistoryOverview(col) {
  if (HIST_OVERVIEW.sort === col) { HIST_OVERVIEW.dir = -HIST_OVERVIEW.dir; }
  else { HIST_OVERVIEW.sort = col; HIST_OVERVIEW.dir = (col === 'path') ? 1 : -1; }
  renderHistoryOverview();
}
function renderHistoryOverview() {
  var body = document.getElementById('hist-overview-body');
  if (!body) return;
  var rows = HIST_OVERVIEW.rows.slice();
  var col = HIST_OVERVIEW.sort, dir = HIST_OVERVIEW.dir;
  rows.sort(function(a, b) {
    var av = a[col === 'first' ? 'first' : col === 'latest' ? 'latest' : col === 'revisions' ? 'revisions' : 'path'];
    var bv = b[col === 'first' ? 'first' : col === 'latest' ? 'latest' : col === 'revisions' ? 'revisions' : 'path'];
    if (col === 'path' || col === 'last_author') { av = String(a[col] || ''); bv = String(b[col] || ''); return av < bv ? -dir : av > bv ? dir : 0; }
    return (av - bv) * dir;
  });
  var s = HIST_OVERVIEW.summary || { files: 0, revisions: 0 };
  if (!rows.length) {
    body.innerHTML = '<p class="mg-muted">No files under content history yet.</p>';
    return;
  }
  var html = '<p class="mg-muted">' + s.files + ' file' + (s.files === 1 ? '' : 's')
           + ' under history, ' + s.revisions + ' revision' + (s.revisions === 1 ? '' : 's') + ' in total.</p>'
           + '<table class="mg-file-table"><thead><tr>'
           + '<th class="mg-sortable" onclick="sortHistoryOverview(\'path\')">Path</th>'
           + '<th class="mg-sortable" onclick="sortHistoryOverview(\'revisions\')">Revisions</th>'
           + '<th class="mg-sortable" onclick="sortHistoryOverview(\'first\')">First</th>'
           + '<th class="mg-sortable" onclick="sortHistoryOverview(\'latest\')">Latest</th>'
           + '<th class="mg-sortable" onclick="sortHistoryOverview(\'last_author\')">Last author</th>'
           + '</tr></thead><tbody>';
  for (var i = 0; i < rows.length; i++) {
    var r = rows[i];
    html += '<tr>'
          + '<td>' + escHtml(r.path) + '</td>'
          + '<td>' + escHtml(String(r.revisions)) + '</td>'
          + '<td>' + escHtml(absTime(r.first)) + '</td>'
          + '<td>' + escHtml(absTime(r.latest)) + '</td>'
          + '<td>' + escHtml(r.last_author || '') + '</td>'
          + '</tr>';
  }
  html += '</tbody></table>';
  body.innerHTML = html;
}

// Expand/collapse the per-file history panel; loads the commit list on open.
function toggleHistory(btn) {
  var card = btn.closest('tr');
  var panel = card.querySelector('.mg-git-panel');
  if (!panel) return;
  if (panel.style.display !== 'none') { panel.style.display = 'none'; return; }
  var path = panel.getAttribute('data-path');
  panel.style.display = '';
  panel.innerHTML = '<p class="mg-muted">Loading history&hellip;</p>';
  fetch(API + '?action=git-history&path=' + encodeURIComponent(path))
    .then(function(r) { return r.json(); })
    .then(function(d) {
      if (!d.ok) { panel.innerHTML = '<p class="mg-muted">' + escHtml(d.error || 'No history available') + '</p>'; return; }
      renderHistory(panel, d.versions || []);
    })
    .catch(function(e) { panel.innerHTML = '<p class="mg-muted">Error: ' + escHtml(e.message) + '</p>'; });
}

function renderHistory(panel, entries) {
  if (!entries.length) {
    panel.innerHTML = '<p class="mg-muted">No versions recorded for this file. If it was changed after history was enabled, version recording may be failing &mdash; run <code>lazysite check</code>.</p>';
    return;
  }
  var html = '<table class="mg-file-table"><thead><tr>'
           + '<th>When</th><th>Who</th><th>Change</th><th></th></tr></thead><tbody>';
  for (var i = 0; i < entries.length; i++) {
    var e = entries[i];
    html += '<tr>'
          + '<td>' + escHtml(absTime(e.epoch)) + '</td>'
          + '<td>' + escHtml(e.author || '') + '</td>'
          + '<td><span title="' + escHtml(e.sha) + '">' + escHtml(e.subject || '') + '</span></td>'
          + '<td style="white-space:nowrap">'
          +   '<button class="mg-btn mg-btn-sm" data-sha="' + escHtml(e.sha) + '" onclick="showVersion(this, \'view\')">View</button> '
          +   '<button class="mg-btn mg-btn-sm" data-sha="' + escHtml(e.sha) + '" onclick="showVersion(this, \'diff\')">Diff</button> '
          +   '<button class="mg-btn mg-btn-sm mg-btn-danger" data-sha="' + escHtml(e.sha) + '" onclick="restoreVersion(this)">Restore</button>'
          + '</td></tr>';
  }
  html += '</tbody></table>'
        + '<pre class="mg-git-view" style="display:none;font-family:var(--mg-mono,monospace);'
        + 'font-size:0.8rem;max-height:320px;overflow:auto;white-space:pre-wrap;'
        + 'margin-top:8px;padding:8px;border:1px solid var(--mg-border,#ddd);"></pre>';
  panel.innerHTML = html;
}

// View a version's raw content, or its unified diff against the current file.
function showVersion(btn, mode) {
  var panel = btn.closest('.mg-git-panel');
  var path = panel.getAttribute('data-path');
  var sha = btn.getAttribute('data-sha');
  fetch(API + '?action=git-show&path=' + encodeURIComponent(path) + '&sha=' + encodeURIComponent(sha))
    .then(function(r) { return r.json(); })
    .then(function(d) {
      var out = panel.querySelector('.mg-git-view');
      if (!out) return;
      out.style.display = '';
      if (!d.ok) { out.textContent = d.error || 'Cannot load this version'; return; }
      // SM175: a version from before a rename notes the path it then lived at.
      var moved = d.from_path ? ' (was ' + d.from_path + ')' : '';
      if (mode === 'diff') {
        out.textContent = '# ' + sha.slice(0, 7) + moved + ' vs current\n\n'
                        + (d.diff || '(identical to the current version)');
      } else {
        out.textContent = '# content at ' + sha.slice(0, 7) + moved + ' (read-only)\n\n' + d.content;
      }
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

// Restore = the old content written back through a normal save: the restore
// becomes the newest version itself, so nothing is ever lost.
function restoreVersion(btn) {
  var panel = btn.closest('.mg-git-panel');
  var path = panel.getAttribute('data-path');
  var sha = btn.getAttribute('data-sha');
  var msg = 'Restore "' + path + '" to version ' + sha.slice(0, 7) + '?\n\n'
          + 'The old content is written back as a normal save - the restore '
          + 'becomes the newest version, so this is always reversible.';
  mgConfirm(msg, { ok: 'Restore' }).then(function(ok) {
    if (!ok) return;
    fetch(API + '?action=git-restore&path=' + encodeURIComponent(path) + '&sha=' + encodeURIComponent(sha), { method: 'POST' })
      .then(function(r) { return r.json(); })
      .then(function(d) {
        if (!d.ok) { showStatus(d.error || 'Restore failed', true); return; }
        showStatus('Restored ' + path + ' to ' + sha.slice(0, 7) + '.');
        loadDir(currentDir);
      })
      .catch(function(e) { showStatus('Error: ' + e.message, true); });
  });
}

// SM157: every content root the user is scoped to. One entry => single-domain
// editor (rooted there, no switcher). Several => multi-domain editor: the file
// browser roots at the ACTIVE one and offers a switcher. Empty => operator.
var SCOPES = (window.LAZYSITE_DAV_SCOPES || '').split(',')
  .map(function(s) { return s.replace(/^\/+|\/+$/g, ''); }).filter(Boolean);
var activeScope = null;
(function initActiveScope() {
  if (!SCOPES.length) return;                 // operator - unconfined, no switcher
  var saved = null;
  try { saved = localStorage.getItem('lazysite.activeScope'); } catch (e) {}
  activeScope = (saved && SCOPES.indexOf(saved) !== -1) ? saved : SCOPES[0];
})();

// SM154 (P3): a domain-bound editor's own content root ('/content/clientA/'),
// or '/' for an unbound operator. The server confines a bound user regardless;
// this just gives them a coherent starting view rooted at their own domain.
// SM157: for a multi-domain editor the root follows the switcher's activeScope.
function scopeRoot() {
  if (activeScope) return '/' + activeScope + '/';
  var s = (window.LAZYSITE_SCOPE_ROOT || '').replace(/^\/+|\/+$/g, '');
  return s ? ('/' + s + '/') : '/';
}

// SM157: render the domain switcher (only when the editor is scoped to several
// domains) and switch between them.
function renderScopeSwitcher() {
  var el = document.getElementById('scope-switcher');
  if (!el) return;
  if (SCOPES.length < 2) { el.style.display = 'none'; return; }
  var opts = SCOPES.map(function (s) {
    return '<option value="' + escHtml(s) + '"' + (s === activeScope ? ' selected' : '') + '>' + escHtml(s) + '</option>';
  }).join('');
  el.innerHTML = '<label class="mg-muted" style="font-size:0.9em;">Domain: '
    + '<select class="mg-inp" style="max-width:18rem" onchange="switchScope(this.value)">' + opts + '</select></label>'
    + ' <span class="mg-muted" style="font-size:0.8em;">you manage several &mdash; pick which to browse</span>';
  el.style.display = '';
}
function switchScope(v) {
  if (SCOPES.indexOf(v) === -1) return;
  activeScope = v;
  try { localStorage.setItem('lazysite.activeScope', v); } catch (e) {}
  renderScopeSwitcher();
  loadDir(scopeRoot());
}
function withinScope(dir) {
  var root = scopeRoot();
  if (root === '/') return true;
  var d = (dir || '/').replace(/\/+$/, '') + '/';
  return d.indexOf(root) === 0;
}

function readInitDir() {
  var want = null;
  var qs = location.search;
  if (qs && qs.length > 1) {
    var params = qs.substr(1).split('&');
    for (var i = 0; i < params.length; i++) {
      var kv = params[i].split('=');
      if (kv[0] === 'path') { want = decodeURIComponent(kv[1] || ''); break; }
    }
  }
  if (!want) { want = decodeURIComponent(location.hash.replace(/^#/, '')); }
  if (!want) return scopeRoot();
  // Clamp a bound editor to their own domain (the server would deny anything
  // outside it anyway).
  return withinScope(want) ? want : scopeRoot();
}

renderScopeSwitcher();
loadPrincipals().then(loadGitStatus).then(function() { loadDir(readInitDir()); });
loadProtectedSections();
loadAliases();
</script>
