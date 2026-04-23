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

<div class="mg-card">
<div class="mg-card-header">
<span class="mg-card-title">Install from Releases</span>
</div>
<div class="mg-card-body">
<p class="mg-card-subtitle" style="margin:0 0 8px 0;">Install themes from a published release of the layouts repository. The release repo must use the D013 nested shape (themes at <code>layouts/LAYOUT/themes/THEME/</code>). Each install pulls every valid theme in the release.</p>
<div class="mg-form-row mg-config-field" style="margin-bottom:0.75rem;">
<label for="layouts-repo-input">Layouts repo</label>
<input type="text" id="layouts-repo-input" placeholder="OpenDigitalCC/lazysite-layouts" style="flex:1;">
<button class="mg-btn mg-btn-outline mg-btn-sm" onclick="saveLayoutsRepo()">Save</button>
</div>
<div style="display:flex;gap:0.5rem;align-items:center;margin-bottom:0.5rem;">
<button class="mg-btn mg-btn-outline" onclick="loadReleases()">Browse releases</button>
</div>
<div id="release-list"></div>
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

// SM044: read/write the layouts_repo conf key via dedicated endpoints.
// loadLayoutsRepo runs on page init; saveLayoutsRepo is wired to the
// Save button beside the input.
//
// SM048: the original loadLayoutsRepo unconditionally assigned
// input.value to the server response, including when the server
// returned an empty string (key unset). A user who typed into the
// field before the async fetch completed had their input clobbered.
// Fix: only populate from the server when a non-empty value is
// returned. Empty response = key unset = leave the input alone.
function loadLayoutsRepo() {
  fetch(API + '?action=layouts-repo-get')
    .then(function(r) { return r.json(); })
    .then(function(data) {
      var input = document.getElementById('layouts-repo-input');
      if (!input) return;
      if (data && data.ok && data.value) {
        input.value = data.value;
      }
      // else: server has no value to restore - don't touch the input,
      // preserving whatever the user may have typed during the fetch.
    })
    .catch(function() {
      // Non-fatal; leave the input alone (may contain user input).
    });
}

function saveLayoutsRepo() {
  var input = document.getElementById('layouts-repo-input');
  if (!input) return;
  var value = (input.value || '').trim();
  fetch(API + '?action=layouts-repo-set', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ value: value })
  })
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) {
        showStatus(data.error || 'Save failed.', true);
        return;
      }
      // SM048: unambiguous feedback on whether the operator saved
      // a value or actively cleared the key.
      if (value) {
        showStatus('Layouts repo saved: ' + value);
      } else {
        showStatus('Layouts repo cleared.');
      }
    })
    .catch(function(e) {
      showStatus('Error: ' + e.message, true);
    });
}

// SM037 / D013: browse releases of the configured layouts repo and
// install themes from a chosen release. layouts-releases is GET so
// anonymous GitHub rate limits (60/hour) apply to the lazysite host,
// not visitors — the browse action is gated behind an explicit click
// rather than auto-loaded on page view to keep the rate budget.
function loadReleases() {
  var container = document.getElementById('release-list');
  container.innerHTML = '<div class="mg-file-item"><span class="mg-file-name">Loading...</span></div>';
  fetch(API + '?action=layouts-releases')
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) {
        container.innerHTML = '';
        showStatus(data.error || 'Unable to fetch releases. Check the Layouts repo setting above.', true);
        return;
      }
      renderReleases(data.releases || [], data.repo || '');
    })
    .catch(function(e) {
      container.innerHTML = '';
      showStatus('Error: ' + e.message, true);
    });
}

function renderReleases(releases, repo) {
  var container = document.getElementById('release-list');
  if (!releases.length) {
    container.innerHTML = '<div class="mg-file-item"><span class="mg-file-name mg-empty">No releases found in ' + escHtml(repo) + '</span></div>';
    return;
  }
  var html = '';
  for (var i = 0; i < releases.length; i++) {
    var r = releases[i];
    var tag = r.tag_name || '';
    var name = r.name || tag;
    var date = (r.published_at || '').split('T')[0];
    // SM058: release body (GitHub release description). Rendered
    // as preformatted text under the tag row so Markdown in the
    // body displays readably without pulling in a markdown
    // renderer. Keeping it simple per briefing.
    var body = r.body || '';
    // SM056: per-release "show contents" affordance. tagSafe used
    // to build both the inline onclick arg and the container id.
    var tagSafe = escHtml(tag);
    var contentsId = 'rc-' + tag.replace(/[^A-Za-z0-9._-]/g, '_');

    html += '<div class="mg-release" data-tag="' + tagSafe + '">';
    html += '<div class="mg-file-item">';
    html += '<span class="mg-file-name">' + escHtml(name) + '</span>';
    if (tag) {
      html += '<span class="mg-badge">' + tagSafe + '</span>';
    }
    if (date) {
      html += '<span class="mg-file-meta">' + escHtml(date) + '</span>';
    }
    html += '<div class="mg-file-actions">';
    html += '<button class="mg-btn mg-btn-sm" onclick="toggleReleaseContents(\'' + tagSafe + '\',\'' + contentsId + '\')">Contents</button>';
    html += '<button class="mg-btn mg-btn-sm mg-btn-primary" onclick="installRelease(\'' + tagSafe + '\')">Install</button>';
    html += '</div>';
    html += '</div>';
    if (body) {
      html += '<pre class="mg-release-body" style="white-space:pre-wrap;'
           +  'font-family:inherit;font-size:0.85rem;color:var(--mg-text-muted);'
           +  'background:var(--mg-surface-alt);padding:0.5rem 0.75rem;'
           +  'border-radius:4px;margin:0.25rem 0 0.5rem;">'
           +  escHtml(body) + '</pre>';
    }
    html += '<div id="' + contentsId + '" class="mg-release-contents" '
         +  'style="margin:0 0 0.75rem 0.5rem;font-size:0.85rem;" hidden></div>';
    html += '</div>';
  }
  container.innerHTML = html;
}

// SM056: lazy-fetch the theme list for one release. First click
// fetches and renders; subsequent clicks toggle visibility without
// re-fetching.
function toggleReleaseContents(tag, contentsId) {
  var el = document.getElementById(contentsId);
  if (!el) return;
  if (el.dataset.loaded === '1') {
    el.hidden = !el.hidden;
    return;
  }
  el.hidden = false;
  el.innerHTML = '<span class="mg-empty">Loading contents...</span>';
  fetch(API + '?action=layouts-release-contents&tag=' + encodeURIComponent(tag))
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) {
        el.innerHTML = '<span class="mg-empty">'
          + escHtml(data.error || 'Unable to list contents.') + '</span>';
        return;
      }
      var themes = data.themes || [];
      if (!themes.length) {
        el.innerHTML = '<span class="mg-empty">(no themes in this release)</span>';
        el.dataset.loaded = '1';
        return;
      }
      var rows = '';
      for (var i = 0; i < themes.length; i++) {
        var t = themes[i];
        rows += '<li style="margin:0.25rem 0;"><strong>'
             +  escHtml(t.name) + '</strong>'
             +  ' <span class="mg-file-meta">(' + escHtml(t.layout) + ')</span>';
        if (t.description) {
          rows += '<div style="color:var(--mg-text-muted);margin-left:1rem;">'
               +  escHtml(t.description) + '</div>';
        }
        rows += '</li>';
      }
      el.innerHTML = '<ul style="margin:0;padding-left:1.25rem;">'
        + rows + '</ul>';
      el.dataset.loaded = '1';
    })
    .catch(function(e) {
      el.innerHTML = '<span class="mg-empty">Error: '
        + escHtml(e.message) + '</span>';
    });
}

function installRelease(tag) {
  if (!tag) { showStatus('Missing tag.', true); return; }
  if (!confirm('Install themes from release "' + tag + '"?')) return;
  showStatus('');
  var prev = document.getElementById('release-list').innerHTML;
  document.getElementById('release-list').innerHTML = '<div class="mg-file-item"><span class="mg-file-name">Installing ' + escHtml(tag) + '...</span></div>';
  fetch(API + '?action=layouts-install', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ tag: tag })
  })
    .then(function(r) { return r.json(); })
    .then(function(data) {
      document.getElementById('release-list').innerHTML = prev;
      if (!data.ok) { showStatus(data.error || 'Install failed.', true); return; }
      var themes = data.themes || [];
      var ok = 0, fail = 0;
      for (var i = 0; i < themes.length; i++) { if (themes[i].ok) ok++; else fail++; }
      var msg = 'Installed ' + ok + ' theme' + (ok === 1 ? '' : 's') + ' from ' + tag;
      if (fail) { msg += ' (' + fail + ' failed)'; }
      if (fail) {
        var parts = [];
        for (var j = 0; j < themes.length; j++) {
          if (!themes[j].ok) {
            parts.push(themes[j].source + ': ' + (themes[j].error || 'failed'));
          }
        }
        showStatus(msg + ' — ' + parts.join('; '), true);
      } else {
        showStatus(msg + '.');
      }
      loadThemes();
    })
    .catch(function(e) {
      document.getElementById('release-list').innerHTML = prev;
      showStatus('Install failed: ' + e.message, true);
    });
}

loadThemes();
loadLayoutsRepo();
</script>
