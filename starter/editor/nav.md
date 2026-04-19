---
title: Navigation
search: false
---

<div>
<style>
.nav-wrap { font-family: system-ui, sans-serif; max-width: 600px; margin: 0 auto; }
.editor-nav { margin-bottom: 16px; }
.editor-nav a { margin-right: 16px; color: #07c; text-decoration: none; font-size: 14px; }
.editor-nav a:hover { text-decoration: underline; }
.editor-nav a.active { font-weight: 600; color: #333; border-bottom: 2px solid #07c; }
.nav-toolbar { display: flex; gap: 8px; margin-bottom: 12px; }
.nav-toolbar button { padding: 4px 14px; cursor: pointer; }
.nav-item { display: flex; align-items: center; gap: 6px; padding: 6px 8px; border: 1px solid #ddd; border-radius: 4px; margin-bottom: 4px; background: #fff; }
.nav-item.child { margin-left: 28px; }
.nav-item .drag { cursor: grab; color: #aaa; font-size: 14px; user-select: none; }
.nav-item .label { font-weight: 500; flex: 1; }
.nav-item .url { color: #888; font-size: 12px; font-family: monospace; }
.nav-item button { font-size: 11px; padding: 1px 6px; cursor: pointer; }
.nav-item .group-badge { font-size: 10px; color: #888; background: #f0f0f0; padding: 0 4px; border-radius: 2px; }
.add-form { display: flex; gap: 6px; margin-bottom: 12px; flex-wrap: wrap; align-items: center; }
.add-form input { padding: 4px 8px; border: 1px solid #ccc; border-radius: 3px; font-size: 13px; }
.add-form select { padding: 4px; font-size: 13px; }
.add-form button { padding: 4px 12px; cursor: pointer; }
.status-msg { padding: 6px 10px; margin-bottom: 8px; border-radius: 4px; font-size: 13px; }
.status-msg.ok { background: #efe; color: #060; }
.status-msg.error { background: #fee; color: #c00; }
</style>
</div>

<div class="nav-wrap" id="app">

<nav class="editor-nav">
<a href="/editor/">Files</a>
<a href="/editor/nav" class="active">Nav</a>
<a href="/editor/plugins">Plugins</a>
<a href="/editor/themes">Themes</a>
<a href="/editor/users">Users</a>
<a href="/editor/cache">Cache</a>
</nav>

<div id="status"></div>

<div class="add-form">
<input type="text" id="add-label" placeholder="Label">
<input type="text" id="add-url" placeholder="/url (blank = group heading)">
<select id="add-parent">
<option value="">Top level</option>
</select>
<button onclick="addItem()">Add</button>
</div>

<div class="nav-toolbar">
<button onclick="saveNav()">Save</button>
<button onclick="loadNav()">Reload</button>
</div>

<div id="nav-list">Loading...</div>

</div>

<script>
var API = '/cgi-bin/lazysite-editor-api.pl';
var navItems = [];

function showStatus(msg, isError) {
  var el = document.getElementById('status');
  el.className = 'status-msg ' + (isError ? 'error' : 'ok');
  el.textContent = msg;
  if (!isError) setTimeout(function() { el.textContent = ''; el.className = ''; }, 3000);
}

function esc(s) { return (s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }

function loadNav() {
  fetch(API + '?action=nav-read')
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      navItems = data.items || [];
      renderNav();
      updateParentSelect();
    })
    .catch(function(e) { showStatus('Load failed: ' + e.message, true); });
}

function renderNav() {
  var list = document.getElementById('nav-list');
  if (!navItems.length) {
    list.innerHTML = '<p style="color:#888;">No navigation items. Add one above.</p>';
    return;
  }
  var html = '';
  for (var i = 0; i < navItems.length; i++) {
    var item = navItems[i];
    html += renderItem(i, -1, item, false);
    var children = item.children || [];
    for (var j = 0; j < children.length; j++) {
      html += renderItem(i, j, children[j], true);
    }
  }
  list.innerHTML = html;
}

function renderItem(pi, ci, item, isChild) {
  var id = pi + ':' + ci;
  var html = '<div class="nav-item' + (isChild ? ' child' : '') + '" data-pi="' + pi + '" data-ci="' + ci + '">';
  html += '<span class="drag" title="Drag to reorder">&#9776;</span>';
  html += '<span class="label">' + esc(item.label) + '</span>';
  if (item.url) {
    html += '<span class="url">' + esc(item.url) + '</span>';
  } else if (!isChild) {
    html += '<span class="group-badge">group</span>';
  }
  html += '<button onclick="editItem(' + pi + ',' + ci + ')" title="Edit">&#9998;</button>';
  if (!isChild) {
    html += '<button onclick="moveItem(' + pi + ',-1)" title="Move up">&uarr;</button>';
    html += '<button onclick="moveItem(' + pi + ',1)" title="Move down">&darr;</button>';
  } else {
    html += '<button onclick="moveChild(' + pi + ',' + ci + ',-1)" title="Move up">&uarr;</button>';
    html += '<button onclick="moveChild(' + pi + ',' + ci + ',1)" title="Move down">&darr;</button>';
  }
  html += '<button onclick="removeItem(' + pi + ',' + ci + ')" title="Remove">&times;</button>';
  html += '</div>';
  return html;
}

function updateParentSelect() {
  var sel = document.getElementById('add-parent');
  var html = '<option value="">Top level</option>';
  for (var i = 0; i < navItems.length; i++) {
    html += '<option value="' + i + '">Under: ' + esc(navItems[i].label) + '</option>';
  }
  sel.innerHTML = html;
}

function addItem() {
  var label = document.getElementById('add-label').value.trim();
  if (!label) { showStatus('Label is required', true); return; }
  var url = document.getElementById('add-url').value.trim();
  var parent = document.getElementById('add-parent').value;

  if (parent === '') {
    navItems.push({ label: label, url: url, children: [] });
  } else {
    var pi = parseInt(parent);
    if (!navItems[pi].children) navItems[pi].children = [];
    navItems[pi].children.push({ label: label, url: url });
  }

  document.getElementById('add-label').value = '';
  document.getElementById('add-url').value = '';
  renderNav();
  updateParentSelect();
}

function editItem(pi, ci) {
  var item = ci === -1 ? navItems[pi] : navItems[pi].children[ci];
  var newLabel = prompt('Label:', item.label);
  if (newLabel === null) return;
  var newUrl = prompt('URL (blank = group heading):', item.url || '');
  if (newUrl === null) return;
  item.label = newLabel;
  item.url = newUrl;
  renderNav();
}

function removeItem(pi, ci) {
  var item = ci === -1 ? navItems[pi] : navItems[pi].children[ci];
  if (!confirm('Remove "' + item.label + '"?')) return;
  if (ci === -1) {
    navItems.splice(pi, 1);
  } else {
    navItems[pi].children.splice(ci, 1);
  }
  renderNav();
  updateParentSelect();
}

function moveItem(pi, dir) {
  var ni = pi + dir;
  if (ni < 0 || ni >= navItems.length) return;
  var tmp = navItems[pi];
  navItems[pi] = navItems[ni];
  navItems[ni] = tmp;
  renderNav();
}

function moveChild(pi, ci, dir) {
  var children = navItems[pi].children;
  var ni = ci + dir;
  if (ni < 0 || ni >= children.length) return;
  var tmp = children[ci];
  children[ci] = children[ni];
  children[ni] = tmp;
  renderNav();
}

function saveNav() {
  showStatus('Saving...');
  fetch(API + '?action=nav-save', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ items: navItems })
  })
  .then(function(r) { return r.json(); })
  .then(function(data) {
    if (data.ok) { showStatus('Navigation saved.'); }
    else { showStatus(data.error || 'Save failed', true); }
  })
  .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

loadNav();
</script>
