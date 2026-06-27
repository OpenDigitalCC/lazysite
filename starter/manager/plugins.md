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
    html += '<div class="mg-plugin-row" data-script="' + esc(p._script) + '">';
    if (p.core) {
      html += '<span class="mg-badge enabled" title="Always on - wired in the web server config">core</span>';
    } else {
      var checked = p._enabled ? ' checked' : '';
      html += '<input type="checkbox" class="mg-toggle"' + checked + ' onchange="togglePlugin(this,\'' + esc(p._script) + '\',\'' + esc(p.name) + '\')">';
    }
    html += '<span class="mg-plugin-row-name">' + esc(p.name) + '</span>';
    html += '<span class="mg-plugin-row-desc">' + esc(p.description || '') + '</span>';
    if (p._enabled && !p.core) {
      html += '<a class="mg-plugin-row-config" href="/manager/plugin-config">Configure</a>';
    }
    html += '<span class="mg-plugin-row-path">' + esc(p._script) + '</span>';
    html += '</div>';
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
    } else { warn(''); loadPluginRegistry(); }
  }).catch(function (e) {
    input.disabled = false; input.checked = !input.checked; warn('Error: ' + e.message);
  });
}

loadPluginRegistry();
</script>
