---
title: Site settings
auth: manager
search: false
---

<section class="mg-config-section">
<div id="site-settings">Loading...</div>
<div id="site-status" class="mg-status"></div>
</section>

<p class="mg-config-help">Manage plugins on the <a href="/manager/plugins">Plugin Manager</a> page (enable/disable) and the <a href="/manager/plugin-config">Plugin Config</a> page (settings).</p>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';

// SM042: SITE_SCHEMA is the SOLE source of truth for the site-settings form.
// (It no longer mirrors the processor's config_schema - that pseudo-plugin path
// is retired. Every settable key here MUST also be in the control API's
// config-set allow-list and config-read subset; the guarantee test
// t/lint/18-config-key-parity.t fails the build if they drift.)
var SITE_SCHEMA = [
  { key: 'site_name',      label: 'Site name',             type: 'text',   required: true,
    default: 'My Site', group: 'Identity' },
  { key: 'site_url',       label: 'Site URL',              type: 'text',
    default: '${REQUEST_SCHEME}://${SERVER_NAME}' },
  // Layout, theme and the layouts repo are managed in ONE place - the Appearance
  // page (Installed layouts & themes), where activation also clears the page cache
  // and mirrors theme assets - so they are NOT duplicated here in settings.
  { key: 'nav_file',       label: 'Navigation file',       type: 'text',
    default: 'lazysite/nav.conf', group: 'Content' },
  { key: 'search_default', label: 'Pages searchable by default', type: 'toggle',
    on: 'true', off: 'false', default: 'true' },
  // SM095/SM138: Manager-UI access is the `ui` channel capability, granted through
  // a group on the Groups page. The legacy manager_groups conf key is retired
  // (SM138): an automatic migration grants its groups explicitly and removes the line.
  { key: 'manager',        label: 'Enable the manager UI', type: 'toggle',
    on: 'enabled', off: 'disabled', default: 'disabled', group: 'Manager user interface',
    note: 'The manager UI is the web interface you are using right now. Switch it OFF to run lazysite as a HEADLESS CMS: the /manager interface is disabled (including for you), but the site keeps serving pages and stays fully configurable over the control API, WebDAV, MCP and direct file access. To turn it back on, set "manager: enabled" in lazysite.conf.' },
  { key: 'manager_path',   label: 'Manager URL path',      type: 'text',
    default: '/manager',
    show_when: { key: 'manager', value: ['enabled'] } },
  { key: 'webdav_enabled', label: 'WebDAV publishing', type: 'toggle',
    on: 'enabled', off: 'disabled', default: 'disabled', group: 'Services',
    note: 'The /dav publishing endpoint (files, themes, layouts) for partner tools and agents. Off by default; when off, /dav returns 404 to every request.' },
  // 0.9.0 service killswitches: every remote surface is OFF until the operator
  // enables it here (the WebDAV posture, extended to the rest). When off, each
  // endpoint returns 404 / refuses and discloses nothing.
  { key: 'mcp_enabled', label: 'MCP connector', type: 'toggle',
    on: 'enabled', off: 'disabled', default: 'disabled', group: 'Services',
    note: 'The Model Context Protocol server exposing site tools to AI agents (Claude, ChatGPT). Off by default; when off the endpoint returns 404 and lists no tools. Enable to let an agent connect.' },
  { key: 'oauth_enabled', label: 'OAuth authorization server', type: 'toggle',
    on: 'enabled', off: 'disabled', default: 'disabled', group: 'Services',
    note: 'The OAuth2 server for web AI connectors (dynamic client registration, authorize, token). Off by default; when off every OAuth endpoint returns 404. Enable only if a connector requires OAuth.' },
  { key: 'control_api_enabled', label: 'Control API (token access)', type: 'toggle',
    on: 'enabled', off: 'disabled', default: 'disabled', group: 'Services',
    note: 'The token-authenticated control API for partner tools and scripts (lzs_ tokens). Off by default; when off token requests are refused - the manager UI you are using now is unaffected. Enable to let API / agent tokens drive the site.' },
  { key: 'token_exchange_enabled', label: 'AI-partner token exchange', type: 'toggle',
    on: 'enabled', off: 'disabled', default: 'disabled', group: 'Services',
    note: 'Pairing-key exchange and token rotation - how an AI partner turns a one-time pairing key into a working token. Off by default. Enable while provisioning AI partners, then it can be turned off again.' },
  { key: 'update_channel', label: 'Update channel', type: 'select',
    options: ['all', 'beta', 'stable'], default: 'all', group: 'Updates',
    note: 'The minimum release maturity this site accepts, on the edge < beta < stable ladder. "all" installs every release (early testing); "beta" takes beta and stable builds (tested, bedding in); "stable" takes only certified stable releases. Out-of-channel upgrades are skipped and logged in the audit trail. Use "stable" for customer sites.' },
];

// SM044: populated by parallel fetch of layouts-available at load time.
// Null means "not yet loaded"; [] means "loaded, but none installed".
var availableLayouts = null;

function esc(s) { return (s==null?'':String(s)).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }

// --- Site settings ---

// Snapshot of the last-loaded values, so save only writes what CHANGED.
var loadedValues = {};

function loadSiteSettings() {
  // SM042: site settings are read via the control API's config-read (a safe,
  // per-key subset) - NOT the lazysite pseudo-plugin. SM044: fetch settings and
  // the layouts-available list in parallel so the layout dropdown renders with
  // real options on first paint; the theme dropdown follows once the layout is known.
  var readPromise = fetch(API + '?action=config-read')
    .then(function(r) { return r.json(); });

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

      var values = data.config || {};
      loadedValues = values;
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
  var html = '<form id="site-form" onsubmit="saveSiteSettings(event)" oninput="markSiteDirty()" onchange="markSiteDirty()">';
  SITE_SCHEMA.forEach(function(f) {
    if (f.group) html += '<h3 class="mg-config-group">' + esc(f.group) + '</h3>';
    var v = values[f.key] !== undefined ? values[f.key] : (f.default || '');
    var sw = f.show_when;
    var da = sw ? ' data-show-key="'+sw.key+'" data-show-val="'+sw.value.join(',')+'"' : '';
    html += '<div class="mg-form-row mg-config-field"'+da+'>';
    html += '<label>' + esc(f.label) + '</label>';
    if (f.type === 'toggle') {
      // SM114: a boolean rendered as a switch. A hidden input carries the on/off
      // string so the existing form serialisation (el.value) round-trips it.
      var onVal = f.on || 'enabled', offVal = f.off || 'disabled';
      var isOn = (String(v) === onVal);
      html += '<input type="hidden" name="'+f.key+'" id="cfg-'+esc(f.key)+'" value="'+esc(isOn?onVal:offVal)+'">';
      html += '<label class="mg-chk"><input type="checkbox" class="mg-toggle"'+(isOn?' checked':'')
           +  ' onchange="var h=document.getElementById(\'cfg-'+esc(f.key)+'\'); h.value=this.checked?\''+onVal+'\':\''+offVal+'\'; applyShowWhen(this.form);"></label>';
    } else if (f.type === 'select') {
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
    } else if (f.type === 'readonly_with_link') {
      // SM068: read-only display with an edit-elsewhere link.
      // Shows the current value (or "(not set)") and a small
      // link that points at f.link_href. The field is NOT
      // part of the submitted form — no <input name>, so
      // plugin-save doesn't see it.
      // Show the effective value: the configured one, or the field default
      // (e.g. the standard layouts repo) so it never reads "(not set)" when
      // a sensible default is in force.
      var eff = v || f.default;
      var disp = eff ? esc(eff) : '<em class="mg-empty">(not set)</em>';
      html += '<span class="mg-readonly-value" '
           +  'style="flex:1;color:var(--mg-text);">'
           +  disp + '</span>';
      if (f.link_href) {
        html += '<a href="' + esc(f.link_href) + '" '
             +  'class="mg-btn mg-btn-sm mg-btn-outline">'
             +  esc(f.link_label || 'Edit') + '</a>';
      }
    } else {
      html += '<input type="text" name="'+f.key+'" value="'+esc(v)+'"'+(f.required?' required':'')+'>';
    }
    if (f.note) html += '<div class="mg-config-help mg-field-note">' + esc(f.note) + '</div>';
    html += '</div>';
  });
  html += '<div class="mg-form-row"><label></label><button type="submit" class="mg-btn mg-btn-primary">Save</button>'
       +  ' <span id="site-dirty" class="mg-dirty-note" style="display:none">&#9679; Unsaved changes &mdash; click Save</span></div>';
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

// SM118: the settings form needs an explicit Save, so flag unsaved changes (and
// warn on leaving) via the shared mgDirtyGuard in the manager layout - the same
// guard every explicit-save manager page uses. Programmatic population doesn't
// fire these.
function markSiteDirty()  { mgDirtyGuard.set('site-settings', 'site-dirty'); }
function clearSiteDirty() { mgDirtyGuard.clear('site-settings'); }

// SM114: aggregate the checked group boxes into the hidden comma-separated value.
function saveSiteSettings(e) {
  e.preventDefault();
  var form = e.target;
  var values = {};
  for (var i = 0; i < form.elements.length; i++) {
    var el = form.elements[i];
    if (!el.name) continue;
    values[el.name] = el.value;
  }
  // SM114: disabling the manager locks the UI for everyone - confirm first.
  if (values.manager === 'disabled') {
    mgConfirm('Disabling the manager locks the manager UI for everyone, including you. Continue?',
      { danger: true, ok: 'Disable manager' }).then(function(ok) { if (ok) saveSiteSettings_go(values); });
    return;
  }
  saveSiteSettings_go(values);
}

function saveSiteSettings_go(values) {
  var status = document.getElementById('site-status');
  status.className = 'mg-status';
  status.textContent = 'Saving...';

  // SM042: the whole site-settings page now persists via the control API's
  // per-key config-set (each key validated + audited by the API) - NOT the
  // lazysite pseudo-plugin's plugin-save. Only CHANGED, settable keys are
  // written; readonly_with_link fields (layout/theme/layouts_repo, managed on
  // Appearance) are never sent. CSRF is added by the manager's fetch wrapper.
  var settable = {};
  SITE_SCHEMA.forEach(function(f) { if (f.type !== 'readonly_with_link') settable[f.key] = true; });

  var writes = [];
  Object.keys(values).forEach(function(k) {
    if (!settable[k]) return;
    var was = (loadedValues[k] == null ? '' : String(loadedValues[k]));
    if (String(values[k]) === was) return;   // unchanged - skip
    writes.push(
      fetch(API + '?action=config-set', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ key: k, value: values[k] })
      })
      .then(function(r) { return r.json(); })
      .then(function(d) { return { key: k, ok: !!d.ok, error: d.error }; })
    );
  });

  if (!writes.length) {
    clearSiteDirty();
    status.className = 'mg-status mg-status-success';
    status.textContent = 'No changes.';
    setTimeout(function() { status.textContent = ''; status.className = 'mg-status'; }, 3000);
    return;
  }

  Promise.all(writes).then(function(results) {
    var failed = results.filter(function(r) { return !r.ok; });
    if (failed.length) {
      mgShowWarning('Could not save ' + failed.map(function(r) { return r.key; }).join(', ')
        + ': ' + (failed[0].error || 'unknown'), true);
      status.textContent = ''; status.className = 'mg-status';
      return;
    }
    // Advance the snapshot so a re-save doesn't rewrite unchanged keys.
    results.forEach(function(r) { loadedValues[r.key] = values[r.key]; });
    mgClearWarning();
    clearSiteDirty();
    status.className = 'mg-status mg-status-success';
    status.textContent = 'Saved.';
    setTimeout(function() { status.textContent = ''; status.className = 'mg-status'; }, 3000);
  }).catch(function(e) {
    mgShowWarning('Error: ' + e.message, true);
    status.textContent = ''; status.className = 'mg-status';
  });
}

// --- Load ---

// SM042: site settings load (config-read) and save (per-key config-set) go
// straight through the control API. The old indirection - discovering the
// processor as a pseudo-plugin (id 'lazysite') via plugin-list, then
// plugin-read/plugin-save - is retired; SITE_SCHEMA below is now the sole source
// of truth for the form, and config-set's allow-list is the sole gate on writes.
loadSiteSettings();
</script>

<!-- config styles consolidated into manager.css (SM109 phase 3) -->
