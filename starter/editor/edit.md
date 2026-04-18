---
title: Edit
search: false
query_params:
  - path
  - new
---

<div id="editor-root">
<link rel="stylesheet" href="/editor/assets/cm/codemirror.min.css">
<style>
#editor-root { position:fixed; inset:0; display:flex; flex-direction:column; font-family:system-ui,sans-serif; font-size:14px; background:#f8f9fa; color:#212529; z-index:9999; }
#ed-toolbar { display:flex; align-items:center; justify-content:space-between; padding:0 1rem; height:44px; background:#fff; border-bottom:1px solid #dee2e6; flex-shrink:0; gap:1rem; }
#ed-toolbar-left, #ed-toolbar-right { display:flex; align-items:center; gap:0.75rem; }
#ed-back { color:#0d6efd; text-decoration:none; font-size:0.875rem; }
#ed-filepath { font-family:ui-monospace,monospace; font-size:0.8rem; color:#6c757d; max-width:300px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.lock-dot { width:8px; height:8px; border-radius:50%; display:inline-block; }
.lock-dot.editing { background:#198754; }
.lock-dot.locked { background:#ffc107; }
#ed-lock-label { font-size:0.8rem; color:#6c757d; }
#ed-shortcut-hint { font-size:0.75rem; color:#adb5bd; }
#ed-toolbar button, #ed-toolbar a { padding:0.3rem 0.75rem; border:1px solid #dee2e6; border-radius:4px; background:#fff; cursor:pointer; font-size:0.875rem; color:#495057; text-decoration:none; }
#ed-toolbar button:hover, #ed-toolbar a:hover { background:#f8f9fa; }
#ed-save-btn.dirty { background:#0d6efd; color:#fff; border-color:#0d6efd; font-weight:600; }
#ed-main { display:flex; flex:1; min-height:0; overflow:hidden; }
#ed-editor-pane { width:50%; display:flex; flex-direction:column; overflow-y:auto; background:#fff; border-right:1px solid #dee2e6; }
#ed-fm-section { border-bottom:1px solid #dee2e6; flex-shrink:0; }
#ed-fm-section summary { padding:0.5rem 1rem; font-size:0.75rem; font-weight:600; text-transform:uppercase; letter-spacing:0.05em; color:#6c757d; cursor:pointer; background:#f8f9fa; user-select:none; }
#ed-fm-fields { padding:0.75rem 1rem; }
.fm-row { display:flex; align-items:flex-start; gap:0.75rem; margin-bottom:0.5rem; }
.fm-row label { width:60px; flex-shrink:0; font-size:0.8rem; color:#6c757d; padding-top:0.3rem; text-align:right; font-family:ui-monospace,monospace; }
.fm-row input, .fm-row select { flex:1; padding:0.25rem 0.5rem; border:1px solid #dee2e6; border-radius:3px; font-size:0.875rem; }
.fm-row input:focus, .fm-row select:focus { outline:none; border-color:#86b7fe; box-shadow:0 0 0 2px rgba(13,110,253,0.15); }
.fm-row-extra { align-items:flex-start; }
#ed-yaml-cm { flex:1; }
#ed-yaml-cm .CodeMirror { font-size:0.8rem; border:1px solid #dee2e6; border-radius:3px; height:auto; min-height:60px; }
#ed-content-section { flex:1; display:flex; flex-direction:column; }
#ed-content-cm { flex:1; }
#ed-content-cm .CodeMirror { height:100%; min-height:400px; font-size:0.875rem; line-height:1.6; font-family:ui-monospace,'Cascadia Code','Fira Code',monospace; border-top:1px solid #dee2e6; }
.cm-tt-variable { color:#c0392b; background:rgba(192,57,43,0.07); border-radius:2px; }
#ed-divider { width:5px; background:#dee2e6; cursor:col-resize; flex-shrink:0; position:relative; }
#ed-divider:hover { background:#adb5bd; }
#ed-preview-pane { flex:1; display:flex; flex-direction:column; background:#fff; min-width:0; }
#ed-preview-toolbar { display:flex; align-items:center; gap:0.5rem; padding:0.3rem 0.75rem; background:#f8f9fa; border-bottom:1px solid #dee2e6; font-size:0.8rem; color:#6c757d; flex-shrink:0; }
#ed-preview-toolbar span { flex:1; }
#ed-preview-status { font-style:italic; }
#ed-preview-frame { flex:1; border:none; width:100%; }
#ed-statusbar { display:flex; align-items:center; gap:1.5rem; padding:0.2rem 1rem; background:#212529; color:#adb5bd; font-size:0.75rem; flex-shrink:0; font-family:ui-monospace,monospace; }
#ed-dirty { color:#ffc107; margin-left:auto; }
#ed-saved { color:#198754; }
body { margin:0 !important; padding:0 !important; max-width:none !important; }
body > .site-bar, body > .site-rule, body > main > h1, body > footer { display:none !important; }
body > main { display:block !important; margin:0 !important; padding:0 !important; }
</style>

<div id="ed-toolbar">
<div id="ed-toolbar-left">
<a href="/editor/" id="ed-back">Manage</a>
<span id="ed-filepath">[% query.path | html %]</span>
<span id="ed-lock-dot" title=""></span>
<span id="ed-lock-label"></span>
</div>
<div id="ed-toolbar-right">
<span id="ed-shortcut-hint">Ctrl+S</span>
<button id="ed-save-btn" onclick="savePage()" disabled>Save</button>
<button onclick="refreshPreview()">Preview</button>
<a id="ed-view-link" href="#" target="_blank">View page</a>
</div>
</div>

<div id="ed-main">
<div id="ed-editor-pane">
<details id="ed-fm-section" open>
<summary>Front Matter</summary>
<div id="ed-fm-fields">
<div class="fm-row"><label>title</label><input type="text" id="fm-title" oninput="syncFmField('title',this.value)"></div>
<div class="fm-row"><label>subtitle</label><input type="text" id="fm-subtitle" oninput="syncFmField('subtitle',this.value)"></div>
<div class="fm-row"><label>auth</label><select id="fm-auth" onchange="syncFmField('auth',this.value)"><option value="">--</option><option value="none">none</option><option value="optional">optional</option><option value="required">required</option></select></div>
<div class="fm-row"><label>search</label><select id="fm-search" onchange="syncFmField('search',this.value)"><option value="">default</option><option value="true">true</option><option value="false">false</option></select></div>
<div class="fm-row fm-row-extra"><label>extra</label><div id="ed-yaml-cm"></div></div>
</div>
</details>
<div id="ed-content-section"><div id="ed-content-cm"></div></div>
</div>
<div id="ed-divider" title="Drag to resize"></div>
<div id="ed-preview-pane">
<div id="ed-preview-toolbar"><span>Preview</span><span id="ed-preview-status">Save to preview</span><button onclick="refreshPreview()">Refresh</button></div>
<iframe id="ed-preview-frame" src="about:blank"></iframe>
</div>
</div>

<div id="ed-statusbar">
<span id="ed-pos">Ln 1, Col 1</span>
<span id="ed-words">0 words</span>
<span id="ed-dirty"></span>
<span id="ed-saved"></span>
</div>

</div>

<script src="/editor/assets/cm/codemirror.min.js"></script>
<script src="/editor/assets/cm/overlay.min.js"></script>
<script src="/editor/assets/cm/xml.min.js"></script>
<script src="/editor/assets/cm/markdown.min.js"></script>
<script src="/editor/assets/cm/yaml.min.js"></script>
<script src="/editor/assets/cm/htmlmixed.min.js"></script>
<script src="/editor/assets/cm/css.min.js"></script>
<script src="/editor/assets/cm/javascript.min.js"></script>
<script src="/editor/assets/cm/perl.min.js"></script>
<script src="/editor/assets/cm/shell.min.js"></script>
<script src="/editor/assets/cm/matchbrackets.min.js"></script>
<script src="/editor/assets/cm/closebrackets.min.js"></script>

<script>
var API = '/cgi-bin/lazysite-editor-api.pl';
var filePath = '[% query.path | html %]';
var isNew = '[% query.new | html %]' === '1';
var isMdFile = filePath && /\.md$/i.test(filePath);
var fileMtime = null;
var isDirty = false;
var lockRenewTimer = null;
var yamlCm = null;
var contentCm = null;

// --- TT overlay modes ---
if (typeof CodeMirror !== 'undefined') {

var TT_OPEN = '[' + '%';
var TT_CLOSE = '%' + ']';
var ttOverlay = {
  token: function(stream) {
    if (stream.match(TT_OPEN)) {
      while (!stream.eol()) { if (stream.match(TT_CLOSE)) break; stream.next(); }
      return 'tt-variable';
    }
    while (stream.next() != null) { if (stream.match(TT_OPEN, false)) break; }
    return null;
  }
};

CodeMirror.defineMode('markdown-tt', function(config) {
  return CodeMirror.overlayMode(
    CodeMirror.getMode(config, { name: 'markdown', xml: true }), ttOverlay);
});

CodeMirror.defineMode('htmlmixed-tt', function(config) {
  return CodeMirror.overlayMode(
    CodeMirror.getMode(config, 'htmlmixed'), ttOverlay);
});

}

function getModeForPath(path) {
  if (!path) return 'text';
  if (path.match(/\.md$/))    return 'markdown-tt';
  if (path.match(/\.tt$/))    return 'htmlmixed-tt';
  if (path.match(/\.ya?ml$/)) return 'yaml';
  if (path.match(/\.conf$/))  return 'yaml';
  if (path.match(/\.json$/))  return { name: 'javascript', json: true };
  if (path.match(/\.css$/))   return 'css';
  if (path.match(/\.pl$/))    return 'perl';
  if (path.match(/\.sh$/))    return 'shell';
  return 'text';
}

// --- Init editors ---
function initEditors() {
  if (typeof CodeMirror === 'undefined') {
    // Fallback: plain textareas
    document.getElementById('ed-yaml-cm').innerHTML =
      '<textarea id="yaml-fallback" style="width:100%;height:60px;font:12px monospace;"></textarea>';
    document.getElementById('ed-content-cm').innerHTML =
      '<textarea id="content-fallback" style="width:100%;height:400px;font:14px monospace;"></textarea>';
    yamlCm = {
      getValue: function() { return document.getElementById('yaml-fallback').value; },
      setValue: function(v) { document.getElementById('yaml-fallback').value = v; },
      on: function(ev, fn) { document.getElementById('yaml-fallback').addEventListener('input', fn); }
    };
    contentCm = {
      getValue: function() { return document.getElementById('content-fallback').value; },
      setValue: function(v) { document.getElementById('content-fallback').value = v; },
      getCursor: function() { return { line: 0, ch: 0 }; },
      on: function(ev, fn) { document.getElementById('content-fallback').addEventListener('input', fn); }
    };
    return;
  }

  yamlCm = CodeMirror(document.getElementById('ed-yaml-cm'), {
    mode: 'yaml', lineNumbers: false, lineWrapping: true, tabSize: 2
  });
  yamlCm.on('change', function() { markDirty(); });

  contentCm = CodeMirror(document.getElementById('ed-content-cm'), {
    mode: getModeForPath(filePath),
    lineNumbers: true, lineWrapping: true, tabSize: 2,
    matchBrackets: true, autoCloseBrackets: true,
    extraKeys: {
      'Ctrl-S': savePage, 'Cmd-S': savePage,
      'Ctrl-P': refreshPreview, 'Cmd-P': refreshPreview
    }
  });
  contentCm.on('change', function() { markDirty(); updateStatus(); });
  contentCm.on('cursorActivity', updateStatus);
}

// --- Status bar ---
function updateStatus() {
  if (!contentCm || !contentCm.getCursor) return;
  var cur = contentCm.getCursor();
  document.getElementById('ed-pos').textContent = 'Ln ' + (cur.line+1) + ', Col ' + (cur.ch+1);
  var text = contentCm.getValue();
  var words = text.trim() ? text.trim().split(/\s+/).length : 0;
  document.getElementById('ed-words').textContent = words + ' words';
}

// --- Dirty state ---
function markDirty() {
  if (!isDirty) {
    isDirty = true;
    document.getElementById('ed-save-btn').classList.add('dirty');
    document.getElementById('ed-save-btn').disabled = false;
    document.getElementById('ed-dirty').textContent = 'unsaved';
  }
}
function clearDirty() {
  isDirty = false;
  document.getElementById('ed-save-btn').classList.remove('dirty');
  document.getElementById('ed-dirty').textContent = '';
  document.getElementById('ed-saved').textContent = 'Saved ' + new Date().toLocaleTimeString();
}

// --- Front matter ---
function parseFrontMatter(content) {
  var m = content.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  if (!m) return { yaml: '', body: content };
  return { yaml: m[1], body: m[2] };
}

function populateFmFields(yaml) {
  var get = function(key) {
    var m = yaml.match(new RegExp('^' + key + '\\s*:\\s*(.+)$', 'm'));
    return m ? m[1].trim() : '';
  };
  document.getElementById('fm-title').value = get('title');
  document.getElementById('fm-subtitle').value = get('subtitle');
  document.getElementById('fm-auth').value = get('auth') || '';
  document.getElementById('fm-search').value = get('search') || '';
  var extra = yaml.split('\n').filter(function(l) {
    return !l.match(/^(title|subtitle|auth|search)\s*:/);
  });
  yamlCm.setValue(extra.join('\n').trim());
}

function syncFmField(key, val) { markDirty(); }

function buildYaml() {
  var parts = [];
  var t = document.getElementById('fm-title').value.trim();
  var s = document.getElementById('fm-subtitle').value.trim();
  var a = document.getElementById('fm-auth').value;
  var sr = document.getElementById('fm-search').value;
  if (t) parts.push('title: ' + t);
  if (s) parts.push('subtitle: ' + s);
  if (a) parts.push('auth: ' + a);
  if (sr) parts.push('search: ' + sr);
  var extra = yamlCm.getValue().trim();
  if (extra) parts.push(extra);
  return parts.join('\n');
}

function buildContent() {
  return '---\n' + buildYaml() + '\n---\n' + contentCm.getValue();
}

// --- Lock ---
function acquireLock() {
  if (!filePath || isNew) return;
  fetch(API + '?action=lock&path=' + encodeURIComponent(filePath))
    .then(function(r) { return r.json(); })
    .then(function(data) {
      var dot = document.getElementById('ed-lock-dot');
      var lbl = document.getElementById('ed-lock-label');
      if (data.locked && data.locked_by) {
        dot.className = 'lock-dot locked'; lbl.textContent = 'Locked by ' + data.locked_by;
        document.getElementById('ed-save-btn').disabled = true;
      } else {
        dot.className = 'lock-dot editing'; lbl.textContent = '';
        lockRenewTimer = setInterval(function() {
          fetch(API + '?action=renew-lock&path=' + encodeURIComponent(filePath));
        }, 60000);
      }
    }).catch(function() {});
}

// --- Load ---
function loadFile() {
  if (!filePath) return;
  document.getElementById('ed-filepath').textContent = filePath;
  var viewPath = filePath.replace(/\.md$/, '').replace(/\/index$/, '/');
  if (viewPath.charAt(0) !== '/') viewPath = '/' + viewPath;
  document.getElementById('ed-view-link').href = viewPath;

  if (!isMdFile) {
    document.getElementById('ed-fm-section').style.display = 'none';
    document.getElementById('ed-preview-pane').style.display = 'none';
    document.getElementById('ed-divider').style.display = 'none';
    document.getElementById('ed-editor-pane').style.width = '100%';
  }

  initEditors();

  if (isNew) {
    yamlCm.setValue('');
    contentCm.setValue('\n## Content\n\nPage content here.\n');
    populateFmFields('title: New Page\nsubtitle: ');
    document.getElementById('ed-save-btn').disabled = false;
    return;
  }

  acquireLock();

  fetch(API + '?action=read&path=' + encodeURIComponent(filePath))
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) {
        document.getElementById('ed-saved').textContent = data.error || 'Load failed';
        return;
      }
      fileMtime = data.mtime;
      if (isMdFile) {
        var parts = parseFrontMatter(data.content);
        populateFmFields(parts.yaml);
        contentCm.setValue(parts.body);
      } else {
        contentCm.setValue(data.content);
      }
      isDirty = false;
      updateStatus();
      if (isMdFile) setTimeout(refreshPreview, 500);
    });
}

// --- Save ---
function savePage() {
  var content = isMdFile ? buildContent() : contentCm.getValue();
  document.getElementById('ed-save-btn').disabled = true;
  document.getElementById('ed-dirty').textContent = 'Saving...';

  fetch(API + '?action=save&path=' + encodeURIComponent(filePath), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ content: content, mtime: fileMtime })
  })
  .then(function(r) { return r.json(); })
  .then(function(data) {
    if (data.ok) {
      fileMtime = data.mtime;
      clearDirty();
      if (isMdFile) refreshPreview();
    } else if (data.conflict) {
      document.getElementById('ed-dirty').textContent = 'Conflict: modified externally';
      document.getElementById('ed-save-btn').disabled = false;
    } else {
      document.getElementById('ed-dirty').textContent = data.error || 'Save failed';
      document.getElementById('ed-save-btn').disabled = false;
    }
  });
}

// --- Preview ---
function isRawOrApi() {
  var yaml = buildYaml();
  return /^api\s*:\s*true/mi.test(yaml) || /^raw\s*:\s*true/mi.test(yaml);
}

function refreshPreview() {
  if (!isMdFile) return;
  var url = filePath.replace(/\.md$/, '').replace(/\/index$/, '/');
  if (url.charAt(0) !== '/') url = '/' + url;
  url += '?_t=' + Date.now();
  var frame = document.getElementById('ed-preview-frame');
  document.getElementById('ed-preview-status').textContent = 'Loading...';

  if (isRawOrApi()) {
    // Fetch as text and display with highlighting
    fetch(url)
      .then(function(r) { return r.text(); })
      .then(function(text) {
        // Strip CGI headers if present
        text = text.replace(/^(Status:.*\n)?(Content-type:.*\n)?(Cache-Control:.*\n)*\n?/i, '');
        var escaped = text.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
        var isJson = /^\s*[\[{]/.test(text);
        if (isJson) {
          try { escaped = JSON.stringify(JSON.parse(text), null, 2)
                  .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;'); } catch(e) {}
        }
        frame.srcdoc = '<html><body style="margin:0;padding:12px;font:13px/1.5 ui-monospace,monospace;background:#1e1e1e;color:#d4d4d4;white-space:pre-wrap;word-break:break-all;">' + escaped + '</body></html>';
        document.getElementById('ed-preview-status').textContent = 'Raw output';
      })
      .catch(function() {
        document.getElementById('ed-preview-status').textContent = 'Preview failed';
      });
    return;
  }

  // Normal HTML preview in iframe
  frame.onload = function() { document.getElementById('ed-preview-status').textContent = ''; };
  frame.removeAttribute('srcdoc');
  frame.src = url;
}

// --- Divider ---
(function() {
  var div = document.getElementById('ed-divider');
  var main = document.getElementById('ed-main');
  var pane = document.getElementById('ed-editor-pane');
  var dragging = false;
  div.addEventListener('mousedown', function() {
    dragging = true;
    document.body.style.cursor = 'col-resize';
    document.body.style.userSelect = 'none';
  });
  document.addEventListener('mousemove', function(e) {
    if (!dragging) return;
    var rect = main.getBoundingClientRect();
    var pct = ((e.clientX - rect.left) / rect.width) * 100;
    pane.style.width = Math.max(20, Math.min(80, pct)) + '%';
  });
  document.addEventListener('mouseup', function() {
    dragging = false;
    document.body.style.cursor = '';
    document.body.style.userSelect = '';
  });
})();

// --- Unload ---
window.addEventListener('beforeunload', function(e) {
  if (isDirty) { e.preventDefault(); e.returnValue = ''; }
  if (lockRenewTimer) clearInterval(lockRenewTimer);
  if (filePath && !isNew) {
    navigator.sendBeacon(API + '?action=unlock&path=' + encodeURIComponent(filePath));
  }
});

// --- Keyboard shortcut (global) ---
document.addEventListener('keydown', function(e) {
  if ((e.ctrlKey || e.metaKey) && e.key === 's') { e.preventDefault(); savePage(); }
});

// --- Boot ---
loadFile();
</script>
