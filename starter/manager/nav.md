---
title: Navigation
auth: manager
search: false
---

<div id="status" class="mg-status"></div>

<!-- SM159: choose which domain's navigation to edit. Only shown when this
     instance serves more than one domain; a domain that inherits the shared
     base nav is flagged. -->
<div id="nav-domain-row" style="display:none;margin-bottom:10px;align-items:center;gap:8px;flex-wrap:wrap;">
  <label class="mg-muted" style="font-size:0.9em;">Editing navigation for:
    <select id="nav-domain" class="mg-inp" style="max-width:20rem" onchange="onDomainChange()"></select>
  </label>
  <span id="nav-inherit-note" class="mg-muted" style="display:none;font-size:0.8em;"></span>
</div>

<div class="mg-toolbar" style="display:flex;gap:8px;margin-bottom:12px;align-items:center;">
<button class="mg-btn" id="add-toggle" onclick="toggleAdd()">+ Add menu item</button>
<span style="flex:1;"></span>
<span id="nav-dirty" class="mg-note mg-note-info" style="display:none">&#9679; Unsaved changes &mdash; click Save</span>
<button class="mg-btn mg-btn-primary" onclick="saveNav()">Save</button>
<button class="mg-btn" onclick="loadNav()">Reload</button>
</div>

<!-- Add-item form: hidden until "Add menu item" is clicked, so the fields are
     clearly a distinct "add new" box rather than loose inputs in the toolbar. -->
<div id="add-panel" style="display:none;border:1px solid var(--mg-border,#ddd);border-radius:6px;padding:12px;margin-bottom:14px;">
  <div style="font-size:0.78em;color:var(--mg-text-muted);text-transform:uppercase;letter-spacing:0.04em;margin-bottom:8px;">Add a menu item</div>
  <div style="display:flex;gap:8px;flex-wrap:wrap;align-items:flex-end;">
    <label style="display:flex;flex-direction:column;gap:2px;font-size:0.85em;color:var(--mg-text-muted);">Label
      <input type="text" id="add-label" placeholder="e.g. About" class="mg-inp" style="width:180px;" onkeydown="if(event.key==='Enter'){addItem();event.preventDefault();}"></label>
    <label style="display:flex;flex-direction:column;gap:2px;font-size:0.85em;color:var(--mg-text-muted);">Link
      <input type="text" id="add-url" placeholder="/about (blank = group heading)" class="mg-inp" style="width:240px;" list="page-urls" onkeydown="if(event.key==='Enter'){addItem();event.preventDefault();}"></label>
    <datalist id="page-urls"></datalist>
    <label style="display:flex;flex-direction:column;gap:2px;font-size:0.85em;color:var(--mg-text-muted);">Under
      <select id="add-parent" class="mg-inp" style="padding:4px;"><option value="">Top level</option></select></label>
    <button class="mg-btn mg-btn-primary" onclick="addItem()">Add to menu</button>
    <button class="mg-btn" onclick="toggleAdd()">Done</button>
  </div>
  <div style="font-size:0.8em;color:var(--mg-text-muted);margin-top:6px;">A blank link makes a group heading (its children drop down under it). Items are added to the list below &mdash; reorder by dragging, then <strong>Save</strong>.</div>
</div>

<div id="nav-list">Loading...</div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';
var navItems = [];
var dragSrcIdx = null;

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

function esc(s) { return (s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }

// SM118 pattern (field report): every mutation below edits only the in-memory
// list - nothing touches nav.conf until Save - so each mutation path flags dirty
// via the shared mgDirtyGuard (manager layout), which shows the note and warns
// on leaving. Load and save success re-sync with the server, so both clear it.
function markNavDirty()  { mgDirtyGuard.set('nav', 'nav-dirty'); }
function clearNavDirty() { mgDirtyGuard.clear('nav'); }

// SM159: which domain's nav is being edited ('' = the default/base nav).
var navHost = '';
function navQuery(extra) {
  return navHost ? (extra + '&host=' + encodeURIComponent(navHost)) : extra;
}
function toggleAdd() {
  var p = document.getElementById('add-panel');
  var show = (p.style.display === 'none');
  p.style.display = show ? 'block' : 'none';
  if (show) { var l = document.getElementById('add-label'); if (l) l.focus(); }
}

// Populate the domain picker from the configured domains. Only domains that can
// have their OWN nav are listed: the default site, plus each domain (a domain
// inheriting the base nav is still selectable, with a note explaining that
// editing it changes the shared base until it is given its own nav_file on the
// Domains page).
function loadNavDomains() {
  return fetch(API + '?action=domains-list', { credentials: 'same-origin' })
    .then(function (r) { return r.json(); })
    .then(function (d) {
      if (!d || !d.ok) return;
      var rows = (d.domains || []).filter(function (r) { return !r.alias_of; });
      if (rows.length <= 1) return;            // single-site: no picker needed
      var sel = document.getElementById('nav-domain');
      sel.innerHTML = rows.map(function (r) {
        var val = r.is_primary ? '' : r.host;
        var lbl = r.is_primary ? 'Default site' : r.host;
        return '<option value="' + esc(val) + '">' + esc(lbl) + '</option>';
      }).join('');
      document.getElementById('nav-domain-row').style.display = 'flex';
    })
    .catch(function () {});
}
function onDomainChange() {
  if (mgDirtyGuard && mgDirtyGuard.isDirty && mgDirtyGuard.isDirty('nav')) {
    if (!window.confirm('You have unsaved nav changes. Switch domain and discard them?')) {
      document.getElementById('nav-domain').value = navHost; return;
    }
  }
  navHost = document.getElementById('nav-domain').value || '';
  loadNav();
}

function loadNav() {
  fetch(API + '?' + navQuery('action=nav-read'))
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      // SM169: always show WHICH file is being edited, and whether it is this
      // domain's own nav or the shared default - so a domain whose nav_file
      // override is not actually in effect is obvious (you see the base file,
      // not the one you set), instead of silently editing a different file.
      var note = document.getElementById('nav-inherit-note');
      if (note) {
        var f = data.nav_file || 'lazysite/nav.conf';
        if (navHost && data.inherited) {
          note.textContent = 'ℹ This domain has no nav file of its own, so it shares the default site’s menu (' + f + '). Editing here changes the shared menu; to give this domain its own, set a nav file for it on the Domains page.';
        } else if (navHost) {
          note.textContent = 'Editing this domain’s own menu: ' + f + '.';
        } else {
          note.textContent = 'Editing the default site menu: ' + f + '.';
        }
        note.style.display = '';
      }
      navItems = [];
      (data.items || []).forEach(function(item) {
        navItems.push({ label: item.label, url: item.url || '', indent: 0 });
        (item.children || []).forEach(function(child) {
          navItems.push({ label: child.label, url: child.url || '', indent: 1 });
        });
      });
      clearNavDirty();
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
    html += '<button onclick="deleteItem(' + idx + ')" class="mg-btn mg-btn-sm mg-btn-danger" title="Delete">&times;</button>';
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
  markNavDirty();
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
  markNavDirty();
  renderNav();
  updateParentSelect();
}

// MR-54: ONE asking, not two. Chained prompts made the operator hold the label
// in their head while typing the URL, and Cancel on the second threw both away
// with nothing to say which had been kept.
function editItem(idx) {
  var item = navItems[idx];
  mgModal({
    msg: 'Navigation item',
    ok: 'Save',
    fields: [
      { name: 'label', label: 'Label', value: item.label },
      { name: 'url',   label: 'URL (blank = group heading)', value: item.url || '' }
    ]
  }).then(function (v) {
    if (v === null) return;
    item.label = v.label;
    item.url   = v.url;
    markNavDirty();
    renderNav();
  });
}

function indentItem(idx) {
  if (idx === 0) return;
  if (navItems[idx].indent >= 1) return;
  if (navItems[idx - 1].indent > 0) return;
  navItems[idx].indent = 1;
  markNavDirty();
  renderNav();
  updateParentSelect();
}

function outdentItem(idx) {
  if (navItems[idx].indent <= 0) return;
  navItems[idx].indent = 0;
  markNavDirty();
  renderNav();
  updateParentSelect();
}

function deleteItem(idx) {
  var item = navItems[idx];
  mgConfirm('Remove "' + item.label + '"?', { danger: true, ok: 'Remove' }).then(function(__ok) {
    if (!__ok) return;
    // If it's a parent, also remove its children
    var count = 1;
    if (item.indent === 0) {
      while (idx + count < navItems.length && navItems[idx + count].indent > 0) count++;
    }
    navItems.splice(idx, count);
    markNavDirty();
    renderNav();
    updateParentSelect();
  });
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
    body: JSON.stringify({ items: items, host: navHost })
  })
  .then(function(r) { return r.json(); })
  .then(function(data) {
    if (data.ok) {
      clearNavDirty();
      // SM168: the save also refreshes the page cache, so the new menu is live
      // immediately - tell the operator it is published, not just saved.
      var n = data.cache_cleared || 0;
      showStatus('Navigation saved and published' +
        (n ? ' (' + n + ' page' + (n === 1 ? '' : 's') + ' refreshed)' : '') + '.');
    }
    else { showStatus(data.error || 'Save failed', true); }
  })
  .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

// SM097: back the URL field with a datalist of the site's existing page URLs so
// the operator picks a real target. Free text stays allowed (external/anchors).
function loadPageUrls() {
  fetch(API + '?action=pages').then(function (r) { return r.json(); }).then(function (d) {
    if (!d || !d.ok || !d.urls) return;
    var dl = document.getElementById('page-urls');
    if (!dl) return;
    dl.innerHTML = d.urls.map(function (u) {
      return '<option value="' + esc(u) + '"></option>';
    }).join('');
  }).catch(function () {});
}

loadNavDomains().then(loadNav);
loadPageUrls();
</script>
