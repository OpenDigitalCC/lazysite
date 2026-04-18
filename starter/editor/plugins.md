---
title: Plugins
search: false
---

<div>
<style>
.plugins-wrap { font-family: system-ui, sans-serif; max-width: 700px; margin: 0 auto; }
.editor-nav { margin-bottom: 16px; }
.editor-nav a { margin-right: 16px; color: #07c; text-decoration: none; font-size: 14px; }
.editor-nav a:hover { text-decoration: underline; }
.editor-nav a.active { font-weight: 600; color: #333; border-bottom: 2px solid #07c; }
.plugin-card { background: #fff; border: 1px solid #dee2e6; border-radius: 6px; padding: 1rem; margin-bottom: 1rem; }
.plugin-title { font-weight: 600; font-size: 1rem; margin-bottom: 0.2rem; }
.plugin-desc { font-size: 0.875rem; color: #6c757d; margin-bottom: 0.75rem; }
.plugin-actions { margin-bottom: 0.75rem; display: flex; gap: 0.5rem; }
.plugin-actions button, .plugin-actions a { padding: 0.3rem 0.75rem; font-size: 0.875rem; border: 1px solid #dee2e6; border-radius: 4px; background: #fff; cursor: pointer; text-decoration: none; color: #495057; }
.plugin-actions button:hover, .plugin-actions a:hover { background: #f8f9fa; }
.config-toggle { font-size: 0.875rem; padding: 0.25rem 0.6rem; }
.config-form { margin-top: 0.75rem; padding-top: 0.75rem; border-top: 1px solid #dee2e6; }
.fm-row { display: flex; gap: 0.75rem; margin-bottom: 0.5rem; align-items: flex-start; }
.fm-row label { width: 120px; flex-shrink: 0; font-size: 0.8rem; color: #6c757d; padding-top: 0.3rem; text-align: right; }
.fm-row input, .fm-row select, .fm-row textarea { flex: 1; padding: 0.25rem 0.5rem; border: 1px solid #dee2e6; border-radius: 3px; font-size: 0.875rem; }
.readonly-val { font-family: ui-monospace, monospace; font-size: 0.875rem; color: #6c757d; }
.plugin-status { font-size: 0.85rem; color: #6c757d; margin-top: 0.5rem; min-height: 1.2em; }
.config-field[data-show-key] { display: none; }
</style>
</div>

<div class="plugins-wrap" id="app">

<nav class="editor-nav">
<a href="/editor/">Files</a>
<a href="/editor/nav">Nav</a>
<a href="/editor/plugins" class="active">Plugins</a>
<a href="/editor/themes">Themes</a>
<a href="/editor/users">Users</a>
<a href="/editor/cache">Cache</a>
</nav>

<div id="plugin-list">Loading...</div>

</div>

<script>
var API = '/cgi-bin/lazysite-editor-api.pl';

function loadPlugins() {
  document.getElementById('plugin-list').textContent = 'Loading...';
  fetch(API + '?action=plugin-list')
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok || !data.plugins || !data.plugins.length) {
        document.getElementById('plugin-list').innerHTML =
          '<p>No plugins configured. Add scripts to <code>plugins:</code> in lazysite.conf.</p>';
        return;
      }
      var html = '';
      data.plugins.forEach(function(p) {
        html += '<div class="plugin-card" id="plugin-' + p.id + '">';
        html += '<div class="plugin-title">' + esc(p.name) + '</div>';
        html += '<div class="plugin-desc">' + esc(p.description) + '</div>';
        if (p.actions && p.actions.length) {
          html += '<div class="plugin-actions">';
          p.actions.forEach(function(a) {
            if (a.link) {
              html += '<a href="' + a.link + '">' + esc(a.label) + '</a>';
            } else {
              html += '<button onclick=\'runAction(' + JSON.stringify(p).replace(/'/g,"&#39;") + ',' + JSON.stringify(a).replace(/'/g,"&#39;") + ')\'>' + esc(a.label) + '</button>';
            }
          });
          html += '</div>';
        }
        if (p.config_schema && p.config_schema.length) {
          html += '<button class="config-toggle" onclick=\'loadConfig(' + JSON.stringify(p).replace(/'/g,"&#39;") + ')\'>Configure</button>';
          html += '<div class="config-form" id="config-' + p.id + '" style="display:none"></div>';
        }
        html += '<div class="plugin-status" id="status-' + p.id + '"></div>';
        html += '</div>';
      });
      document.getElementById('plugin-list').innerHTML = html;
    });
}

function esc(s) { return (s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }

function loadConfig(plugin) {
  var fd = document.getElementById('config-' + plugin.id);
  if (fd.style.display !== 'none') { fd.style.display = 'none'; return; }
  fd.textContent = 'Loading...';
  fd.style.display = 'block';
  fetch(API + '?action=plugin-read&plugin=' + encodeURIComponent(plugin.id), {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ script: plugin._script })
  })
  .then(function(r) { return r.json(); })
  .then(function(data) {
    if (!data.ok) { fd.textContent = data.error; return; }
    fd.innerHTML = renderForm(plugin, data.values || {});
    applyShowWhen(fd);
  });
}

function renderForm(plugin, values) {
  var html = '<form onsubmit="saveConfig(event,\'' + plugin.id + '\',\'' + esc(plugin._script) + '\')">';
  (plugin.config_schema||[]).forEach(function(f) {
    var val = values[f.key] !== undefined ? values[f.key] : (f.default || '');
    var sw = f.show_when;
    var da = sw ? ' data-show-key="'+sw.key+'" data-show-val="'+sw.value.join(',')+'"' : '';
    html += '<div class="fm-row config-field"'+da+'>';
    html += '<label>' + esc(f.label) + '</label>';
    if (f.type === 'select') {
      html += '<select name="'+f.key+'" onchange="applyShowWhen(this.form)">';
      (f.options||[]).forEach(function(o) { html += '<option'+(val===o?' selected':'')+'>'+o+'</option>'; });
      html += '</select>';
    } else if (f.type === 'boolean') {
      html += '<input type="checkbox" name="'+f.key+'"'+(val==='true'||val==='1'?' checked':'')+' onchange="applyShowWhen(this.form)">';
    } else if (f.type === 'textarea') {
      html += '<textarea name="'+f.key+'" rows="4">'+esc(val)+'</textarea>';
    } else if (f.type === 'password') {
      html += '<input type="password" name="'+f.key+'" placeholder="leave blank to keep">';
    } else if (f.type === 'readonly') {
      html += '<span class="readonly-val">'+esc(val)+'</span>';
    } else {
      var t = f.type==='email'?'email':f.type==='number'?'number':'text';
      html += '<input type="'+t+'" name="'+f.key+'" value="'+esc(val)+'"'+(f.required?' required':'')+'>';
    }
    html += '</div>';
  });
  html += '<div class="fm-row"><label></label><button type="submit">Save</button></div></form>';
  return html;
}

function applyShowWhen(container) {
  if (!container) return;
  var fields = container.querySelectorAll ? container.querySelectorAll('[data-show-key]') : [];
  for (var i = 0; i < fields.length; i++) {
    var f = fields[i];
    var key = f.dataset.showKey;
    var vals = f.dataset.showVal.split(',');
    var ctrl = container.querySelector ? container.querySelector('[name="'+key+'"]') : null;
    if (!ctrl) continue;
    var cur = ctrl.type === 'checkbox' ? (ctrl.checked ? 'true' : 'false') : ctrl.value;
    f.style.display = vals.indexOf(cur) !== -1 ? '' : 'none';
  }
}

function saveConfig(e, pluginId, script) {
  e.preventDefault();
  var form = e.target;
  var status = document.getElementById('status-' + pluginId);
  var values = {};
  var inputs = form.elements;
  for (var i = 0; i < inputs.length; i++) {
    var el = inputs[i];
    if (!el.name) continue;
    if (el.type === 'checkbox') { values[el.name] = el.checked ? 'true' : 'false'; }
    else if (el.type === 'password') { if (el.value) values[el.name] = el.value; }
    else { values[el.name] = el.value; }
  }
  status.textContent = 'Saving...';
  fetch(API + '?action=plugin-save&plugin=' + encodeURIComponent(pluginId), {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ script: script, values: values })
  })
  .then(function(r) { return r.json(); })
  .then(function(data) {
    if (data.ok) {
      status.textContent = 'Saved. Reloading...';
      setTimeout(function() { location.reload(); }, 1000);
    } else {
      status.textContent = 'Error: ' + data.error;
    }
  });
}

function runAction(plugin, action) {
  if (action.confirm && !confirm(action.confirm)) return;
  var status = document.getElementById('status-' + plugin.id);
  status.textContent = 'Running...';
  fetch(API + '?action=plugin-action&plugin=' + encodeURIComponent(plugin.id), {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ script: plugin._script, action_id: action.id })
  })
  .then(function(r) { return r.json(); })
  .then(function(data) {
    if (!data.ok) { status.textContent = 'Error: ' + (data.error||'unknown'); return; }
    status.textContent = 'Done.';
    if (action.on_complete === 'open_url' && data[action.result_key]) {
      window.open(data[action.result_key], '_blank');
    }
    setTimeout(function() { status.textContent = ''; }, 5000);
  });
}

loadPlugins();
</script>
