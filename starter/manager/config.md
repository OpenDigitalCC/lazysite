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
  { key: 'asset_max_age', label: 'Asset cache lifetime (seconds)', type: 'text',
    default: '', group: 'Content',
    note: 'How long a visitor\'s browser may keep stylesheets, images and fonts before re-checking. Empty or 0 (the default) means re-check on every use: theme changes and newly protected files take effect immediately, at the cost of more requests. A value like 300 lets browsers reuse assets for that many seconds - fewer requests, and a change (including protecting a file) can take up to that long to reach visitors who already fetched it.' },
  // SM095/SM138: Manager-UI access is the `ui` channel capability, granted through
  // a group on the Groups page. The legacy manager_groups conf key is retired
  // (SM138): an automatic migration grants its groups explicitly and removes the line.
  { key: 'manager',        label: 'Enable the manager UI', type: 'toggle',
    on: 'enabled', off: 'disabled', default: 'disabled', group: 'Manager user interface',
    note: 'The manager UI is the web interface you are using right now. Switch it OFF to run lazysite as a HEADLESS CMS: the /manager interface is disabled (including for you), but the site keeps serving pages and stays fully configurable over the control API, WebDAV, MCP and direct file access. To turn it back on, set "manager: enabled" in lazysite.conf.' },
  { key: 'manager_path',   label: 'Manager URL path',      type: 'text',
    default: '/manager',
    show_when: { key: 'manager', value: ['enabled'] } },
  // SM623: the service toggles are grouped BY WHAT A CLIENT NEEDS, not by the
  // order they were added. They were interleaved - WebDAV, MCP, OAuth, control
  // API, token exchange - so an operator setting up one kind of connection had
  // to know which of five unrelated-looking switches applied to it, and the two
  // that a web connector needs sat either side of one it does not.
  //
  // The grouping is the SAME split the connector panel checks (SM622): a web
  // connector runs on mcp + oauth; an agent redeems a pairing key through the
  // token exchange and then drives whichever surfaces it holds. Each group
  // carries a preset that flips exactly its own switches - which is the point,
  // because the mistake this prevents is turning on four of the five and
  // wondering why sign-in never appears.
  { key: 'mcp_enabled', label: 'MCP connector', type: 'toggle',
    on: 'enabled', off: 'disabled', default: 'disabled',
    group: 'Services: web AI connector (Claude.ai, ChatGPT)', group_preset: 'web',
    note: 'The Model Context Protocol server exposing site tools to AI agents (Claude, ChatGPT). Off by default; when off the endpoint returns 404 and lists no tools. Enable to let an agent connect.' },
  { key: 'oauth_enabled', label: 'OAuth authorization server', type: 'toggle',
    on: 'enabled', off: 'disabled', default: 'disabled',
    group: 'Services: web AI connector (Claude.ai, ChatGPT)',
    note: 'The OAuth2 server a WEB connector signs in through (dynamic client registration, authorize, token) - this is what asks for the one-time connect code. Off by default; when off every OAuth endpoint returns 404, the sign-in prompt never appears, and the connect code is never asked for. Needed for Claude.ai and ChatGPT; NOT needed for Claude Code, Claude Desktop or scripts, which present a token directly.' },
  { key: 'control_api_enabled', label: 'Control API (token access)', type: 'toggle',
    on: 'enabled', off: 'disabled', default: 'disabled',
    group: 'Services: agent and CLI access (Claude Code, Desktop, scripts)', group_preset: 'agent',
    note: 'The token-authenticated control API for partner tools and scripts (lzs_ tokens). Off by default; when off token requests are refused - the manager UI you are using now is unaffected. Enable to let API / agent tokens drive the site.' },
  { key: 'webdav_enabled', label: 'WebDAV publishing', type: 'toggle',
    on: 'enabled', off: 'disabled', default: 'disabled',
    group: 'Services: agent and CLI access (Claude Code, Desktop, scripts)',
    note: 'The /dav publishing endpoint (files, themes, layouts) for partner tools and agents. Off by default; when off, /dav returns 404 to every request.' },
  { key: 'token_exchange_enabled', label: 'Pairing key exchange and token rotation', type: 'toggle',
    on: 'enabled', off: 'disabled', default: 'disabled',
    group: 'Services: agent and CLI access (Claude Code, Desktop, scripts)',
    note: 'How an agent turns the one-time PAIRING KEY from "Generate agent brief" into a working token, and how it rotates one later. Off by default; when off the key cannot be redeemed, so a brief you issue cannot be used. Enable while provisioning agents; it can go off again afterwards, though rotation stops with it.' },
  { key: 'update_channel', label: 'Update channel', type: 'select',
    options: ['all', 'beta', 'stable'], default: 'all', group: 'Updates',
    note: 'The minimum release maturity this site accepts, on the edge < beta < stable < certified ladder. "all" installs every release (early testing); "beta" takes beta and above (tested, bedding in); "stable" takes stable and certified builds - supported software; "certified" takes only builds whose compliance records were walked before the cut. Out-of-channel upgrades are skipped and logged in the audit trail. Use "stable" for customer sites.' },
];

// SM044: populated by parallel fetch of layouts-available at load time.
// Null means "not yet loaded"; [] means "loaded, but none installed".
var availableLayouts = null;

// SM277 (deferred half of SM180): the RECIPROCAL of the dormant-capability
// indicator. The Groups and Users grids answer "this grant does nothing because
// the service is off" - the grant's side. An operator standing at the switch
// needs the other direction: how many accounts lose this channel if I turn it
// off. Populated by loadCapabilityHolders(); {} until it arrives, and left {} if
// the call is refused (see below), so the page renders identically either way.
var capHolders = {};
var channelForKey = {};

// The counts come from action=users/capability-holders, which sits behind
// manage_users - an operator with manage_config but not manage_users may edit
// these switches and cannot enumerate accounts. That refusal is CORRECT and the
// page must not treat it as an error: no counts is a quieter, truthful state
// than a count of zero, which would read as "nothing depends on this".
function loadCapabilityHolders() {
  fetch(API + '?action=channel-services').then(function(r) { return r.json(); })
    .then(function(d) {
      channelForKey = (d && d.ok && d.channel_for_key) || {};
      // The users sub-dispatcher takes its action in the POST body. CSRF is
      // added by the manager's fetch wrapper, as everywhere else on this page.
      return fetch(API + '?action=users', {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'capability-holders' })
      }).then(function(r) { return r.json(); });
    })
    .then(function(d) {
      if (d && d.ok && d.holders) { capHolders = d.holders; refreshServiceCounts(); }
    })
    .catch(function() { /* no counts; the switches still work */ });
}

// Rendered after the form exists, and re-rendered when the counts land, so the
// form is never blocked on a call that may be refused.
function refreshServiceCounts() {
  Object.keys(channelForKey).forEach(function(key) {
    var el = document.getElementById('cfg-holders-' + key);
    if (!el) return;
    var h = capHolders[channelForKey[key]];
    if (!h) { el.textContent = ''; return; }
    var g = h.groups, u = h.users;
    if (!g && !u) {
      el.innerHTML = '<span class="mg-muted">Held by no group &mdash; switching this '
        + 'off affects nobody today.</span>';
      return;
    }
    // Groups are named (the operator can act on them); accounts are a count
    // only - the Users page answers "which account" per account, and listing
    // them here would put a roster on the settings screen for no gain.
    el.innerHTML = '<span class="mg-holder-count" title="'
      + esc(g ? 'Granted by: ' + (h.group_names || []).join(', ') : '')
      + '">Held by <b>' + g + '</b> group' + (g === 1 ? '' : 's')
      + ' / <b>' + u + '</b> account' + (u === 1 ? '' : 's')
      + '. Switching this off makes those grants inert.</span>';
  });
}

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
      refreshServiceCounts();      // fills in if the counts already arrived
      loadCapabilityHolders();
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

// SM623: one button per service group, flipping exactly that group's switches.
// The sets are written out rather than derived from the schema, because the
// schema says which GROUP a toggle is in and this says what a WORKING setup
// looks like - and those are allowed to differ. t/unit/manager/124 pins them to
// each other so a toggle cannot join a group and be silently left out.
//
// Sets and marks dirty; does NOT save. The operator sees what changed and
// presses Save, so a preset can never alter a live site by itself - and turning
// a service on is exactly the kind of change that should be looked at once.
var SERVICE_PRESETS = {
  web: {
    label: 'Turn these on',
    sets: { mcp_enabled: 'enabled', oauth_enabled: 'enabled' }
  },
  agent: {
    label: 'Turn these on',
    sets: { control_api_enabled: 'enabled', webdav_enabled: 'enabled',
            token_exchange_enabled: 'enabled' }
  }
};

function applyPreset(name) {
  var p = SERVICE_PRESETS[name];
  if (!p) return;
  var changed = [], already = [];
  Object.keys(p.sets).forEach(function(k) {
    var h = document.getElementById('cfg-' + k);
    if (!h) return;                       // not on this page - say nothing
    if (h.value === p.sets[k]) { already.push(k); return; }
    h.value = p.sets[k];
    var row = h.closest ? h.closest('.mg-form-row') : null;
    var cb = row ? row.querySelector('input.mg-toggle') : null;
    if (cb) cb.checked = (p.sets[k] === 'enabled');
    changed.push(k);
  });
  var form = document.getElementById('site-form');
  if (form) applyShowWhen(form);
  if (!changed.length) {
    showStatus('Already on - nothing to change.');
    return;
  }
  markSiteDirty();
  // Name the count rather than the keys: the switches are on screen and now
  // visibly moved, so repeating their names adds nothing. What the operator
  // cannot see is that this is UNSAVED.
  showStatus(changed.length + ' switch' + (changed.length === 1 ? '' : 'es') +
    ' turned on - press Save to apply.');
}

function renderSiteForm(values) {
  var html = '<form id="site-form" onsubmit="saveSiteSettings(event)" oninput="markSiteDirty()" onchange="markSiteDirty()">';
  // Emit a group heading only when the group CHANGES, so consecutive fields in
  // one group (e.g. the Services toggles) sit under a single heading.
  var lastGroup = null;
  SITE_SCHEMA.forEach(function(f) {
    if (f.group && f.group !== lastGroup) {
      html += '<h3 class="mg-config-group">' + esc(f.group) + '</h3>';
      // The preset rides on the FIRST field of its group, so the button lands
      // under the heading it belongs to.
      if (f.group_preset && SERVICE_PRESETS[f.group_preset]) {
        html += '<div class="mg-config-preset">'
             +  '<button type="button" class="mg-btn mg-btn-sm" onclick="applyPreset(\''
             +  esc(f.group_preset) + '\')">'
             +  esc(SERVICE_PRESETS[f.group_preset].label) + '</button>'
             +  '<span class="mg-muted">Sets every switch in this group. Nothing is saved until you press Save.</span>'
             +  '</div>';
      }
    }
    if (f.group) lastGroup = f.group;
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
    // SM277: an anchor for the reciprocal count, emitted for every field so
    // refreshServiceCounts can fill in whichever ones map to a channel. Empty
    // until the count arrives, and it stays empty for a service with no
    // capability of its own (OAuth and the token exchange serve other channels
    // rather than being held by anyone) - which is why this is driven by the
    // server's channel_for_key map rather than by the group heading.
    html += '<div class="mg-config-help mg-holder-line" id="cfg-holders-' + esc(f.key) + '"></div>';
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
