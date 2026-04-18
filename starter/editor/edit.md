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
<div class="fm-row"><label>auth</label><input type="text" id="fm-auth" placeholder="none, login, editor, admin" oninput="markDirty()"></div>
<div class="fm-row"><label>search</label><select id="fm-search" onchange="markDirty()"><option value="">default</option><option value="true">true</option><option value="false">false</option></select></div>
<div class="fm-row"><label>view</label><input type="text" id="fm-view" oninput="markDirty()"></div>
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

var knownFmKeys = ['title', 'subtitle', 'auth', 'search', 'view'];

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
  fetch(API + '?action=lock', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ path: filePath })
  })
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (data.error) {
        document.getElementById('lock-info').textContent = 'Lock: ' + data.error;
        return;
      }
      lockId = data.lock_id;
      document.getElementById('lock-info').textContent = 'Lock acquired';
      lockTimer = setInterval(renewLock, 60000);
    })
    .catch(function() {});
}

function renewLock() {
  if (!lockId) return;
  fetch(API + '?action=lock_renew', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ path: filePath, lock_id: lockId })
  }).catch(function() {});
}

function releaseLock() {
  if (!lockId) return;
  var data = JSON.stringify({ path: filePath, lock_id: lockId });
  if (navigator.sendBeacon) {
    var blob = new Blob([data], { type: 'application/json' });
    navigator.sendBeacon(API + '?action=lock_release', blob);
  } else {
    var xhr = new XMLHttpRequest();
    xhr.open('POST', API + '?action=lock_release', false);
    xhr.setRequestHeader('Content-Type', 'application/json');
    xhr.send(data);
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
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i];
    var kv = line.match(/^(\w[\w_-]*)\s*:\s*(.*)$/);
    if (kv && knownFmKeys.indexOf(kv[1]) !== -1) {
      yaml[kv[1]] = kv[2].trim();
    } else {
      extraLines.push(line);
    }
  }
  return { yaml: yaml, extra: extraLines.join('\n').trim(), content: content };
}

function buildFrontMatter() {
  var lines = [];
  var title = document.getElementById('fm-title').value;
  var subtitle = document.getElementById('fm-subtitle').value;
  var auth = document.getElementById('fm-auth').value;
  var search = document.getElementById('fm-search').value;
  var view = document.getElementById('fm-view').value;
  var extra = document.getElementById('fm-extra').value.trim();

  if (title) lines.push('title: ' + title);
  if (subtitle) lines.push('subtitle: ' + subtitle);
  if (auth) lines.push('auth: ' + auth);
  if (search) lines.push('search: ' + search);
  if (view) lines.push('view: ' + view);
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
      if (data.error) { showStatus(data.error, 'error'); return; }
      serverMtime = data.mtime;
      var parsed = parseFrontMatter(data.content || '');
      document.getElementById('fm-title').value = parsed.yaml.title || '';
      document.getElementById('fm-subtitle').value = parsed.yaml.subtitle || '';
      document.getElementById('fm-auth').value = parsed.yaml.auth || '';
      document.getElementById('fm-view').value = parsed.yaml.view || '';
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
    path: filePath,
    content: fullContent
  };
  if (serverMtime) payload.expected_mtime = serverMtime;
  if (lockId) payload.lock_id = lockId;

  fetch(API + '?action=save', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload)
  })
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (data.error) {
        if (data.conflict) {
          showStatus('Save conflict: file was modified by another user. Reload to see their changes, or save again to overwrite.', 'error');
        } else {
          showStatus(data.error, 'error');
        }
        return;
      }
      serverMtime = data.mtime;
      clearDirty();
      showStatus('Saved.');
    })
    .catch(function(e) { showStatus('Save failed: ' + e.message, 'error'); });
}

// --- Preview ---
function schedulePreview() {
  if (previewTimer) clearTimeout(previewTimer);
  previewTimer = setTimeout(updatePreview, 800);
}

function updatePreview() {
  var fullContent = buildFullContent();
  fetch(API + '?action=preview', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ path: filePath, content: fullContent })
  })
    .then(function(r) { return r.text(); })
    .then(function(html) {
      var frame = document.getElementById('preview-frame');
      frame.srcdoc = html;
    })
    .catch(function() {});
}

// --- Keyboard shortcut ---
document.addEventListener('keydown', function(e) {
  if ((e.ctrlKey || e.metaKey) && e.key === 's') {
    e.preventDefault();
    save();
  }
});

if (filePath) {
  loadFile();
} else {
  showStatus('No file path specified.', 'error');
}
</script>
