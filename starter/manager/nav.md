---
title: Navigation
auth: manager
search: false
---

<div id="status" class="mg-status"></div>

<div style="display:flex;gap:8px;margin-bottom:12px;flex-wrap:wrap;align-items:center;">
<input type="text" id="add-label" placeholder="Label" class="mg-file-filter" style="flex:none;width:160px;">
<input type="text" id="add-url" placeholder="/url (blank = group heading)" class="mg-file-filter" style="flex:none;width:220px;">
<select id="add-parent" style="padding:4px;font-size:13px;">
<option value="">Top level</option>
</select>
<button class="mg-btn" onclick="addItem()">Add</button>
<span style="flex:1;"></span>
<button class="mg-btn mg-btn-primary" onclick="saveNav()">Save</button>
<button class="mg-btn" onclick="loadNav()">Reload</button>
</div>

<div id="nav-list">Loading...</div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';
var navItems = [];
var dragSrcIdx = null;

function showStatus(msg, isError) {
  var el = document.getElementById('status');
  el.className = 'mg-status' + (isError ? ' mg-status-error' : ' mg-status-success');
  el.textContent = msg;
  if (!isError) setTimeout(function() { el.textContent = ''; el.className = 'mg-status'; }, 3000);
}

function esc(s) { return (s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }

function loadNav() {
  fetch(API + '?action=nav-read')
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      navItems = [];
      (data.items || []).forEach(function(item) {
        navItems.push({ label: item.label, url: item.url || '', indent: 0 });
        (item.children || []).forEach(function(child) {
          navItems.push({ label: child.label, url: child.url || '', indent: 1 });
        });
      });
      renderNav();
      updateParentSelect();
    })
    .catch(function(e) { showStatus('Load failed: ' + e.message, true); });
}

function renderNav() {
  var list = document.getElementById('nav-list');
  if (!navItems.length) {
    list.innerHTML = '<p class="mg-empty">No navigation items. Add one above.</p>';
    return;
  }
  var html = '';
  navItems.forEach(function(item, idx) {
    html += '<div class="nav-drop-zone" data-before="' + idx + '"'
      + ' ondragover="onDropZoneOver(event,' + idx + ')"'
      + ' ondragleave="onDropZoneLeave(event)"'
      + ' ondrop="onDropZoneDrop(event,' + idx + ')"></div>';

    var isChild = item.indent > 0;
    html += '<div class="mg-nav-item' + (isChild ? ' child' : '') + '"'
      + ' draggable="true"'
      + ' data-idx="' + idx + '"'
      + ' ondragstart="onDragStart(event,' + idx + ')"'
      + ' ondragend="onDragEnd(event)">';
    html += '<span class="mg-nav-handle" title="Drag to reorder">&#9776;</span>';
    var canOutdent = item.indent > 0;
    var canIndent  = idx > 0 && item.indent < 1 && navItems[idx - 1].indent === 0;
    html += '<button onclick="outdentItem(' + idx + ')" class="mg-btn mg-btn-sm" title="Outdent"'
      + (canOutdent ? '' : ' disabled') + '>&#8592;</button>';
    html += '<button onclick="indentItem(' + idx + ')" class="mg-btn mg-btn-sm" title="Indent"'
      + (canIndent ? '' : ' disabled') + '>&#8594;</button>';
    html += '<span class="mg-nav-label">' + esc(item.label) + '</span>';
    html += '<span class="mg-nav-url">' + (item.url ? esc(item.url) : '<em>group</em>') + '</span>';
    html += '<button onclick="editItem(' + idx + ')" class="mg-btn mg-btn-sm" title="Edit">&#9998;</button>';
    html += '<button onclick="removeItem(' + idx + ')" class="mg-btn mg-btn-sm mg-btn-danger" title="Remove">&times;</button>';
    html += '</div>';
  });
  html += '<div class="nav-drop-zone" data-before="' + navItems.length + '"'
    + ' ondragover="onDropZoneOver(event,' + navItems.length + ')"'
    + ' ondragleave="onDropZoneLeave(event)"'
    + ' ondrop="onDropZoneDrop(event,' + navItems.length + ')"></div>';
  list.innerHTML = html;
}

function onDragStart(e, idx) {
  dragSrcIdx = idx;
  e.dataTransfer.effectAllowed = 'move';
  e.dataTransfer.setData('text/plain', idx);
  e.currentTarget.classList.add('dragging');
}

function onDropZoneOver(e, idx) {
  e.preventDefault();
  e.dataTransfer.dropEffect = 'move';
  e.currentTarget.classList.add('drop-active');
}

function onDropZoneLeave(e) {
  e.currentTarget.classList.remove('drop-active');
}

function onDropZoneDrop(e, beforeIdx) {
  e.preventDefault();
  e.currentTarget.classList.remove('drop-active');
  if (dragSrcIdx === null) return;
  var moved = navItems.splice(dragSrcIdx, 1)[0];
  var insertAt = beforeIdx > dragSrcIdx ? beforeIdx - 1 : beforeIdx;
  navItems.splice(insertAt, 0, moved);
  dragSrcIdx = null;
  renderNav();
}

function onDragEnd(e) {
  e.currentTarget.classList.remove('dragging');
  document.querySelectorAll('.nav-drop-zone').forEach(function(el) {
    el.classList.remove('drop-active');
  });
  dragSrcIdx = null;
}

function updateParentSelect() {
  var sel = document.getElementById('add-parent');
  var parents = navItems.filter(function(item) { return item.indent === 0; });
  var html = '<option value="">Top level</option>';
  var parentIdx = 0;
  navItems.forEach(function(item, idx) {
    if (item.indent === 0) {
      html += '<option value="' + idx + '">Under: ' + esc(item.label) + '</option>';
    }
  });
  sel.innerHTML = html;
}

function addItem() {
  var label = document.getElementById('add-label').value.trim();
  if (!label) { showStatus('Label is required', true); return; }
  var url = document.getElementById('add-url').value.trim();
  var parentVal = document.getElementById('add-parent').value;

  if (parentVal === '') {
    navItems.push({ label: label, url: url, indent: 0 });
  } else {
    var afterIdx = parseInt(parentVal);
    // Insert after the parent and its existing children
    var insertAt = afterIdx + 1;
    while (insertAt < navItems.length && navItems[insertAt].indent > 0) insertAt++;
    navItems.splice(insertAt, 0, { label: label, url: url, indent: 1 });
  }

  document.getElementById('add-label').value = '';
  document.getElementById('add-url').value = '';
  renderNav();
  updateParentSelect();
}

function editItem(idx) {
  var item = navItems[idx];
  var newLabel = prompt('Label:', item.label);
  if (newLabel === null) return;
  var newUrl = prompt('URL (blank = group heading):', item.url || '');
  if (newUrl === null) return;
  item.label = newLabel;
  item.url = newUrl;
  renderNav();
}

function indentItem(idx) {
  if (idx === 0) return;
  if (navItems[idx].indent >= 1) return;
  if (navItems[idx - 1].indent > 0) return;
  navItems[idx].indent = 1;
  renderNav();
  updateParentSelect();
}

function outdentItem(idx) {
  if (navItems[idx].indent <= 0) return;
  navItems[idx].indent = 0;
  renderNav();
  updateParentSelect();
}

function removeItem(idx) {
  var item = navItems[idx];
  if (!confirm('Remove "' + item.label + '"?')) return;
  // If it's a parent, also remove its children
  var count = 1;
  if (item.indent === 0) {
    while (idx + count < navItems.length && navItems[idx + count].indent > 0) count++;
  }
  navItems.splice(idx, count);
  renderNav();
  updateParentSelect();
}

function saveNav() {
  // Convert flat list back to nested structure for API
  var items = [];
  var currentParent = null;
  navItems.forEach(function(item) {
    if (item.indent === 0) {
      currentParent = { label: item.label, url: item.url, children: [] };
      items.push(currentParent);
    } else if (currentParent) {
      currentParent.children.push({ label: item.label, url: item.url });
    }
  });

  showStatus('Saving...');
  fetch(API + '?action=nav-save', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ items: items })
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
