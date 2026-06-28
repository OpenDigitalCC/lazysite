---
title: Appearance
auth: manager
search: false
query_params:
  - action
  - theme
---

<div id="status" class="mg-status"></div>

<div class="mg-card">
<div class="mg-card-header"><span class="mg-card-title">Layouts repo</span></div>
<div class="mg-card-body">
<p class="mg-card-subtitle" style="margin:0 0 8px 0;">Where layouts and themes are downloaded from. Leave the default, or point at your own fork. See the <a href="/docs/features/configuration/remote-layouts">docs</a>.</p>
<div class="mg-form-row" style="margin:0;">
<label for="layouts-repo-input">Repo</label>
<input type="text" id="layouts-repo-input" placeholder="OpenDigitalCC/lazysite-layouts" style="flex:1;">
<button class="mg-btn mg-btn-outline mg-btn-sm" onclick="saveLayoutsRepo()">Save</button>
</div>
</div>
</div>

<div class="mg-card">
<div class="mg-card-header">
<span class="mg-card-title">Active layout &amp; theme</span>
<button id="lzs-stop-preview" class="mg-btn mg-btn-outline mg-btn-sm" onclick="clearPreview()" style="display:none">Stop preview</button>
</div>
<div class="mg-card-body">
<p class="mg-card-subtitle" style="margin:0 0 8px 0;">The layout is the page structure; the theme is its colours and fonts. Activating sets the site default for all visitors and clears the page cache.</p>
<div class="mg-form-row">
<label for="sw-layout">Layout</label>
<select id="sw-layout" onchange="onSwitchLayout()" style="flex:1;"></select>
</div>
<div class="mg-form-row">
<label for="sw-theme">Theme</label>
<select id="sw-theme" style="flex:1;"></select>
</div>
<div style="display:flex;gap:0.5rem;justify-content:flex-end;">
<button class="mg-btn mg-btn-primary" onclick="activateSelection()">Activate</button>
</div>
</div>
</div>

<div class="mg-card">
<div class="mg-card-header"><span class="mg-card-title">Upload a theme</span></div>
<div class="mg-card-body">
<p class="mg-card-subtitle" style="margin:0 0 8px 0;">A .zip with <code>theme.json</code> at its root and an <code>assets/</code> subtree. Installs under the active layout. (Layouts install from the catalogue below.)</p>
<div style="display:flex;gap:0.5rem;align-items:center;">
<input type="file" id="theme-file" accept=".zip">
<button class="mg-btn mg-btn-outline" onclick="uploadTheme()">Upload</button>
</div>
</div>
</div>

<div class="mg-card">
<div class="mg-card-header">
<span class="mg-card-title">Browse the repo</span>
<button class="mg-btn mg-btn-outline mg-btn-sm" onclick="loadCatalogue()">Refresh</button>
</div>
<div class="mg-card-body">
<p class="mg-card-subtitle" style="margin:0 0 8px 0;">Layouts available in the repo. Installing a layout pulls its default theme; expand to install other themes.</p>
<div id="catalogue"><span class="mg-empty">Click Refresh to load the catalogue.</span></div>
</div>
</div>

<div class="mg-card">
<div class="mg-card-header"><span class="mg-card-title">Installed layouts &amp; themes</span></div>
<div id="installed">
<div class="mg-file-item"><span class="mg-file-name">Loading...</span></div>
</div>
</div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';
var ACTIVE_LAYOUT = '';
var ACTIVE_THEME  = '';

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

function escHtml(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

// --- Load everything: active state, installed layouts, grouped themes ---
function loadAll() {
  showStatus('');
  Promise.all([
    fetch(API + '?action=themes-list-all').then(function(r){ return r.json(); }),
    fetch(API + '?action=layouts-available').then(function(r){ return r.json(); })
  ]).then(function(res) {
    var ta = res[0] || {}, la = res[1] || {};
    ACTIVE_LAYOUT = ta.active_layout || '';
    ACTIVE_THEME  = ta.active || '';
    var themes  = ta.themes || [];                 // [{name, layout}]
    var layouts = (la.layouts || []).slice();      // [name]

    // Group themes by layout; union layout names so empty layouts show too.
    var byLayout = {};
    for (var i = 0; i < themes.length; i++) {
      (byLayout[themes[i].layout] = byLayout[themes[i].layout] || []).push(themes[i].name);
    }
    for (var k in byLayout) { if (layouts.indexOf(k) < 0) layouts.push(k); }
    layouts.sort();

    renderSwitcher(layouts, byLayout);
    renderInstalled(layouts, byLayout);
  }).catch(function(e) { showStatus('Failed to load: ' + e.message, true); });
}

// --- Active layout & theme switcher ---
function renderSwitcher(layouts, byLayout) {
  var ls = document.getElementById('sw-layout');
  ls.innerHTML = '';
  if (!layouts.length) {
    ls.innerHTML = '<option value="">(no layouts installed)</option>';
    document.getElementById('sw-theme').innerHTML = '';
    return;
  }
  for (var i = 0; i < layouts.length; i++) {
    var sel = layouts[i] === ACTIVE_LAYOUT ? ' selected' : '';
    ls.innerHTML += '<option value="' + escHtml(layouts[i]) + '"' + sel + '>'
      + escHtml(layouts[i]) + (layouts[i] === ACTIVE_LAYOUT ? ' (active)' : '') + '</option>';
  }
  fillThemeSelect(ls.value, byLayout);
}

function fillThemeSelect(layout, byLayout) {
  var ts = document.getElementById('sw-theme');
  var themes = (byLayout && byLayout[layout]) || [];
  ts.innerHTML = '';
  if (!themes.length) { ts.innerHTML = '<option value="">(no themes)</option>'; return; }
  for (var i = 0; i < themes.length; i++) {
    var sel = ( layout === ACTIVE_LAYOUT && themes[i] === ACTIVE_THEME ) ? ' selected' : '';
    ts.innerHTML += '<option value="' + escHtml(themes[i]) + '"' + sel + '>'
      + escHtml(themes[i]) + '</option>';
  }
}

// Switching the layout dropdown refreshes the theme list for that layout.
function onSwitchLayout() {
  var layout = document.getElementById('sw-layout').value;
  fetch(API + '?action=themes-for-layout&layout=' + encodeURIComponent(layout))
    .then(function(r){ return r.json(); })
    .then(function(d) {
      var by = {}; by[layout] = (d && d.themes) || [];
      fillThemeSelect(layout, by);
    });
}

function activateSelection() {
  var layout = document.getElementById('sw-layout').value;
  var theme  = document.getElementById('sw-theme').value;
  if (!layout) { showStatus('No layout selected.', true); return; }
  mgConfirm('Activate layout "' + layout + '"' + (theme ? ' with theme "' + theme + '"' : '')
    + '? All cached pages will be cleared.', { ok: 'Activate' }).then(function(ok) {
    if (!ok) return;
    fetch(API + '?action=layout-activate&path=' + encodeURIComponent(layout), {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ theme: theme })
    }).then(function(r){ return r.json(); }).then(function(d) {
      if (!d.ok) { showStatus(d.error, true); return; }
      showStatus('Activated layout "' + layout + '"' + (theme ? ' / theme "' + theme + '"' : '') + '.');
      loadAll();
    }).catch(function(e){ showStatus('Error: ' + e.message, true); });
  });
}

// --- Installed layouts & themes (full management) ---
function renderInstalled(layouts, byLayout) {
  var box = document.getElementById('installed');
  if (!layouts.length) {
    box.innerHTML = '<div class="mg-file-item"><span class="mg-file-name mg-empty">'
      + 'No layouts installed - install one from the catalogue above.</span></div>';
    return;
  }
  // Active layout first.
  layouts = layouts.slice().sort();
  if (ACTIVE_LAYOUT && layouts.indexOf(ACTIVE_LAYOUT) >= 0) {
    layouts = [ACTIVE_LAYOUT].concat(layouts.filter(function(l){ return l !== ACTIVE_LAYOUT; }));
  }
  var html = '';
  for (var g = 0; g < layouts.length; g++) {
    var L = layouts[g], isActiveL = (L === ACTIVE_LAYOUT);
    html += '<div class="mg-handler-group" style="margin:0.5rem;">';
    html += '<div class="mg-handler-group-header">';
    html += '<span class="mg-handler-group-label">' + escHtml(L);
    if (isActiveL) html += ' <span class="mg-badge mg-badge-success">active</span>';
    html += '</span><div class="mg-handler-item-actions">';
    if (!isActiveL) {
      html += '<button class="mg-btn mg-btn-sm mg-btn-primary" onclick="activateLayout(\'' + escHtml(L) + '\')">Activate</button>';
      var tc = ((byLayout[L] || []).length);
      html += '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="deleteLayout(\'' + escHtml(L) + '\',' + tc + ')">Delete</button>';
    } else {
      html += '<span class="mg-file-meta">active - cannot delete</span>';
    }
    html += '</div></div>';

    var themes = (byLayout[L] || []).slice().sort();
    if (!themes.length) {
      html += '<div class="mg-handler-item"><span class="mg-empty">No themes for this layout.</span></div>';
    }
    for (var i = 0; i < themes.length; i++) {
      var t = themes[i], isActiveT = (isActiveL && t === ACTIVE_THEME);
      html += '<div class="mg-handler-item"><div class="mg-handler-item-header">';
      html += '<span class="mg-handler-name">' + escHtml(t) + '</span>';
      if (isActiveT) html += '<span class="mg-badge mg-badge-success">active</span>';
      html += '<span style="flex:1;"></span><div class="mg-handler-item-actions">';
      if (!isActiveT) {
        html += '<button class="mg-btn mg-btn-sm" onclick="previewTheme(\'' + escHtml(t) + '\',\'' + escHtml(L) + '\')">Preview</button>';
      }
      if (isActiveL) {
        if (isActiveT) {
          html += '<button class="mg-btn mg-btn-sm" onclick="deactivateTheme()">Deactivate</button>';
        } else {
          html += '<button class="mg-btn mg-btn-sm mg-btn-primary" onclick="activateThemeOnly(\'' + escHtml(t) + '\')">Activate</button>';
          html += '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="deleteTheme(\'' + escHtml(t) + '\')">Delete</button>';
        }
      }
      html += '</div></div></div>';
    }
    html += '</div>';
  }
  box.innerHTML = html;
}

function activateLayout(name) {
  mgConfirm('Activate layout "' + name + '"? Its default theme is used; cached pages clear.',
    { ok: 'Activate' }).then(function(ok) {
    if (!ok) return;
    fetch(API + '?action=layout-activate&path=' + encodeURIComponent(name), { method: 'POST' })
      .then(function(r){ return r.json(); }).then(function(d) {
        if (!d.ok) { showStatus(d.error, true); return; }
        showStatus('Layout "' + name + '" activated.'); loadAll();
      }).catch(function(e){ showStatus('Error: ' + e.message, true); });
  });
}

function deleteLayout(name, themeCount) {
  var extra = themeCount > 0
    ? ' This also deletes its ' + themeCount + ' theme' + (themeCount === 1 ? '' : 's') + '.'
    : '';
  mgConfirm('Delete layout "' + name + '"?' + extra + ' A backup is kept. This cannot be undone from the UI.',
    { danger: true, ok: 'Delete' }).then(function(ok) {
    if (!ok) return;
    fetch(API + '?action=layout-delete&path=' + encodeURIComponent(name), { method: 'POST' })
      .then(function(r){ return r.json(); }).then(function(d) {
        if (!d.ok) { showStatus(d.error, true); return; }
        var n = (d.themes_removed || []).length;
        showStatus('Deleted layout "' + name + '"'
          + (n ? ' and ' + n + ' theme' + (n === 1 ? '' : 's') : '') + '.');
        loadAll();
      }).catch(function(e){ showStatus('Error: ' + e.message, true); });
  });
}

function activateThemeOnly(name) {
  fetch(API + '?action=theme-activate&path=' + encodeURIComponent(name), { method: 'POST' })
    .then(function(r){ return r.json(); }).then(function(d) {
      if (!d.ok) { showStatus(d.error, true); return; }
      showStatus('Theme "' + name + '" activated.'); loadAll();
    }).catch(function(e){ showStatus('Error: ' + e.message, true); });
}

function deactivateTheme() {
  mgConfirm('Deactivate theme and use the built-in fallback?', { ok: 'Deactivate' }).then(function(ok) {
    if (!ok) return;
    fetch(API + '?action=theme-activate&path=', { method: 'POST' })
      .then(function(r){ return r.json(); }).then(function(d) {
        if (!d.ok) { showStatus(d.error, true); return; }
        showStatus('Theme deactivated.'); loadAll();
      }).catch(function(e){ showStatus('Error: ' + e.message, true); });
  });
}

function deleteTheme(name) {
  mgConfirm('Delete theme "' + name + '"? This cannot be undone.', { danger: true, ok: 'Delete' }).then(function(ok) {
    if (!ok) return;
    fetch(API + '?action=theme-delete&path=' + encodeURIComponent(name), { method: 'POST' })
      .then(function(r){ return r.json(); }).then(function(d) {
        if (!d.ok) { showStatus(d.error, true); return; }
        showStatus('Theme deleted.'); loadAll();
      }).catch(function(e){ showStatus('Error: ' + e.message, true); });
  });
}

function previewTheme(name, layout) {
  fetch(API + '?action=preview-grant&layout=' + encodeURIComponent(layout)
            + '&theme=' + encodeURIComponent(name), { method: 'POST' })
    .then(function(r){ return r.json(); }).then(function(d) {
      if (!d.ok) { showStatus(d.error, true); return; }
      showStatus('Previewing "' + name + '" - opening the site in a new tab.');
      syncStopPreview(); window.open('/', '_blank');
    }).catch(function(e){ showStatus('Error: ' + e.message, true); });
}

function clearPreview() {
  fetch(API + '?action=preview-clear', { method: 'POST' })
    .then(function(r){ return r.json(); }).then(function(d) {
      if (!d.ok) { showStatus(d.error, true); return; }
      showStatus('Preview cleared.'); syncStopPreview();
    }).catch(function(e){ showStatus('Error: ' + e.message, true); });
}

function syncStopPreview() {
  var on = /(?:^|;\s*)lzs_preview_active=1(?:;|$)/.test(document.cookie);
  var btn = document.getElementById('lzs-stop-preview');
  if (btn) btn.style.display = on ? '' : 'none';
}

// --- Upload a theme ---
function uploadTheme() {
  var fi = document.getElementById('theme-file');
  if (!fi.files.length) { showStatus('Select a .zip file first.', true); return; }
  var file = fi.files[0];
  if (!/\.zip$/i.test(file.name)) { showStatus('File must be a .zip archive.', true); return; }
  var reader = new FileReader();
  reader.onload = function(e) {
    fetch(API + '?action=theme-upload&filename=' + encodeURIComponent(file.name),
      { method: 'POST', body: e.target.result })
      .then(function(r){ return r.json(); }).then(function(d) {
        if (!d.ok) { showStatus(d.error, true); return; }
        showStatus('Theme uploaded: ' + (d.name || file.name));
        fi.value = ''; loadAll();
      }).catch(function(err){ showStatus('Upload failed: ' + err.message, true); });
  };
  reader.readAsArrayBuffer(file);
}

// --- Layouts repo setting ---
function loadLayoutsRepo() {
  fetch(API + '?action=layouts-repo-get').then(function(r){ return r.json(); })
    .then(function(d) {
      var input = document.getElementById('layouts-repo-input');
      if (input && d && d.ok && d.value) input.value = d.value;
    }).catch(function(){});
}

function saveLayoutsRepo() {
  var input = document.getElementById('layouts-repo-input');
  if (!input) return;
  var value = (input.value || '').trim();
  fetch(API + '?action=layouts-repo-set', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ value: value })
  }).then(function(r){ return r.json(); }).then(function(d) {
    if (!d.ok) { showStatus(d.error || 'Save failed.', true); return; }
    showStatus(value ? ('Layouts repo saved: ' + value) : 'Layouts repo cleared.');
  }).catch(function(e){ showStatus('Error: ' + e.message, true); });
}

// --- Browse the repo catalogue (manifest) ---
function loadCatalogue() {
  var box = document.getElementById('catalogue');
  box.innerHTML = '<span class="mg-empty">Loading catalogue...</span>';
  fetch(API + '?action=layouts-manifest').then(function(r){ return r.json(); })
    .then(function(d) {
      if (!d.ok) { box.innerHTML = ''; showStatus(d.error || 'Could not load catalogue.', true); return; }
      renderCatalogue(d.layouts || []);
    }).catch(function(e){ box.innerHTML = ''; showStatus('Error: ' + e.message, true); });
}

function renderCatalogue(layouts) {
  var box = document.getElementById('catalogue');
  if (!layouts.length) { box.innerHTML = '<span class="mg-empty">No layouts in the repo manifest.</span>'; return; }
  var html = '';
  for (var i = 0; i < layouts.length; i++) {
    var L = layouts[i];
    var cid = 'cat-' + L.name.replace(/[^A-Za-z0-9_-]/g, '_');
    html += '<div class="mg-file-item">';
    html += '<span class="mg-file-name">' + escHtml(L.name) + '</span>';
    if (L.version) html += '<span class="mg-badge">' + escHtml(L.version) + '</span>';
    if (L.installed) html += '<span class="mg-badge mg-badge-success">installed</span>';
    html += '<div class="mg-file-actions">';
    html += '<button class="mg-btn mg-btn-sm" onclick="toggleCat(\'' + cid + '\')">Themes</button>';
    if (L.installed) {
      html += '<button class="mg-btn mg-btn-sm" onclick="installLayout(\'' + escHtml(L.name) + '\',\'\',true)">Update</button>';
    } else {
      html += '<button class="mg-btn mg-btn-sm mg-btn-primary" onclick="installLayout(\'' + escHtml(L.name) + '\',\'\')">Install</button>';
    }
    html += '</div></div>';
    // Per-theme rows (install a specific theme into the layout).
    html += '<div id="' + cid + '" hidden style="margin:0 0 0.5rem 1rem;">';
    var ths = L.themes || [];
    for (var j = 0; j < ths.length; j++) {
      var t = ths[j];
      html += '<div class="mg-file-item"><span class="mg-file-name">' + escHtml(t.name) + '</span>';
      if (t.name === L.default_theme) html += '<span class="mg-file-meta">default</span>';
      html += '<div class="mg-file-actions">';
      if (t.installed) {
        html += '<span class="mg-badge mg-badge-success">installed</span>';
      } else {
        html += '<button class="mg-btn mg-btn-sm" onclick="installLayout(\''
          + escHtml(L.name) + '\',\'' + escHtml(t.name) + '\')">Install</button>';
      }
      html += '</div></div>';
    }
    html += '</div>';
  }
  box.innerHTML = html;
}

function toggleCat(id) { var el = document.getElementById(id); if (el) el.hidden = !el.hidden; }

function installLayout(layout, theme, update) {
  var label = 'layout "' + layout + '"' + (theme ? ' / theme "' + theme + '"' : ' (default theme)');
  var verb = update ? 'Update' : 'Install';
  mgConfirm(verb + ' ' + label + ' and activate it?', { ok: verb }).then(function(ok) {
    if (!ok) return;
    showStatus(verb + 'ing ' + label + '...');
    fetch(API + '?action=layout-install', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ layout: layout, theme: theme, update: update ? true : false })
    }).then(function(r){ return r.json(); }).then(function(d) {
      if (!d.ok) { showStatus(d.error || 'Install failed.', true); return; }
      var n = (d.themes_installed || []).length;
      var msg = 'Installed ' + layout + ' with ' + n + ' theme' + (n === 1 ? '' : 's');
      if (d.theme_errors && d.theme_errors.length) {
        showStatus(msg + ' - ' + d.theme_errors.join('; '), true);
      } else {
        showStatus(msg + (d.activated ? ' and activated.' : '.'));
      }
      loadAll(); loadCatalogue();
    }).catch(function(e){ showStatus('Install failed: ' + e.message, true); });
  });
}

loadAll();
loadLayoutsRepo();
syncStopPreview();
</script>
