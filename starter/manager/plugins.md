---
title: Plugin Manager
auth: manager
search: false
---

<p class="mg-config-help">Enable or disable plugins. Configure an enabled plugin on the <a href="/manager/plugin-config">Plugin Config</a> page.</p>

<div id="plugin-status" class="mg-status"></div>
<div id="plugin-registry">Loading&hellip;</div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';
// The processor publishes itself as a plugin (id 'lazysite') to expose the site
// config schema; it is the host, not a togglable plugin, so it is filtered out.
var SITE_PLUGIN_ID = 'lazysite';

function esc(s) { var d = document.createElement('div'); d.textContent = (s == null ? '' : String(s)); return d.innerHTML; }
function warn(msg) { var el = document.getElementById('plugin-status'); if (el) { el.textContent = msg || ''; el.style.display = msg ? '' : 'none'; } }

function loadPluginRegistry() {
  fetch(API + '?action=plugin-list').then(function (r) { return r.json(); }).then(function (data) {
    var container = document.getElementById('plugin-registry');
    if (!data.ok) { warn(data.error || 'Failed to load plugins'); container.textContent = ''; return; }
    warn('');
    var plugins = (data.plugins || []).filter(function (p) { return p.id !== SITE_PLUGIN_ID; });
    renderPluginRegistry(plugins);
  }).catch(function (e) { warn('Error: ' + e.message); document.getElementById('plugin-registry').textContent = ''; });
}

function renderPluginRegistry(plugins) {
  var container = document.getElementById('plugin-registry');
  if (!plugins.length) { container.innerHTML = '<p class="mg-empty">No plugins discovered.</p>'; return; }
  var html = '<div class="mg-plugin-registry">';
  plugins.forEach(function (p) {
    html += '<div class="mg-plugin-row' + (p.core ? ' mg-plugin-core' : '') + '" data-script="' + esc(p._script) + '">';
    // Control column: the enable toggle, with Configure stacked beneath it when
    // enabled (so enabling never shifts the row across a column).
    html += '<div class="mg-plugin-ctl">';
    if (!p.core) {
      var checked = p._enabled ? ' checked' : '';
      html += '<input type="checkbox" class="mg-toggle"' + checked + ' onchange="togglePlugin(this,\'' + esc(p._script) + '\',\'' + esc(p.name) + '\')">';
      if (p._enabled) {
        html += '<a class="mg-plugin-row-config" href="/manager/plugin-config">Configure</a>';
      }
    }
    html += '</div>';
    // Main column: name + description.
    html += '<div class="mg-plugin-main">' +
      '<div class="mg-plugin-row-name">' + esc(p.name) + '</div>' +
      '<div class="mg-plugin-row-desc">' + esc(p.description || '') + '</div></div>';
    // End column (info only): the core badge, or an info tooltip carrying the
    // plugin details (its file is here, not cluttering the row).
    html += '<div class="mg-plugin-end">';
    if (p.core) {
      html += '<span class="mg-badge enabled" title="Always on - wired in the web server config">core</span>';
    } else {
      var info = 'File: ' + p._script + (p.version ? '  ·  v' + p.version : '') + (p.id ? '  ·  id: ' + p.id : '');
      html += '<span class="mg-info" tabindex="0" role="img" aria-label="Plugin details" title="' + esc(info) + '">&#9432;</span>';
    }
    html += '</div></div>';
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
  }).then(function (r) { return r.json(); }).then(function (data) {
    input.disabled = false;
    if (!data.ok) {
      input.checked = !input.checked;
      warn('Failed to ' + (input.checked ? 'enable' : 'disable') + ' ' + name + ': ' + (data.error || 'unknown'));
    } else {
      // A plugin may run a setup/teardown step with its toggle (on_enable /
      // on_disable) - its outcome IS the news, so show it here.
      var h = data.hook;
      if (h && h.message) { warn(name + ': ' + h.message); }
      else if (h && !h.ok) { warn(name + ' is toggled, but its setup step failed: ' + (h.error || 'unknown') + ' - open its config page for status.'); }
      else { warn(''); }
      loadPluginRegistry();
    }
  }).catch(function (e) {
    input.disabled = false; input.checked = !input.checked; warn('Error: ' + e.message);
  });
}

loadPluginRegistry();
</script>
