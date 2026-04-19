---
title: Configuration
auth: manager
search: false
---

<section class="mg-config-section">
<h2>Site settings</h2>
<div id="site-settings">Loading...</div>
<div id="site-status" class="mg-status"></div>
</section>

<section class="mg-config-section">
<h2>Plugins</h2>
<p class="mg-config-help">Enable or disable discovered plugins. Configure enabled plugins on the <a href="/manager/plugins">Plugins</a> page.</p>
<div id="plugin-registry">Loading...</div>
</section>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';
var SITE_PLUGIN_ID     = 'lazysite';
var SITE_PLUGIN_SCRIPT = 'cgi-bin/lazysite-processor.pl';

var SITE_SCHEMA = [
  { key: 'site_name',      label: 'Site name',             type: 'text',   required: true,
    default: 'My Site' },
  { key: 'site_url',       label: 'Site URL',              type: 'text',
    default: '${REQUEST_SCHEME}://${SERVER_NAME}' },
  { key: 'theme',          label: 'Default theme',         type: 'text',   default: '' },
  { key: 'nav_file',       label: 'Navigation file',       type: 'text',
    default: 'lazysite/nav.conf' },
  { key: 'search_default', label: 'Pages searchable by default', type: 'select',
    options: ['true', 'false'], default: 'true' },
  { key: 'manager',        label: 'Manager',               type: 'select',
    options: ['disabled', 'enabled'], default: 'disabled' },
  { key: 'manager_path',   label: 'Manager URL path',      type: 'text',
    default: '/manager',
    show_when: { key: 'manager', value: ['enabled'] } },
  { key: 'manager_groups', label: 'Manager access groups', type: 'text',
    default: '',
    show_when: { key: 'manager', value: ['enabled'] } },
];

function esc(s) { return (s==null?'':String(s)).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }

// --- Site settings ---

function loadSiteSettings() {
  fetch(API + '?action=plugin-read&plugin=' + encodeURIComponent(SITE_PLUGIN_ID), {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ script: SITE_PLUGIN_SCRIPT })
  })
  .then(function(r) { return r.json(); })
  .then(function(data) {
    var container = document.getElementById('site-settings');
    if (!data.ok) { container.textContent = data.error || 'Failed to load site settings'; return; }
    container.innerHTML = renderSiteForm(data.values || {});
    applyShowWhen(container);
  })
  .catch(function(e) {
    document.getElementById('site-settings').textContent = 'Error: ' + e.message;
  });
}

function renderSiteForm(values) {
  var html = '<form id="site-form" onsubmit="saveSiteSettings(event)">';
  SITE_SCHEMA.forEach(function(f) {
    var v = values[f.key] !== undefined ? values[f.key] : (f.default || '');
    var sw = f.show_when;
    var da = sw ? ' data-show-key="'+sw.key+'" data-show-val="'+sw.value.join(',')+'"' : '';
    html += '<div class="mg-form-row mg-config-field"'+da+'>';
    html += '<label>' + esc(f.label) + '</label>';
    if (f.type === 'select') {
      html += '<select name="'+f.key+'" onchange="applyShowWhen(this.form)">';
      (f.options||[]).forEach(function(o) { html += '<option'+(v===o?' selected':'')+'>'+o+'</option>'; });
      html += '</select>';
    } else {
      html += '<input type="text" name="'+f.key+'" value="'+esc(v)+'"'+(f.required?' required':'')+'>';
    }
    html += '</div>';
  });
  html += '<div class="mg-form-row"><label></label><button type="submit">Save</button></div>';
  html += '</form>';
  return html;
}

function applyShowWhen(container) {
  if (!container) return;
  var fields = container.querySelectorAll('[data-show-key]');
  for (var i = 0; i < fields.length; i++) {
    var f = fields[i];
    var key = f.dataset.showKey;
    var vals = f.dataset.showVal.split(',');
    var ctrl = container.querySelector('[name="' + key + '"]');
    if (!ctrl) { f.style.display = 'none'; continue; }
    var cur = ctrl.value;
    var show = vals.indexOf(cur) !== -1;
    f.style.display = show ? 'flex' : 'none';
  }
}

function saveSiteSettings(e) {
  e.preventDefault();
  var form = e.target;
  var status = document.getElementById('site-status');
  var values = {};
  for (var i = 0; i < form.elements.length; i++) {
    var el = form.elements[i];
    if (!el.name) continue;
    values[el.name] = el.value;
  }
  status.textContent = 'Saving...';
  fetch(API + '?action=plugin-save&plugin=' + encodeURIComponent(SITE_PLUGIN_ID), {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ script: SITE_PLUGIN_SCRIPT, values: values })
  })
  .then(function(r) { return r.json(); })
  .then(function(data) {
    if (data.ok) {
      status.className = 'mg-status mg-status-success';
      status.textContent = 'Saved.';
      setTimeout(function() { status.textContent = ''; status.className = 'mg-status'; }, 3000);
    } else {
      status.className = 'mg-status mg-status-error';
      status.textContent = 'Error: ' + (data.error || 'unknown');
    }
  })
  .catch(function(e) {
    status.className = 'mg-status mg-status-error';
    status.textContent = 'Error: ' + e.message;
  });
}

// --- Plugin registry ---

function loadPluginRegistry() {
  fetch(API + '?action=plugin-list')
    .then(function(r) { return r.json(); })
    .then(function(data) {
      var container = document.getElementById('plugin-registry');
      if (!data.ok) { container.textContent = data.error || 'Failed to load plugins'; return; }
      renderPluginRegistry(data.plugins || []);
    })
    .catch(function(e) {
      document.getElementById('plugin-registry').textContent = 'Error: ' + e.message;
    });
}

function renderPluginRegistry(plugins) {
  var container = document.getElementById('plugin-registry');
  if (!plugins.length) {
    container.innerHTML = '<p class="mg-empty">No plugins discovered.</p>';
    return;
  }
  var html = '<div class="mg-plugin-registry">';
  plugins.forEach(function(p) {
    var checked = p._enabled ? ' checked' : '';
    html += '<label class="mg-plugin-row" data-script="' + esc(p._script) + '">';
    html += '<input type="checkbox"' + checked + ' onchange="togglePlugin(this,\'' + esc(p._script) + '\',\'' + esc(p.name) + '\')">';
    html += '<span class="mg-plugin-row-name">' + esc(p.name) + '</span>';
    html += '<span class="mg-plugin-row-desc">' + esc(p.description || '') + '</span>';
    html += '<span class="mg-plugin-row-path">' + esc(p._script) + '</span>';
    html += '</label>';
  });
  html += '</div>';
  container.innerHTML = html;
}

function togglePlugin(input, script, name) {
  var action = input.checked ? 'plugin-enable' : 'plugin-disable';
  input.disabled = true;
  fetch(API + '?action=' + action, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ script: script })
  })
  .then(function(r) { return r.json(); })
  .then(function(data) {
    input.disabled = false;
    if (!data.ok) {
      input.checked = !input.checked;
      alert('Failed to ' + (input.checked ? 'enable' : 'disable') + ' ' + name + ': ' + (data.error || 'unknown'));
    }
  })
  .catch(function(e) {
    input.disabled = false;
    input.checked = !input.checked;
    alert('Error: ' + e.message);
  });
}

loadSiteSettings();
loadPluginRegistry();
</script>

<style>
.mg-config-section { margin-bottom: 2rem; }
.mg-config-help { color: var(--mg-text-muted); font-size: 0.875rem; margin: 0.25rem 0 1rem; }
.mg-plugin-registry { display: flex; flex-direction: column; gap: 0.25rem; }
.mg-plugin-row {
  display: grid;
  grid-template-columns: auto 14rem 1fr auto;
  align-items: center;
  gap: 0.75rem;
  padding: 0.5rem 0.75rem;
  border: 1px solid var(--mg-border, #e5e5e5);
  border-radius: 4px;
  cursor: pointer;
}
.mg-plugin-row:hover { background: var(--mg-bg-hover, #fafafa); }
.mg-plugin-row-name { font-weight: 500; }
.mg-plugin-row-desc { color: var(--mg-text-muted); font-size: 0.875rem; }
.mg-plugin-row-path { font-family: var(--mg-mono, monospace); font-size: 0.75rem; color: var(--mg-text-light); }
</style>
