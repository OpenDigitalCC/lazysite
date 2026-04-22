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
var SITE_PLUGIN_ID = 'lazysite';
// SM028: script path is discovered from plugin-list (processor exposes
// --describe with id="lazysite") rather than hardcoded, so the manager
// keeps working if the processor is ever moved.
var sitePluginScript = null;

// NOTE: this mirrors lazysite-processor.pl's config_schema.
// Keep them in sync until SM042 unifies them.
var SITE_SCHEMA = [
  { key: 'site_name',      label: 'Site name',             type: 'text',   required: true,
    default: 'My Site' },
  { key: 'site_url',       label: 'Site URL',              type: 'text',
    default: '${REQUEST_SCHEME}://${SERVER_NAME}' },
  // SM044: layout + theme are dynamically-populated dropdowns.
  // Options come from ?action=layouts-available and
  // ?action=themes-for-layout. The layout change event re-fetches
  // the theme options (depends_on: 'layout').
  { key: 'layout',         label: 'Active layout',         type: 'dropdown_layouts',
    default: '' },
  { key: 'theme',          label: 'Active theme',          type: 'dropdown_themes_for_active_layout',
    default: '', depends_on: 'layout' },
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

// SM044: populated by parallel fetch of layouts-available at load time.
// Null means "not yet loaded"; [] means "loaded, but none installed".
var availableLayouts = null;

function esc(s) { return (s==null?'':String(s)).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }

// --- Site settings ---

function loadSiteSettings() {
  if (!sitePluginScript) return;
  // SM044: fetch settings and the layouts-available list in parallel,
  // so the layout dropdown can render with real options on first paint.
  // Theme dropdown is populated afterwards once we know the layout.
  var readPromise = fetch(
    API + '?action=plugin-read&plugin=' + encodeURIComponent(SITE_PLUGIN_ID), {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ script: sitePluginScript })
    }
  ).then(function(r) { return r.json(); });

  var layoutsPromise = fetch(API + '?action=layouts-available')
    .then(function(r) { return r.json(); });

  Promise.all([readPromise, layoutsPromise])
    .then(function(results) {
      var data = results[0];
      var layoutsResp = results[1];
      var container = document.getElementById('site-settings');
      if (!data.ok) {
        mgShowWarning(data.error || 'Failed to load site settings', true);
        container.textContent = '';
        return;
      }
      mgClearWarning();

      availableLayouts = (layoutsResp && layoutsResp.ok && layoutsResp.layouts)
        ? layoutsResp.layouts
        : [];

      var values = data.values || {};
      container.innerHTML = renderSiteForm(values);
      applyShowWhen(container);
      // Now that layout is known, populate theme dropdown for it.
      refreshThemeDropdown(values.layout || '', values.theme || '');
    })
    .catch(function(e) {
      mgShowWarning('Error: ' + e.message, true);
      document.getElementById('site-settings').textContent = '';
    });
}

// SM044: refresh the theme <select> based on the current layout.
// Called on initial load and on layout-field change. If the currently
// configured theme value isn't compatible with the new layout, it's
// cleared — better than silently pretending an incompatible theme
// is active.
function refreshThemeDropdown(layoutValue, preferredTheme) {
  var sel = document.querySelector('#site-form [name="theme"]');
  if (!sel) return;

  if (!layoutValue) {
    sel.innerHTML =
      '<option value="" disabled selected>'
      + '(set a layout first)</option>';
    sel.value = '';
    return;
  }

  fetch(API + '?action=themes-for-layout&layout='
        + encodeURIComponent(layoutValue))
    .then(function(r) { return r.json(); })
    .then(function(data) {
      var themes = (data && data.ok && data.themes) ? data.themes : [];
      if (!themes.length) {
        sel.innerHTML =
          '<option value="" disabled selected>'
          + '(no themes compatible with '
          + esc(layoutValue) + ')</option>';
        sel.value = '';
        return;
      }
      var html = '<option value="">(none)</option>';
      var found = false;
      for (var i = 0; i < themes.length; i++) {
        var t = themes[i];
        var selectedAttr = '';
        if (preferredTheme && t === preferredTheme) {
          selectedAttr = ' selected';
          found = true;
        }
        html += '<option value="' + esc(t) + '"' + selectedAttr + '>'
             + esc(t) + '</option>';
      }
      sel.innerHTML = html;
      if (!found) sel.value = '';
    })
    .catch(function() {
      sel.innerHTML =
        '<option value="" disabled selected>(failed to load)</option>';
    });
}

// SM044: wired into the layout dropdown's onchange in renderSiteForm.
// Uses the CURRENT theme field value as preferredTheme so operators
// get the same theme back if it's still compatible.
function onLayoutChange(select) {
  var themeSel = document.querySelector('#site-form [name="theme"]');
  var preferred = themeSel ? themeSel.value : '';
  refreshThemeDropdown(select.value, preferred);
  applyShowWhen(select.form);
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
    } else if (f.type === 'dropdown_layouts') {
      // SM044: populated from the layouts-available response cached
      // in availableLayouts. On change, refresh the theme dropdown
      // via onLayoutChange (which also calls applyShowWhen).
      html += '<select name="'+f.key+'" onchange="onLayoutChange(this)">';
      if (!availableLayouts || !availableLayouts.length) {
        html += '<option value="" disabled selected>'
             +  '(no layouts installed)</option>';
      } else {
        html += '<option value=""'+(v===''?' selected':'')+'>(none)</option>';
        availableLayouts.forEach(function(layoutName) {
          html += '<option value="'+esc(layoutName)+'"'
               +  (v===layoutName?' selected':'')+'>'+esc(layoutName)+'</option>';
        });
      }
      html += '</select>';
    } else if (f.type === 'dropdown_themes_for_active_layout') {
      // SM044: populated asynchronously by refreshThemeDropdown
      // after the form renders (and again on layout change). A
      // placeholder <option> carries the current value so the
      // form's value round-trips on save before the fetch returns.
      html += '<select name="'+f.key+'" onchange="applyShowWhen(this.form)">';
      html += '<option value="'+esc(v)+'" selected>'
           +  (v ? esc(v) : '(loading...)')+'</option>';
      html += '</select>';
    } else {
      html += '<input type="text" name="'+f.key+'" value="'+esc(v)+'"'+(f.required?' required':'')+'>';
    }
    html += '</div>';
  });
  html += '<div class="mg-form-row"><label></label><button type="submit" class="mg-btn mg-btn-outline">Save</button></div>';
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
  status.className = 'mg-status';
  status.textContent = 'Saving...';
  fetch(API + '?action=plugin-save&plugin=' + encodeURIComponent(SITE_PLUGIN_ID), {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ script: sitePluginScript, values: values })
  })
  .then(function(r) { return r.json(); })
  .then(function(data) {
    if (data.ok) {
      mgClearWarning();
      status.className = 'mg-status mg-status-success';
      status.textContent = 'Saved.';
      setTimeout(function() { status.textContent = ''; status.className = 'mg-status'; }, 3000);
    } else {
      mgShowWarning('Error: ' + (data.error || 'unknown'), true);
      status.textContent = '';
      status.className = 'mg-status';
    }
  })
  .catch(function(e) {
    mgShowWarning('Error: ' + e.message, true);
    status.textContent = '';
    status.className = 'mg-status';
  });
}

// --- Plugin registry ---

function loadPluginRegistry() {
  fetch(API + '?action=plugin-list')
    .then(function(r) { return r.json(); })
    .then(function(data) {
      var regContainer = document.getElementById('plugin-registry');
      var siteContainer = document.getElementById('site-settings');
      if (!data.ok) {
        mgShowWarning(data.error || 'Failed to load plugins', true);
        regContainer.textContent = '';
        siteContainer.textContent = '';
        return;
      }
      mgClearWarning();
      var plugins = data.plugins || [];

      // SM028: discover the site-config plugin's script path here so the
      // settings form uses the same source as the registry. Filter the
      // core processor out of the togglable registry below — it's the
      // host, not an optional plugin.
      var core;
      for (var i = 0; i < plugins.length; i++) {
        if (plugins[i].id === SITE_PLUGIN_ID) { core = plugins[i]; break; }
      }
      if (core) {
        sitePluginScript = core._script;
        loadSiteSettings();
      } else {
        siteContainer.textContent = '';
        mgShowWarning('Site configuration plugin not discovered.', true);
      }

      var toRender = plugins.filter(function(p) { return p.id !== SITE_PLUGIN_ID; });
      renderPluginRegistry(toRender);
    })
    .catch(function(e) {
      mgShowWarning('Error: ' + e.message, true);
      document.getElementById('plugin-registry').textContent = '';
      document.getElementById('site-settings').textContent = '';
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
      mgShowWarning(
        'Failed to ' + (input.checked ? 'enable' : 'disable') + ' ' + name
          + ': ' + (data.error || 'unknown'),
        true);
    } else {
      mgClearWarning();
    }
  })
  .catch(function(e) {
    input.disabled = false;
    input.checked = !input.checked;
    mgShowWarning('Error: ' + e.message, true);
  });
}

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
