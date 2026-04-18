---
title: Edit Page
auth: editor
search: false
query_params:
  - path
  - new
---

<div>
<style>
.edit-wrap { font-family: system-ui, sans-serif; max-width: 100%; }
.edit-header { display: flex; align-items: center; gap: 12px; margin-bottom: 8px; flex-wrap: wrap; }
.edit-header h2 { margin: 0; font-size: 16px; font-weight: normal; color: #333; }
.edit-header button { padding: 4px 14px; cursor: pointer; }
.edit-header .save-btn { font-weight: bold; }
.edit-header .back-link { text-decoration: none; color: #07c; font-size: 14px; }
.edit-panes { display: flex; gap: 8px; height: calc(100vh - 220px); min-height: 400px; }
.edit-left { flex: 1; display: flex; flex-direction: column; min-width: 0; }
.edit-right { flex: 1; min-width: 0; border: 1px solid #ccc; border-radius: 4px; }
.edit-right iframe { width: 100%; height: 100%; border: none; }
.fm-section { border: 1px solid #ccc; border-radius: 4px; padding: 8px; margin-bottom: 8px; background: #f8f8f8; }
.fm-section summary { cursor: pointer; font-weight: bold; font-size: 14px; }
.fm-row { display: flex; gap: 8px; margin-top: 6px; align-items: center; }
.fm-row label { width: 100px; font-size: 13px; text-align: right; flex-shrink: 0; }
.fm-row input, .fm-row select { flex: 1; padding: 3px 6px; font-size: 13px; font-family: system-ui, sans-serif; }
.content-area { flex: 1; display: flex; flex-direction: column; }
.content-area textarea { flex: 1; width: 100%; font-family: monospace; font-size: 13px; padding: 8px; border: 1px solid #ccc; border-radius: 4px; resize: none; box-sizing: border-box; tab-size: 2; }
.status-msg { padding: 6px 10px; margin-bottom: 8px; border-radius: 4px; font-size: 13px; }
.status-msg.error { background: #fee; color: #c00; }
.status-msg.ok { background: #efe; color: #060; }
.status-msg.warn { background: #ffd; color: #860; }
.lock-info { font-size: 12px; color: #888; }
.dirty-indicator { color: #c60; font-weight: bold; font-size: 14px; }
</style>
</div>

<div class="edit-wrap" id="app">

<div class="edit-header">
<a href="/editor/" class="back-link">&#8592; Files</a>
<h2 id="file-path">Loading...</h2>
<span id="dirty-flag" class="dirty-indicator" style="display:none;">&#9679; unsaved</span>
<button class="save-btn" onclick="save()">Save</button>
<span class="lock-info" id="lock-info"></span>
</div>

<div id="status"></div>

<div class="edit-panes">
<div class="edit-left">

<details class="fm-section" open>
<summary>Front Matter</summary>
<div class="fm-row"><label>title</label><input type="text" id="fm-title" oninput="markDirty()"></div>
<div class="fm-row"><label>subtitle</label><input type="text" id="fm-subtitle" oninput="markDirty()"></div>
<div class="fm-row"><label>auth</label><select id="fm-auth" onchange="markDirty()"><option value="">none</option><option value="required">required</option><option value="optional">optional</option></select></div>
<div class="fm-row"><label>auth_groups</label><span id="fm-auth-groups" style="display:flex;flex-wrap:wrap;gap:4px 12px;font-size:13px;">Loading...</span></div>
<div class="fm-row"><label>search</label><select id="fm-search" onchange="markDirty()"><option value="">default</option><option value="true">true</option><option value="false">false</option></select></div>
<div class="fm-row"><label>layout</label><select id="fm-layout" onchange="markDirty()"><option value="">default</option></select></div>
<div class="fm-row"><label>extra YAML</label><textarea id="fm-extra" rows="3" style="flex:1; font-family:monospace; font-size:12px; resize:vertical;" oninput="markDirty()"></textarea></div>
</details>

<div class="content-area">
<textarea id="content" oninput="markDirty(); schedulePreview();" placeholder="Page content..."></textarea>
</div>

</div>

<div class="edit-right">
<iframe id="preview-frame" srcdoc="<p style='color:#888;font-family:system-ui;padding:20px;'>Preview loads after opening a file.</p>"></iframe>
</div>
</div>

</div>

<script>
var API = '/cgi-bin/lazysite-editor-api.pl';
var filePath = '[% query.path | html %]';
var isNew = '[% query.new | html %]' === '1';
var serverMtime = null;
var lockId = null;
var lockTimer = null;
var dirty = false;
var previewTimer = null;

var knownFmKeys = ['title', 'subtitle', 'auth', 'auth_groups', 'search', 'layout'];

function showStatus(msg, cls) {
  var el = document.getElementById('status');
  el.className = 'status-msg ' + (cls || 'ok');
  el.textContent = msg;
  if (cls !== 'error') setTimeout(function() { el.textContent = ''; el.className = ''; }, 4000);
}

function markDirty() {
  dirty = true;
  document.getElementById('dirty-flag').style.display = 'inline';
}

function clearDirty() {
  dirty = false;
  document.getElementById('dirty-flag').style.display = 'none';
}

window.addEventListener('beforeunload', function(e) {
  if (dirty) { e.preventDefault(); e.returnValue = ''; }
});

// --- Lock management ---
function acquireLock() {
  fetch(API + '?action=lock&path=' + encodeURIComponent(filePath))
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (data.locked) {
        document.getElementById('lock-info').textContent = 'Locked by ' + data.locked_by;
        return;
      }
      if (data.ok) {
        document.getElementById('lock-info').textContent = 'Editing';
        lockTimer = setInterval(renewLock, 60000);
      }
    })
    .catch(function() {});
}

function renewLock() {
  fetch(API + '?action=renew-lock&path=' + encodeURIComponent(filePath))
    .catch(function() {});
}

function releaseLock() {
  if (navigator.sendBeacon) {
    navigator.sendBeacon(API + '?action=unlock&path=' + encodeURIComponent(filePath));
  } else {
    var xhr = new XMLHttpRequest();
    xhr.open('GET', API + '?action=unlock&path=' + encodeURIComponent(filePath), false);
    xhr.send();
  }
}

window.addEventListener('unload', releaseLock);
window.addEventListener('pagehide', releaseLock);

// --- Front matter parsing ---
function parseFrontMatter(text) {
  var match = text.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  if (!match) return { yaml: {}, extra: '', content: text };

  var yamlText = match[1];
  var content = match[2];
  var yaml = {};
  var extraLines = [];

  var lines = yamlText.split('\n');
  var currentListKey = null;
  var listValues = [];
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    // Check for list item under a known key
    var listItem = line.match(/^\s+-\s+(.+)$/);
    if (listItem && currentListKey) {
      listValues.push(listItem[1].trim());
      continue;
    }
    // Flush previous list
    if (currentListKey) {
      yaml[currentListKey] = listValues.join(', ');
      currentListKey = null;
      listValues = [];
    }
    var kv = line.match(/^(\w[\w_-]*)\s*:\s*(.*)$/);
    if (kv && knownFmKeys.indexOf(kv[1]) !== -1) {
      if (kv[2].trim() === '') {
        // Could be start of a list block
        currentListKey = kv[1];
        listValues = [];
      } else {
        yaml[kv[1]] = kv[2].trim();
      }
    } else {
      extraLines.push(line);
    }
  }
  if (currentListKey) {
    yaml[currentListKey] = listValues.join(', ');
  }
  return { yaml: yaml, extra: extraLines.join('\n').trim(), content: content };
}

function buildFrontMatter() {
  var lines = [];
  var title = document.getElementById('fm-title').value;
  var subtitle = document.getElementById('fm-subtitle').value;
  var auth = document.getElementById('fm-auth').value;
  var authGroupChecks = document.querySelectorAll('#fm-auth-groups input[type=checkbox]:checked');
  var authGroups = Array.from(authGroupChecks).map(function(cb) { return cb.value; });
  var search = document.getElementById('fm-search').value;
  var layout = document.getElementById('fm-layout').value;
  var extra = document.getElementById('fm-extra').value.trim();

  if (title) lines.push('title: ' + title);
  if (subtitle) lines.push('subtitle: ' + subtitle);
  if (auth) lines.push('auth: ' + auth);
  if (authGroups.length) {
    lines.push('auth_groups:');
    authGroups.forEach(function(g) { lines.push('  - ' + g); });
  }
  if (search) lines.push('search: ' + search);
  if (layout) lines.push('layout: ' + layout);
  if (extra) lines.push(extra);

  return '---\n' + lines.join('\n') + '\n---\n';
}

function buildFullContent() {
  return buildFrontMatter() + document.getElementById('content').value;
}

// --- Load file ---
function loadFile() {
  document.getElementById('file-path').textContent = filePath;

  if (isNew) {
    document.getElementById('fm-title').value = 'New Page';
    document.getElementById('content').value = '\nNew page content.\n';
    markDirty();
    acquireLock();
    return;
  }

  fetch(API + '?action=read&path=' + encodeURIComponent(filePath))
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error || 'Failed to load file', 'error'); return; }
      serverMtime = data.mtime;
      var parsed = parseFrontMatter(data.content || '');
      document.getElementById('fm-title').value = parsed.yaml.title || '';
      document.getElementById('fm-subtitle').value = parsed.yaml.subtitle || '';
      document.getElementById('fm-auth').value = parsed.yaml.auth || '';
      document.getElementById('fm-layout').value = parsed.yaml.layout || '';
      // Check auth_groups checkboxes if present in YAML
      if (parsed.yaml.auth_groups) {
        var groups = parsed.yaml.auth_groups.split(/\s*,\s*/).filter(Boolean);
        document.querySelectorAll('#fm-auth-groups input[type=checkbox]').forEach(function(cb) {
          cb.checked = groups.indexOf(cb.value) >= 0;
        });
      }
      var searchVal = parsed.yaml.search || '';
      document.getElementById('fm-search').value = searchVal;
      document.getElementById('fm-extra').value = parsed.extra;
      document.getElementById('content').value = parsed.content;
      clearDirty();
      acquireLock();
      schedulePreview();
    })
    .catch(function(e) { showStatus('Failed to load: ' + e.message, 'error'); });
}

// --- Save ---
function save() {
  var fullContent = buildFullContent();
  var payload = {
    content: fullContent,
    mtime: serverMtime || null
  };

  fetch(API + '?action=save&path=' + encodeURIComponent(filePath), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload)
  })
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) {
        if (data.conflict) {
          showStatus('Save conflict: file was modified by another user.', 'error');
        } else {
          showStatus(data.error || 'Save failed', 'error');
        }
        return;
      }
      serverMtime = data.mtime;
      clearDirty();
      showStatus('Saved.');
      updatePreview();
    })
    .catch(function(e) { showStatus('Save failed: ' + e.message, 'error'); });
}

// --- Preview ---
function schedulePreview() {
  if (previewTimer) clearTimeout(previewTimer);
  previewTimer = setTimeout(updatePreview, 800);
}

var previewLoaded = false;
var isMdFile = filePath && /\.md$/i.test(filePath);

function updatePreview() {
  if (!filePath || !isMdFile) return;
  previewLoaded = true;
  var pageUrl = filePath.replace(/\.md$/, '').replace(/\/index$/, '/');
  if (pageUrl.charAt(0) !== '/') pageUrl = '/' + pageUrl;
  pageUrl += (pageUrl.indexOf('?') >= 0 ? '&' : '?') + '_t=' + Date.now();
  var frame = document.getElementById('preview-frame');
  frame.removeAttribute('srcdoc');
  frame.src = pageUrl;
}

// --- Keyboard shortcut ---
document.addEventListener('keydown', function(e) {
  if ((e.ctrlKey || e.metaKey) && e.key === 's') {
    e.preventDefault();
    save();
  }
});

// Populate layout dropdown from installed themes
fetch(API + '?action=theme-list')
  .then(function(r) { return r.json(); })
  .then(function(data) {
    if (!data.ok) return;
    var sel = document.getElementById('fm-layout');
    (data.themes || []).forEach(function(t) {
      if (t.valid) {
        var opt = document.createElement('option');
        opt.value = t.name;
        opt.textContent = t.name;
        sel.appendChild(opt);
      }
    });
    if (sel.options.length <= 1) {
      var opt = document.createElement('option');
      opt.value = '';
      opt.textContent = 'No views installed';
      opt.disabled = true;
      sel.appendChild(opt);
    }
  }).catch(function() {});

// Populate auth_groups dropdown from known groups
fetch(API + '?action=users', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ action: 'groups' })
})
  .then(function(r) { return r.json(); })
  .then(function(data) {
    var container = document.getElementById('fm-auth-groups');
    container.innerHTML = '';
    if (!data.ok || !data.groups || Object.keys(data.groups).length === 0) {
      container.textContent = 'No groups defined';
      return;
    }
    Object.keys(data.groups).sort().forEach(function(g) {
      var lbl = document.createElement('label');
      lbl.style.cssText = 'display:flex;align-items:center;gap:3px;cursor:pointer;';
      var cb = document.createElement('input');
      cb.type = 'checkbox';
      cb.value = g;
      cb.onchange = markDirty;
      lbl.appendChild(cb);
      lbl.appendChild(document.createTextNode(g));
      container.appendChild(lbl);
    });
  }).catch(function() {
    document.getElementById('fm-auth-groups').textContent = 'Groups unavailable';
  });

// Hide preview and front matter for non-.md files
if (!isMdFile) {
  document.querySelector('.edit-right').style.display = 'none';
  document.querySelector('.edit-left').style.flex = '1 1 100%';
  document.querySelector('.fm-section').style.display = 'none';
  document.getElementById('preview-frame').srcdoc = '<p style="color:#888;font-family:system-ui;padding:20px;">Preview not available for this file type.</p>';
}

if (filePath) {
  loadFile();
  if (isMdFile) {
    setTimeout(function() {
      if (!previewLoaded) updatePreview();
    }, 2000);
  }
} else {
  showStatus('No file path specified.', 'error');
}
</script>
