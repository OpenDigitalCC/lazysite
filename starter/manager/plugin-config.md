---
title: Plugin Config
auth: manager
search: false
---

<div id="plugin-list">Loading...</div>

<div class="mg-card" id="audit-report-card" style="display:none">
  <div class="mg-card-header">
    <span class="mg-card-title">Audit Report</span>
    <span class="mg-card-subtitle" id="audit-timestamp"></span>
  </div>
  <div class="mg-card-body" id="audit-report">
    <!-- report renders here -->
  </div>
</div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';
var smtpPlugin = null;
var allHandlers = [];
var handlerTypes = [];
var smtpConnectionLoaded = false;
var smtpConnectionValues = {};

function esc(s) { return (s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }
function val(id) { var el = document.getElementById(id); return el ? el.value : ''; }

// SM118 pattern (field report): every explicit-save surface on this page - the
// per-plugin config forms, the handler add/edit forms and the form targets -
// flags unsaved changes via the shared mgDirtyGuard (manager layout). Each
// surface gets its own key so saving or cancelling one never un-flags another.
function markPluginDirty(id)   { mgDirtyGuard.set('plugin-' + id, 'dirty-' + id); }
function clearPluginDirty(id)  { mgDirtyGuard.clear('plugin-' + id); }
function markHandlerDirty(fid) { mgDirtyGuard.set('handler-' + fid, 'handler-dirty-' + fid); }
function clearHandlerDirty(fid){ mgDirtyGuard.clear('handler-' + fid); }
function markTargetsDirty(f)   { mgDirtyGuard.set('targets-' + f, 'targets-dirty-' + f); }
function clearTargetsDirty(f)  { mgDirtyGuard.clear('targets-' + f); }

// SM664: the all-files history overview, moved here from the Files page.
//
// It is a report ABOUT the repository, not a file operation, and on the Files
// page seeing it required the Files app - full read and write over content -
// for somebody who only needed to know what changed. SM461 argued that and was
// declined in August; the release manager reversed it on 2026-08-28. The
// control-API action now accepts manage_content OR manage_config, so the
// audience of THIS page can read it.
//
// The per-file History panel stays on Files. That one IS a file operation and
// belongs beside the file.
var HIST_OVERVIEW = { rows: [], sort: 'latest', dir: -1 };

// Ported with the overview: this page had neither helper, and moving the code
// without them would have thrown at render time.
function histEsc(s) { return esc(s); }
function histTime(mtime) {
  if (!mtime) return '';
  var d = new Date(mtime * 1000);
  function p(n) { return (n < 10 ? '0' : '') + n; }
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate())
       + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
}

function openHistoryOverview() {
  var body = mgPluginModal('Content history - all files');
  body.innerHTML = '<p class="mg-muted">Loading&hellip;</p>';
  // SM461: mgJson, not r.json(). Any non-JSON body - a 500, a die, a proxy
  // timeout page - used to become "JSON.parse: unexpected character at line 1
  // column 1", which reads as the HISTORY being corrupt while the data was
  // always fine. Carried across with the code, because the fault it guards
  // against is a property of the fetch, not of the page it sat on.
  fetch(API + '?action=git-history-summary')
    .then(function(r) { return (window.mgJson ? window.mgJson(r) : r.json()); })
    .then(function(d) {
      var b = document.getElementById('plugin-modal-body');
      if (!b) return;
      if (!d.ok) { b.innerHTML = '<p class="mg-muted">' + histEsc(d.error || 'No history available') + '</p>'; return; }
      if (!d.enabled) { b.innerHTML = '<p class="mg-muted">Content history is not enabled.</p>'; return; }
      HIST_OVERVIEW.rows = d.files || [];
      HIST_OVERVIEW.summary = d.summary || { files: 0, revisions: 0 };
      renderHistoryOverview();
    })
    .catch(function(e) {
      var b = document.getElementById('plugin-modal-body');
      if (b) b.innerHTML = '<p class="mg-muted">The history overview could not be '
        + 'loaded: ' + histEsc(e.message) + '</p>';
    });
}

function sortHistoryOverview(col) {
  if (HIST_OVERVIEW.sort === col) { HIST_OVERVIEW.dir = -HIST_OVERVIEW.dir; }
  else { HIST_OVERVIEW.sort = col; HIST_OVERVIEW.dir = (col === 'path') ? 1 : -1; }
  renderHistoryOverview();
}

function renderHistoryOverview() {
  var body = document.getElementById('plugin-modal-body');
  if (!body) return;
  var rows = HIST_OVERVIEW.rows.slice();
  var col = HIST_OVERVIEW.sort, dir = HIST_OVERVIEW.dir;
  rows.sort(function(a, b) {
    if (col === 'path' || col === 'last_author') {
      var as = String(a[col] || ''), bs = String(b[col] || '');
      return as < bs ? -dir : as > bs ? dir : 0;
    }
    return ((a[col] || 0) - (b[col] || 0)) * dir;
  });
  var s = HIST_OVERVIEW.summary || { files: 0, revisions: 0 };
  if (!rows.length) {
    body.innerHTML = '<p class="mg-muted">No files under content history yet.</p>';
    return;
  }
  var html = '<p class="mg-muted">' + s.files + ' file' + (s.files === 1 ? '' : 's')
           + ' under history, ' + s.revisions + ' revision' + (s.revisions === 1 ? '' : 's') + ' in total.</p>'
           + '<table class="mg-table"><thead><tr>'
           + '<th class="mg-sortable" onclick="sortHistoryOverview(\'path\')">Path</th>'
           + '<th class="mg-sortable" onclick="sortHistoryOverview(\'revisions\')">Revisions</th>'
           + '<th class="mg-sortable" onclick="sortHistoryOverview(\'first\')">First</th>'
           + '<th class="mg-sortable" onclick="sortHistoryOverview(\'latest\')">Latest</th>'
           + '<th class="mg-sortable" onclick="sortHistoryOverview(\'last_author\')">Last author</th>'
           + '</tr></thead><tbody>';
  for (var i = 0; i < rows.length; i++) {
    var r = rows[i];
    html += '<tr>'
          + '<td>' + histEsc(r.path) + '</td>'
          + '<td>' + histEsc(String(r.revisions)) + '</td>'
          + '<td>' + histEsc(histTime(r.first)) + '</td>'
          + '<td>' + histEsc(histTime(r.latest)) + '</td>'
          + '<td>' + histEsc(r.last_author || '') + '</td>'
          + '</tr>';
  }
  html += '</tbody></table>';
  body.innerHTML = html;
}

// SM640: the plugin config modal. ONE shell, opened by any plugin that has been
// converted to the mechanism, and it fetches its own data and owns its own
// reload - which is the whole point: a change to one plugin no longer re-renders
// every other plugin's configuration.
//
// Deliberately a SECOND shell rather than a generalisation of openSubsModal
// (SM182/SM187) for now. That one carries a form selector in its header and is
// driven by the submissions viewer's own state; merging them is a refactor with
// no behaviour to show for it, and this page is being converted one plugin at a
// time (SM640's own rule) rather than rewritten.
function mgPluginModal(title) {
  mgPluginModalClose(true);
  var ov = document.createElement('div');
  ov.id = 'plugin-modal';
  ov.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,0.5);z-index:1000;display:flex;align-items:center;justify-content:center;';
  ov.innerHTML =
      '<div style="background:var(--mg-bg,#fff);color:var(--mg-text,inherit);width:92%;max-width:760px;max-height:86vh;border-radius:8px;display:flex;flex-direction:column;overflow:hidden;">'
    + '<div style="display:flex;align-items:center;gap:8px;padding:10px 14px;border-bottom:1px solid var(--mg-border,#ddd);">'
    + '<strong id="plugin-modal-title" style="flex:1"></strong>'
    + '<button class="mg-btn mg-btn-sm" onclick="mgPluginModalClose()">Close</button></div>'
    + '<div id="plugin-modal-body" style="flex:1;overflow:auto;padding:12px 14px;"></div></div>';
  // Clicking the backdrop closes, and goes through the same unsaved-changes
  // question as the button - an accidental click outside must not be a quieter
  // way to lose an edit than pressing Close.
  ov.addEventListener('click', function(e) { if (e.target === ov) mgPluginModalClose(); });
  document.body.appendChild(ov);
  document.getElementById('plugin-modal-title').textContent = title || 'Configuration';
  return document.getElementById('plugin-modal-body');
}

// force: skip the unsaved-changes question (used when re-opening, and after a
// successful save has already cleared the flag).
function mgPluginModalClose(force) {
  var ov = document.getElementById('plugin-modal');
  if (!ov) return;
  var id = ov.getAttribute('data-plugin') || '';
  if (!force && id && mgDirtyGuard && mgDirtyGuard.isDirty('plugin-' + id)) {
    if (!confirm('This configuration has unsaved changes. Close and lose them?')) return;
  }
  if (id) clearPluginDirty(id);
  if (ov.parentNode) ov.parentNode.removeChild(ov);
}

function shouldRenderPlugin(plugin, allPlugins) {
  if (plugin.id === 'form-smtp') {
    return !allPlugins.some(function(p) { return p.id === 'form-handler' && p._enabled; });
  }
  return true;
}

function loadPlugins() {
  document.getElementById('plugin-list').textContent = 'Scanning...';
  fetch(API + '?action=plugin-list')
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) {
        document.getElementById('plugin-list').textContent = data.error || 'Failed to load plugins';
        return;
      }
      window._plugins = data.plugins || [];
      renderPlugins(data.plugins || []);
    });
}

function renderPlugins(plugins) {
  var enabled = (plugins || []).filter(function(p) { return p._enabled; });

  if (!enabled.length) {
    document.getElementById('plugin-list').innerHTML =
      '<p class="mg-empty">No plugins enabled. Visit <a href="/manager/config">Configuration</a> to enable plugins.</p>';
    return;
  }

  var html = '';
  var childPlugins = [];

  enabled.forEach(function(p) {
    if (!shouldRenderPlugin(p, plugins)) return;
    html += renderPluginCard(p);
    if (p.child_configs) childPlugins.push(p);
  });

  document.getElementById('plugin-list').innerHTML = html;
  childPlugins.forEach(function(p) { loadChildConfigs(p); });

  // Initialise handler section if form-handler is enabled
  var fhPlugin = plugins.find(function(p) { return p.id === 'form-handler' && p._enabled; });
  if (fhPlugin) {
    handlerTypes = fhPlugin.handler_types || [];
    smtpPlugin = plugins.find(function(p) { return p.id === 'form-smtp' && p._enabled; });
    loadHandlers();
  }
}

// SM640: a LINE per enabled plugin - name, state, and a way in - rather than
// every plugin's whole configuration rendered inline one after another. The
// page no longer grows with the number of plugins installed.
//
// What stays on the row: the plugin's own actions, and the containers for the
// things that are NOT its config form - child configs (the forms plugin renders
// its handler list into one), an action's choice prompt, and the status line.
// Those keep their identity and their position, so nothing that moves DOM nodes
// around - the add-handler wizard does - finds its container inside a modal
// that has since been destroyed.
function renderPluginCard(plugin) {
  var hasConfig = !!(plugin.config_schema && plugin.config_schema.length);
  // A CARD IS NOT A ROW. Carrying both meant the card inherited the row grid,
  // so its stacked contents - title, description, the action group and the
  // full-width panels below them - were laid out as columns of a line.
  var html = '<div class="mg-plugin-card" id="plugin-' + esc(plugin.id) + '">';
  html += '<div class="mg-plugin-title">' + esc(plugin.name) + '</div>';
  html += '<div class="mg-plugin-desc">' + esc(plugin.description) + '</div>';
  // The group opens unconditionally, because Configure and the per-plugin
  // buttons below belong to it even when the plugin declares no actions of its
  // own. Opening it only for declared actions is what left those buttons
  // outside the group, each on its own baseline.
  html += '<div class="mg-wizard-actions">';
  if (plugin.actions && plugin.actions.length) {
    plugin.actions.forEach(function(a, ai) {
      // Lifecycle actions a plugin drives from its enable/disable toggle
      // (on_enable / on_disable) are marked hidden - they are not buttons here,
      // so e.g. content history never shows "Enable" while already enabled.
      if (a.hidden) { return; }
      if (a.link) {
        html += '<a href="' + a.link + '">' + esc(a.label) + '</a>';
      } else if (a.needs) {
        // Gated action (e.g. git-sync "Test connection" needs a remote_url):
        // refuse until the required config key is set, so the button is never a
        // dead end on an unconfigured plugin.
        html += '<button class="mg-btn mg-btn-sm" onclick="runActionGated(\'' + esc(plugin.id) + '\',' + ai + ',\'' + esc(a.needs) + '\')">' + esc(a.label) + '</button>';
      } else {
        html += '<button class="mg-btn mg-btn-sm" onclick="(function(){var p=window._plugins.find(function(x){return x.id===\'' + plugin.id + '\'});runAction(p,p.actions[' + ai + '])})()">' + esc(a.label) + '</button>';
      }
    });
  }
  if (hasConfig) {
    // mg-btn-sm, like every other button in this row. Configure was full size
    // beside small action buttons, so one plugin's controls came in two
    // weights and the odd one out read as more important than the rest.
    html += '<button class="mg-btn mg-btn-sm" onclick="loadConfig(window._plugins.find(function(x){return x.id===\'' + plugin.id + '\'}))">Configure</button>';
  }
  // SM664: content history's way in is a VIEW, not a config form - it declares
  // an empty config_schema, so without this its row would offer nothing at all.
  if (plugin.id === 'content-history') {
    html += '<button class="mg-btn mg-btn-sm" onclick="openHistoryOverview()" title="All files under content history, with per-file revision statistics">History overview</button>';
  }
  // SM703: the blocked-address list belongs to the plugin that does the
  // blocking. It sat on Visitor Statistics, which reads as a reporting filter -
  // and a block is not a reporting filter: lazysite-auth.pl answers a blocked
  // address 403 and exits before anything is served. Putting an access control
  // on a statistics page invites an operator to read it as "hidden from the
  // numbers" rather than "refused the site".
  if (plugin.id === 'bad-url-blocker') {
    html += '<button class="mg-btn mg-btn-sm" onclick="toggleBlocked(this)" '
         +  'aria-controls="blocked-body" aria-expanded="false">Blocked addresses</button>';
  }
  // Every button this plugin offers is now in ONE group, so they share a
  // baseline and wrap together. Panels open BELOW it, full width.
  html += '</div>';
  if (plugin.id === 'bad-url-blocker') {
    html += '<div class="mg-card-body mg-expand-body" id="blocked-body" style="display:none">Loading&hellip;</div>';
  }
  if (plugin.child_configs) {
    html += '<div class="mg-card-body" id="children-' + plugin.id + '">Loading...</div>';
  }
  // SM085: an action result may ask for a choice (needs_choice) - the
  // conflict list + choice buttons render here.
  html += '<div id="choice-' + esc(plugin.id) + '" style="display:none"></div>';
  html += '<div class="mg-status" id="status-' + esc(plugin.id) + '"></div>';
  html += '</div>';
  return html;
}

// --- Generic plugin config ---

// SM639/SM640: the configuration opens in the modal and fetches its own values
// on click, so opening one plugin's config neither renders nor re-reads any
// other plugin's.
function loadConfig(plugin) {
  var body = mgPluginModal(plugin.name);
  document.getElementById('plugin-modal').setAttribute('data-plugin', plugin.id);
  body.textContent = 'Loading...';
  fetch(API + '?action=plugin-read&plugin=' + encodeURIComponent(plugin.id), {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ script: plugin._script })
  })
  .then(function(r) { return window.mgJson ? window.mgJson(r) : r.json(); })
  .then(function(data) {
    // The modal may have been closed while the request was in flight; writing
    // into a detached node would silently do nothing, so check it is still ours.
    var b = document.getElementById('plugin-modal-body');
    if (!b) return;
    if (!data.ok) { b.textContent = data.error || 'Could not read this plugin\'s configuration'; return; }
    b.innerHTML = renderForm(plugin, data.values || {});
    applyShowWhen(b);
  })
  .catch(function(e) {
    var b = document.getElementById('plugin-modal-body');
    if (b) b.textContent = 'Error: ' + e.message;
  });
}

function renderForm(plugin, values) {
  var html = '<form onsubmit="saveConfig(event,\'' + plugin.id + '\',\'' + esc(plugin._script) + '\')"'
           + ' oninput="markPluginDirty(\'' + plugin.id + '\')" onchange="markPluginDirty(\'' + plugin.id + '\')">';
  (plugin.config_schema||[]).forEach(function(f) {
    var v = values[f.key] !== undefined ? values[f.key] : (f.default || '');
    var sw = f.show_when;
    var da = sw ? ' data-show-key="'+sw.key+'" data-show-val="'+sw.value.join(',')+'"' : '';
    html += '<div class="mg-field mg-config-field"'+da+'>';
    html += '<label>' + esc(f.label) + '</label>';
    if (f.type === 'select') {
      html += '<select name="'+f.key+'" onchange="applyShowWhen(this.form)">';
      (f.options||[]).forEach(function(o) { html += '<option'+(v===o?' selected':'')+'>'+o+'</option>'; });
      html += '</select>';
    } else if (f.type === 'boolean') {
      html += '<input type="checkbox" name="'+f.key+'"'+(v==='true'||v==='1'?' checked':'')+' onchange="applyShowWhen(this.form)">';
    } else if (f.type === 'textarea') {
      html += '<textarea name="'+f.key+'" rows="4">'+esc(v)+'</textarea>';
    } else if (f.type === 'password') {
      // autocomplete=new-password: stop the browser pair-autofilling these plugin
      // credential fields with the operator's own saved site login.
      html += '<input type="password" name="'+f.key+'" placeholder="leave blank to keep" autocomplete="new-password">';
    } else if (f.type === 'readonly') {
      html += '<span class="mg-readonly-value">'+esc(v)+'</span>';
    } else {
      var t = f.type==='email'?'email':f.type==='number'?'number':'text';
      html += '<input type="'+t+'" name="'+f.key+'" value="'+esc(v)+'"'+(f.required?' required':'')+' autocomplete="off">';
    }
    html += '</div>';
  });
  html += '<div class="mg-field"><label></label><button type="submit" class="mg-btn mg-btn-primary">Save</button>'
       +  ' <span id="dirty-' + plugin.id + '" class="mg-note mg-note-info" style="display:none">&#9679; Unsaved changes &mdash; click Save</span></div></form>';
  return html;
}

function applyShowWhen(container) {
  if (!container) return;
  var fields = container.querySelectorAll('[data-show-key]');
  for (var i = 0; i < fields.length; i++) {
    var f = fields[i];
    var key = f.dataset.showKey;
    var vals = f.dataset.showVal.split(',');
    var ctrl = document.getElementById(key)
      || (container.querySelector ? container.querySelector('[name="' + key + '"]') : null);
    if (!ctrl) { f.style.display = 'none'; continue; }
    var cur = ctrl.type === 'checkbox' ? (ctrl.checked ? 'true' : 'false') : ctrl.value;
    var show = vals.indexOf(cur) !== -1;
    f.style.display = show ? (f.classList.contains('mg-field') ? 'flex' : 'block') : 'none';
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
  if (status) status.textContent = 'Saving...';
  fetch(API + '?action=plugin-save&plugin=' + encodeURIComponent(pluginId), {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ script: script, values: values })
  })
  .then(function(r) { return r.json(); })
  .then(function(data) {
    if (data.ok) {
      mgClearWarning();
      clearPluginDirty(pluginId);
      // SM639: the page no longer reloads. The saved plugin closes its modal and
      // the list re-reads itself, so a change to one plugin costs one request
      // and leaves every other plugin's state - and the operator's scroll
      // position - alone. The dirty flag is cleared BEFORE the close so the
      // unsaved-changes question does not fire on a successful save.
      mgPluginModalClose(true);
      if (status) status.textContent = 'Saved';
      loadPlugins();
    } else {
      mgShowWarning(data.error || 'Save failed', true);
      if (status) status.textContent = '';
    }
  })
  .catch(function(e) {
    mgShowWarning('Error: ' + e.message, true);
    if (status) status.textContent = '';
  });
}

// Run an action only once its required config key is set; otherwise point the
// operator at the config first (no test-against-nothing).
function runActionGated(pluginId, ai, needs) {
  var p = window._plugins.find(function(x) { return x.id === pluginId; });
  if (!p) return;
  fetch(API + '?action=plugin-read&plugin=' + encodeURIComponent(pluginId), {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ script: p._script })
  })
    .then(function(r) { return r.json(); })
    .then(function(d) {
      var v = (d.ok && d.values && d.values[needs] != null) ? String(d.values[needs]).trim() : '';
      var st = document.getElementById('status-' + pluginId);
      if (!v) {
        if (st) { st.textContent = 'Set "' + needs + '" and Save first, then test.'; st.className = 'mg-status mg-status-error'; }
        return;
      }
      runAction(p, p.actions[ai]);
    });
}

function runAction(plugin, action, params) {
  if (action.confirm) { mgConfirm(action.confirm).then(function(__ok){ if (__ok) runAction_go(plugin, action, params); }); return; }
  runAction_go(plugin, action, params);
}
function runAction_go(plugin, action, params) {
  var status = document.getElementById('status-' + plugin.id);
  status.textContent = 'Running...';
  clearActionChoice(plugin.id);
  fetch(API + '?action=plugin-action&plugin=' + encodeURIComponent(plugin.id), {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ script: plugin._script, action_id: action.id, params: params || {} })
  })
  .then(function(r) { return r.json(); })
  .then(function(data) {
    if (!data.ok) {
      mgShowWarning(data.error || 'Action failed', true);
      status.textContent = '';
      return;
    }
    mgClearWarning();
    // SM085: the action needs a decision (e.g. git-sync's "changed in both
    // places") - render the report and the declared choice buttons; the
    // chosen id is re-posted as params.choice.
    if (data.needs_choice && action.choices && action.choices.length) {
      status.textContent = '';
      renderActionChoice(plugin, action, data);
      return;
    }
    // A diagnostic action (e.g. SMTP validate) returns a human message - show it.
    var msg = data.message || 'Done.';
    if (data.pages && data.pages.length) {
      msg += ' Pages: ' + data.pages.slice(0, 20).join(', ')
           + (data.pages.length > 20 ? ', …' : '');
    }
    status.textContent = msg;
    if (data.message) mgShowWarning(msg, false);

    // Link Audit: render the report inline in the audit-report card
    // rather than opening it in a new tab. Other plugins keep the
    // existing open_url behaviour unchanged.
    if (plugin.id === 'audit' && action.id === 'run' && data.report_url) {
      renderAuditReport(data.report_url);
    }
    else if (action.on_complete === 'open_url' && data[action.result_key]) {
      window.open(data[action.result_key], '_blank');
    }
    // THE RESULT STAYS. It used to be wiped after five seconds, which is
    // right for "Done." and wrong for everything that reports something: the
    // Briefs Status button said "Running...", then briefly gave its answer,
    // then left an empty line - so the button looked like it did nothing.
    //
    // Nothing needs tidying away: the line is replaced by "Running..." the
    // next time an action runs, and .mg-status:empty hides it when there is
    // nothing to say. An answer that removes itself while you are reading it
    // is worse than one that waits to be replaced.
  })
  .catch(function(e) {
    mgShowWarning('Error: ' + e.message, true);
    status.textContent = '';
  });
}

// SM085: the needs_choice panel - the plain-language report, the list of
// items it concerns, one button per declared choice, and Cancel.
function renderActionChoice(plugin, action, data) {
  var box = document.getElementById('choice-' + plugin.id);
  if (!box) { mgShowWarning(data.message || 'A choice is needed.', false); return; }
  var html = '<div class="mg-plugin-desc">' + esc(data.message || 'A choice is needed.') + '</div>';
  if (data.conflicts && data.conflicts.length) {
    html += '<ul>';
    data.conflicts.forEach(function(c) { html += '<li>' + esc(c) + '</li>'; });
    html += '</ul>';
  }
  html += '<div class="mg-wizard-actions">';
  (action.choices || []).forEach(function(c) {
    html += '<button class="mg-btn mg-btn-sm" onclick="chooseAction(\'' + esc(plugin.id)
          + '\',\'' + esc(action.id) + '\',\'' + esc(c.id) + '\')">' + esc(c.label) + '</button>';
  });
  html += '<button class="mg-btn mg-btn-sm" onclick="clearActionChoice(\'' + esc(plugin.id) + '\')">Cancel</button>';
  html += '</div>';
  box.innerHTML = html;
  box.style.display = 'block';
}

function chooseAction(pluginId, actionId, choiceId) {
  var p = (window._plugins || []).find(function(x) { return x.id === pluginId; });
  if (!p) return;
  var a = (p.actions || []).find(function(x) { return x.id === actionId; });
  if (!a) return;
  runAction_go(p, a, { choice: choiceId });
}

function clearActionChoice(pluginId) {
  var box = document.getElementById('choice-' + pluginId);
  if (box) { box.innerHTML = ''; box.style.display = 'none'; }
}

function renderAuditReport(url) {
  var card = document.getElementById('audit-report-card');
  var body = document.getElementById('audit-report');
  var ts   = document.getElementById('audit-timestamp');
  if (!card || !body) return;

  body.textContent = 'Loading report...';
  card.style.display = '';

  fetch(url, { credentials: 'same-origin' })
    .then(function(r) { return r.text(); })
    .then(function(html) {
      // The report is a full HTML page rendered by the processor.
      // Extract just the <main> content so the surrounding chrome
      // (nav, footer) from the report's own view.tt doesn't duplicate
      // the manager layout.
      var parser = new DOMParser();
      var doc    = parser.parseFromString(html, 'text/html');
      var main   = doc.querySelector('main') || doc.body;
      body.innerHTML = '';
      if (main) {
        // Copy children rather than re-assigning innerHTML so scripts
        // inside the report don't execute.
        Array.prototype.forEach.call(main.childNodes, function(n) {
          body.appendChild(document.importNode(n, true));
        });
      }

      // Prefer the <time datetime> emitted in the starter theme footer,
      // otherwise fall back to the page's <h1>/subtitle, otherwise now.
      var stamp = '';
      var t = body.querySelector('time[datetime]');
      if (t) stamp = t.getAttribute('datetime') || t.textContent || '';
      if (!stamp) {
        var sub = doc.querySelector('main > p');
        if (sub) stamp = sub.textContent || '';
      }
      if (!stamp) stamp = new Date().toISOString().replace('T',' ').replace(/\..*$/,'');
      if (ts) ts.textContent = stamp;
    })
    .catch(function(e) {
      body.textContent = 'Failed to load report: ' + e.message;
      if (ts) ts.textContent = '';
    });
}

// --- Form handler: child configs ---

function loadChildConfigs(plugin) {
  var cc = plugin.child_configs;
  if (!cc) return;
  var container = document.getElementById('children-' + plugin.id);

  handlerTypes = plugin.handler_types || [];

  var fetches = [
    fetch(API + '?action=handler-list').then(function(r) { return r.json(); }),
    fetch(API + '?action=list&path=/' + (cc.pattern || '').replace(/\/[^/]*$/, ''))
      .then(function(r) { return r.json(); })
  ];
  if (smtpPlugin) {
    fetches.push(fetch(API + '?action=plugin-read&plugin=form-smtp', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ script: smtpPlugin._script })
    }).then(function(r) { return r.json(); }));
  }

  Promise.all(fetches).then(function(results) {
    var handlersData = results[0];
    var filesData = results[1];
    allHandlers = (handlersData.ok ? handlersData.handlers : []) || [];

    if (results[2] && results[2].ok) {
      smtpConnectionValues = results[2].values || {};
      smtpConnectionLoaded = true;
    }

    container.innerHTML = '<div id="handler-list"></div>';
    renderHandlerList();

    // Build Form Connections as a separate card
    var exclude = cc.exclude || [];
    var dir = (cc.pattern || '').replace(/\/[^/]*$/, '');
    var files = [];
    if (filesData.ok && filesData.entries) {
      files = filesData.entries.filter(function(e) {
        return e.type === 'file' && e.name.match(/\.conf$/) && exclude.indexOf(e.name) < 0;
      });
    }

    var existing = document.getElementById('form-connections-card');
    if (existing) existing.remove();

    var cardHtml = '<div class="mg-plugin-card" id="form-connections-card">';
    cardHtml += '<div class="mg-plugin-title">Form Connections</div>';
    cardHtml += '<div class="mg-plugin-desc">Connect each form to its dispatch handlers.</div>';
    if (files.length) {
      files.forEach(function(f) {
        var formName = f.name.replace(/\.conf$/, '');
        cardHtml += '<div class="mg-form-entry">';
        cardHtml += '<div class="mg-form-entry-header">';
        cardHtml += '<span class="mg-form-name">' + esc(formName) + '</span>';
        cardHtml += '<button class="mg-btn mg-btn-sm" onclick="toggleFormTargets(\'' + esc(formName) + '\')">Edit targets</button>';
        cardHtml += '<a href="/manager/edit?path=/' + encodeURIComponent(dir + '/' + f.name) + '" style="font-size:11px;color:var(--mg-accent);">Edit raw</a>';
        cardHtml += '</div>';
        cardHtml += '<div id="form-targets-' + formName + '" style="display:none"></div>';
        cardHtml += '</div>';
      });
    } else {
      cardHtml += '<p style="font-size:13px;color:var(--mg-text-muted);">No form configs found.</p>';
    }
    cardHtml += '<div class="mg-status" id="status-form-connections"></div>';
    cardHtml += '</div>';

    var pluginCard = document.getElementById('plugin-' + plugin.id);
    pluginCard.insertAdjacentHTML('afterend', cardHtml);
  });
}

// --- Blocked addresses (SM128, moved here by SM703) ---

function toggleBlocked(btn) {
  var el = document.getElementById('blocked-body');
  if (!el) return;
  var open = el.style.display !== 'none';
  el.style.display = open ? 'none' : '';
  btn.setAttribute('aria-expanded', open ? 'false' : 'true');
  if (!open) loadBlocked();
}

function loadBlocked() {
  var el = document.getElementById('blocked-body');
  if (!el) return;
  fetch(API + '?action=bad-url-blocks').then(function (r) { return r.json(); }).then(function (d) {
    if (!d || !d.ok) { el.innerHTML = '<p class="mg-muted">' + esc((d && d.error) || 'Unavailable.') + '</p>'; return; }
    var ips = Object.keys(d.blocks || {});
    if (!ips.length) { el.innerHTML = '<p class="mg-muted">No addresses are currently blocked.</p>'; return; }
    ips.sort(function (a, b) { return (d.blocks[b].since || 0) - (d.blocks[a].since || 0); });
    var h = '<div class="mg-line" style="margin:0 0 10px;">'
          + '<input class="mg-inp" id="block-add-ip" placeholder="203.0.113.4" '
          +   'style="max-width:14rem" onkeydown="if(event.key===\'Enter\')addBlock()">'
          + '<button class="mg-btn" onclick="addBlock()">Block this address</button>'
          + '</div>'
          + '<p class="mg-muted">A blocked address is refused the site &mdash; it receives 403 and is served nothing. '
          + 'Unblocking takes effect on its next request.</p>'
          + '<div class="mg-table-wrap"><table class="mg-table"><thead><tr>'
          + '<th>Address</th><th>Probes</th><th>Blocked since</th><th></th></tr></thead><tbody>';
    ips.forEach(function (ip) {
      var b = d.blocks[ip];
      var since = b.since ? new Date(b.since * 1000).toLocaleString() : '';
      h += '<tr><td><code>' + esc(ip) + '</code></td><td>' + esc(String(b.count))
         + '</td><td>' + esc(since) + '</td><td>'
         + '<button class="mg-btn mg-btn-sm" onclick="unblockIp(\'' + esc(ip).replace(/'/g, '') + '\')">Unblock</button>'
         + '</td></tr>';
    });
    el.innerHTML = h + '</tbody></table></div>';
  }).catch(function (e) { el.textContent = 'Error: ' + e.message; });
}

// SM704: block an address the operator names. The auto-blocker catches a
// probe once it trips a threshold; an operator watching one in the access log
// should not have to wait for that.
function addBlock() {
  var el = document.getElementById('block-add-ip');
  var ip = (el && el.value || '').replace(/^\s+|\s+$/g, '');
  if (!ip) return;
  fetch(API + '?action=bad-url-block&ip=' + encodeURIComponent(ip), {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}'
  })
    .then(function (r) { return r.json(); })
    .then(function (d) {
      if (!d || !d.ok) { showStatus((d && d.error) || 'Could not block', true); return; }
      showStatus(d.added ? 'Blocked ' + ip + '.' : ip + ' was already blocked.');
      el.value = '';
      loadBlocked();
    })
    .catch(function (e) { showStatus('Error: ' + e.message, true); });
}

function unblockIp(ip) {
  fetch(API + '?action=bad-url-unblock&ip=' + encodeURIComponent(ip), { method: 'POST' })
    .then(function (r) { return r.json(); })
    .then(function (d) {
      if (!d || !d.ok) { showStatus((d && d.error) || 'Unblock failed', true); return; }
      showStatus('Unblocked ' + ip + '.');
      loadBlocked();
    })
    .catch(function (e) { showStatus('Error: ' + e.message, true); });
}

// --- Handler list (grouped by type) ---

function renderHandlerList() {
  var typeOrder = ['smtp', 'file', 'webhook'];
  var typeLabels = { smtp: 'Email (SMTP)', file: 'File storage', webhook: 'Webhooks' };
  var typeAddLabel = { smtp: '+ Add email handler', file: '+ Add file handler', webhook: '+ Add webhook' };

  var html = '';

  typeOrder.forEach(function(type) {
    var ofType = allHandlers.filter(function(h) { return h.type === type; });

    html += '<div class="mg-handler-group" id="mg-handler-group-' + type + '">';
    html += '<div class="mg-handler-group-header">';
    html += '<span class="mg-handler-group-label">' + typeLabels[type] + '</span>';
    html += '<button class="mg-btn mg-btn-sm" onclick="showAddHandlerForm(\'' + type + '\')">' + typeAddLabel[type] + '</button>';
    html += '</div>';

    ofType.forEach(function(h) {
      var enabled = h.enabled !== 'false';
      html += '<div class="mg-handler-item" id="handler-' + h.id + '">';
      // The same row idiom as Files and Data, rather than a fourth way of
      // drawing a line with a name and some buttons on it.
      html += '<div class="mg-row mg-handler-item-header">';
      html += '<span class="mg-handler-name">' + esc(h.name || h.id) + '</span>';
      html += '<span class="mg-tag ' + (enabled ? 'enabled' : 'disabled') + '">' + (enabled ? 'enabled' : 'disabled') + '</span>';
      // File-storage handlers: inline "View submissions" slot. Populated
      // asynchronously once we know whether the configured directory
      // exists on disk. data-submissions-for="<id>" lets one fetch
      // update both the inline slot and the equivalent row in the
      // expanded edit form in a single callback.
      if (h.type === 'file') {
        html += '<span data-submissions-for="' + esc(h.id) + '" class="mg-handler-submissions" style="margin-left:0.5rem">';
        html += '<span style="font-size:0.8rem;color:var(--mg-text-light)">Checking...</span>';
        html += '</span>';
      }
      html += '<div class="mg-handler-item-actions">';
      html += '<button class="mg-btn mg-btn-sm" onclick=\'editHandler(' + JSON.stringify(h).replace(/'/g, "&#39;") + ')\'>Edit</button>';
      html += '<button class="mg-btn mg-btn-danger" onclick="deleteHandler(\'' + esc(h.id) + '\')">Delete</button>';
      html += '</div></div>';
      html += '<div class="mg-expand mg-expand-body mg-handler-edit-form" id="handler-edit-' + h.id + '" style="display:none"></div>';
      html += '<div class="mg-expand mg-expand-body mg-submissions-panel" id="submissions-panel-' + esc(h.id) + '" style="display:none"></div>';
      html += '</div>';
    });

    if (ofType.length === 0) {
      html += '<p class="mg-empty">No ' + typeLabels[type].toLowerCase() + ' handlers configured.</p>';
    }

    // SM639/SM640: EACH GROUP OWNS ITS WIZARD SLOT.
    //
    // There used to be one wizard node after the whole list, and opening the
    // form MOVED it into the group being added to. That relocation is what
    // kept this section out of the shared config modal - a modal destroyed on
    // close takes the moved node with it - and both filings recorded it as
    // the blocker. Nothing moves now: the slot is rendered where it is used.
    html += '<div class="mg-handler-wizard" id="add-handler-wizard-' + type + '" style="display:none"></div>';

    html += '</div>';
  });

  document.getElementById('handler-list').innerHTML = html;

  // Kick off the "View submissions" probe for each file handler.
  allHandlers.forEach(function(h) {
    if (h.type === 'file') checkSubmissionsDir(h);
  });
}

// Normalise a handler.path (e.g. "lazysite/forms/submissions" or
// "/lazysite/forms/submissions") to the shape the manager-api's `list`
// action and the file browser's hash navigation both expect: leading /
// and trailing /.
function submissionsPath(raw) {
  if (!raw) return '/';
  var p = String(raw);
  if (p.charAt(0) !== '/') p = '/' + p;
  if (p.charAt(p.length - 1) !== '/') p = p + '/';
  return p;
}

function checkSubmissionsDir(handler) {
  var slots = document.querySelectorAll(
    '[data-submissions-for="' + handler.id + '"]');
  if (!slots.length) return;

  var path = submissionsPath(handler.path);
  fetch(API + '?action=list&path=' + encodeURIComponent(path))
    .then(function(r) { return r.json(); })
    .then(function(data) {
      var html;
      if (data.ok) {
        // SM182: open an inline, escaped submissions TABLE. (The raw .jsonl
        // store lives in the reserved lazysite/ tree and can't be opened in the
        // file editor, so we render it here instead of deep-linking to Files.)
        html = '<button class="mg-btn mg-btn-sm" onclick=\'toggleSubmissions('
             + JSON.stringify(handler.id).replace(/'/g, '&#39;') + ', '
             + JSON.stringify(path).replace(/'/g, '&#39;')
             + ')\'>View submissions</button>';
      } else {
        html = '<span style="font-size:0.8rem;color:var(--mg-text-light)">No submissions yet</span>';
      }
      slots.forEach(function(el) { el.innerHTML = html; });
    })
    .catch(function() {
      slots.forEach(function(el) {
        el.innerHTML = '<span style="font-size:0.8rem;color:var(--mg-text-light)">No submissions yet</span>';
      });
    });
}

// --- SM182/SM187: submissions viewer (scrollable modal + per-row delete) -----
// The raw .jsonl store lives in the reserved lazysite/ tree, so it can't be
// opened in the file editor. Show it in a scrollable MODAL table instead. Values
// are user-supplied, so EVERY cell/header/label goes through esc(). A handled row
// can be deleted by its stable _id (server rewrites the store).

function toggleSubmissions(handlerId, dirPath) {
  openSubsModal();
  setSubsBody('<p style="color:var(--mg-text-light)">Loading submissions&hellip;</p>', 'Submissions');
  fetch(API + '?action=list&path=' + encodeURIComponent(dirPath))
    .then(function(r) { return r.json(); })
    .then(function(data) {
      var files = (data.ok && data.entries ? data.entries : []).filter(function(f) {
        return f.type === 'file' && /\.jsonl$/.test(f.name || '');
      });
      if (!files.length) { setSubsBody('<p style="color:var(--mg-text-light)">No submissions yet.</p>', 'Submissions'); return; }
      // A form selector in the modal header when the store holds more than one.
      var fsel = document.getElementById('subs-modal-forms');
      if (files.length > 1 && fsel) {
        var sel = '<select onchange="showSubmissionTable(this.value, this.options[this.selectedIndex].text)">';
        files.forEach(function(f) {
          var form = (f.name || '').replace(/\.jsonl$/, '');
          sel += '<option value="' + esc(f.path) + '">' + esc(form) + '</option>';
        });
        fsel.innerHTML = sel + '</select>';
      }
      showSubmissionTable(files[0].path, (files[0].name || '').replace(/\.jsonl$/, ''));
    })
    .catch(function() { setSubsBody('<p style="color:var(--mg-danger,#c00)">Could not list submissions.</p>', 'Submissions'); });
}

// SM216: a quarantine filter, kept per-open so a reload keeps the view.
var subsFilter  = 'all';   // 'all' | 'quarantined'
var subsCurrent = null;
var subsLoaded  = null;    // SM187: last-loaded {file,form,cols,rows} for CSV/bulk
function setSubsFilter(f) { subsFilter = f; if (subsCurrent) showSubmissionTable(subsCurrent.file, subsCurrent.form); }

function showSubmissionTable(filePath, formName) {
  subsCurrent = { file: filePath, form: formName };
  setSubsBody('<p style="color:var(--mg-text-light)">Loading ' + esc(formName) + '&hellip;</p>', 'Submissions: ' + formName);
  fetch(API + '?action=form-submissions&file=' + encodeURIComponent(filePath))
    .then(function(r) { return r.json(); })
    .then(function(d) {
      if (!d.ok) { setSubsBody('<p style="color:var(--mg-danger,#c00)">' + esc(d.error || 'Could not read submissions') + '</p>', 'Submissions'); return; }
      // SM216: _quarantined / _spam_reason are status meta, not form fields - drive
      // the row marking, not a data column.
      var META = { _quarantined: 1, _spam_reason: 1 };
      var cols = (d.columns || []).filter(function(c) { return !META[c]; });
      var rows = d.rows || [];
      if (!rows.length || !cols.length) {
        setSubsBody('<p style="color:var(--mg-text-light)">No submissions in ' + esc(formName) + ' yet.</p>', 'Submissions: ' + formName);
        return;
      }
      var qcount = rows.filter(function(r) { return r._quarantined; }).length;
      var view = (subsFilter === 'quarantined') ? rows.filter(function(r) { return r._quarantined; }) : rows;
      subsLoaded = { file: filePath, form: formName, cols: cols, rows: rows };   // SM187

      // SM187: a toolbar - quarantine filter (if any) on the left, CSV export and
      // bulk delete (of the checked rows) on the right.
      var h = '<div style="display:flex;flex-wrap:wrap;gap:0.4rem;align-items:center;margin:0 0 0.5rem;font-size:0.85rem">';
      if (qcount) {
        h += '<span><strong>' + qcount + '</strong> quarantined (suspected spam, kept out of notifications).</span> '
           + '<button class="mg-btn mg-btn-sm" onclick="setSubsFilter(\'all\')"' + (subsFilter === 'all' ? ' disabled' : '') + '>All</button> '
           + '<button class="mg-btn mg-btn-sm" onclick="setSubsFilter(\'quarantined\')"' + (subsFilter === 'quarantined' ? ' disabled' : '') + '>Quarantine only</button>';
      }
      h += '<span style="margin-left:auto"></span>'
         + '<button class="mg-btn mg-btn-sm" onclick="downloadSubmissionsCsv()">Download CSV</button> '
         + '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="bulkDeleteSubmissions()">Delete selected</button>'
         + '</div>';

      h += '<div class="mg-table-wrap"><table class="mg-table mg-submissions-table"><thead><tr>'
         + '<th><input type="checkbox" title="Select all" onclick="subsToggleAll(this)"></th><th>Status</th>';
      cols.forEach(function(c) { h += '<th>' + esc(c) + '</th>'; });
      h += '<th></th></tr></thead><tbody>';
      view.forEach(function(row) {
        var q = row._quarantined;
        h += '<tr' + (q ? ' style="background:var(--mg-warn-bg,#fff8e1)"' : '') + '>';
        h += '<td><input type="checkbox" class="mg-sub-cb" value="' + esc(row._id) + '"></td>';
        h += '<td>' + (q ? '<span class="mg-tag mg-tag-off" title="' + esc(row._spam_reason || '') + '">quarantined</span>' : '') + '</td>';
        cols.forEach(function(c) { h += '<td>' + esc(row[c] == null ? '' : row[c]) + '</td>'; });
        var args = JSON.stringify(filePath).replace(/'/g, '&#39;') + ', '
                 + JSON.stringify(row._id).replace(/'/g, '&#39;') + ', '
                 + JSON.stringify(formName).replace(/'/g, '&#39;');
        h += '<td style="white-space:nowrap">';
        if (q) h += '<button class="mg-btn mg-btn-sm" onclick=\'confirmSubmissionRow(' + args + ')\'>Confirm</button> ';
        h += '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick=\'deleteSubmissionRow(' + args + ')\'>Delete</button>';
        h += '</td></tr>';
      });
      h += '</tbody></table></div>';
      var note = 'Showing ' + d.shown + ' of ' + d.total + ' submission' + (d.total === 1 ? '' : 's');
      if (d.truncated) note += ' (most recent ' + d.shown + ')';
      if (d.malformed) note += '; ' + d.malformed + ' unreadable line' + (d.malformed === 1 ? '' : 's') + ' skipped';
      h += '<p style="font-size:0.8rem;color:var(--mg-text-light);margin-top:0.4rem">' + esc(note) + '</p>';
      setSubsBody(h, 'Submissions: ' + formName);
    })
    .catch(function() { setSubsBody('<p style="color:var(--mg-danger,#c00)">Could not read submissions.</p>', 'Submissions'); });
}

// SM216: confirm a quarantined row as legitimate (clears the flag; the message
// stays in the store, just no longer flagged). Reloads the table in place.
function confirmSubmissionRow(filePath, rowId, formName) {
  fetch(API + '?action=form-submission-confirm', {
    method: 'POST', credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ file: filePath, id: rowId })
  }).then(function(r) { return r.json(); }).then(function(d) {
    if (!d.ok) { showStatus(d.error || 'Confirm failed', true); return; }
    showStatus('Submission confirmed - moved out of quarantine.');
    showSubmissionTable(filePath, formName);
  }).catch(function(e) { showStatus('Confirm error: ' + e.message, true); });
}

function deleteSubmissionRow(filePath, rowId, formName) {
  var go = function(ok) {
    if (!ok) return;
    fetch(API + '?action=form-submission-delete', {
      method: 'POST', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ file: filePath, id: rowId })
    }).then(function(r) { return r.json(); }).then(function(d) {
      if (!d.ok) { showStatus(d.error || 'Delete failed', true); return; }
      showSubmissionTable(filePath, formName);   // reload the table in place
    }).catch(function(e) { showStatus('Delete error: ' + e.message, true); });
  };
  var msg = 'Delete this submission? It is permanently removed from "' + formName + '".';
  if (typeof mgConfirm === 'function') { mgConfirm(msg, { danger: true, ok: 'Delete' }).then(go); }
  else { go(window.confirm(msg)); }
}

// SM187: select-all toggle for the row checkboxes.
function subsToggleAll(master) {
  var boxes = document.querySelectorAll('.mg-sub-cb');
  for (var i = 0; i < boxes.length; i++) { boxes[i].checked = master.checked; }
}

// SM187: delete every checked row in one atomic server-side rewrite.
function bulkDeleteSubmissions() {
  if (!subsLoaded) return;
  var ids = [];
  var boxes = document.querySelectorAll('.mg-sub-cb');
  for (var i = 0; i < boxes.length; i++) { if (boxes[i].checked) ids.push(boxes[i].value); }
  if (!ids.length) { showStatus('No rows selected.', true); return; }
  var filePath = subsLoaded.file, formName = subsLoaded.form;
  var go = function(ok) {
    if (!ok) return;
    fetch(API + '?action=form-submissions-delete-bulk', {
      method: 'POST', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ file: filePath, ids: ids })
    }).then(function(r) { return r.json(); }).then(function(d) {
      if (!d.ok) { showStatus(d.error || 'Bulk delete failed', true); return; }
      showStatus(d.deleted + ' submission' + (d.deleted === 1 ? '' : 's') + ' deleted.');
      showSubmissionTable(filePath, formName);   // reload in place
    }).catch(function(e) { showStatus('Bulk delete error: ' + e.message, true); });
  };
  var msg = 'Delete ' + ids.length + ' selected submission' + (ids.length === 1 ? '' : 's')
          + '? They are permanently removed from "' + formName + '".';
  if (typeof mgConfirm === 'function') { mgConfirm(msg, { danger: true, ok: 'Delete' }).then(go); }
  else { go(window.confirm(msg)); }
}

// SM187: download the loaded store as a CSV, built client-side from the rows
// already in hand (no new server surface). Columns are the visible fields plus
// the quarantine status/reason; every cell is RFC-4180 quoted.
function downloadSubmissionsCsv() {
  if (!subsLoaded || !subsLoaded.rows.length) { showStatus('Nothing to export.', true); return; }
  var cols = subsLoaded.cols.concat(['quarantined', 'spam_reason']);
  var q = function(v) { return '"' + String(v == null ? '' : v).replace(/"/g, '""') + '"'; };
  var lines = [cols.map(q).join(',')];
  subsLoaded.rows.forEach(function(row) {
    lines.push(cols.map(function(c) {
      if (c === 'quarantined') return q(row._quarantined ? 'yes' : '');
      if (c === 'spam_reason') return q(row._spam_reason || '');
      return q(row[c]);
    }).join(','));
  });
  var blob = new Blob([lines.join('\r\n') + '\r\n'], { type: 'text/csv;charset=utf-8' });
  var url = URL.createObjectURL(blob);
  var a = document.createElement('a');
  a.href = url;
  a.download = (subsLoaded.form || 'submissions').replace(/[^A-Za-z0-9_-]/g, '_') + '-submissions.csv';
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  setTimeout(function() { URL.revokeObjectURL(url); }, 1000);
}

// The submissions modal shell: a fixed overlay with a scrollable body.
function openSubsModal() {
  if (document.getElementById('subs-modal')) return;
  var ov = document.createElement('div');
  ov.id = 'subs-modal';
  ov.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,0.5);z-index:1000;display:flex;align-items:center;justify-content:center;';
  ov.innerHTML =
      '<div style="background:var(--mg-bg,#fff);color:var(--mg-text,inherit);width:92%;max-width:1000px;max-height:86vh;border-radius:8px;display:flex;flex-direction:column;overflow:hidden;">'
    + '<div style="display:flex;align-items:center;gap:8px;padding:10px 14px;border-bottom:1px solid var(--mg-border,#ddd);">'
    + '<strong id="subs-modal-title" style="flex:1">Submissions</strong>'
    + '<span id="subs-modal-forms"></span>'
    + '<button class="mg-btn mg-btn-sm" onclick="closeSubsModal()">Close</button></div>'
    + '<div id="subs-modal-body" style="flex:1;overflow:auto;padding:12px 14px;"></div></div>';
  ov.addEventListener('click', function(e) { if (e.target === ov) closeSubsModal(); });
  document.body.appendChild(ov);
}
function closeSubsModal() {
  var ov = document.getElementById('subs-modal');
  if (ov && ov.parentNode) ov.parentNode.removeChild(ov);
}
function setSubsBody(html, title) {
  var b = document.getElementById('subs-modal-body');
  var t = document.getElementById('subs-modal-title');
  if (t && title) t.textContent = title;
  if (b) b.innerHTML = html;
}

// --- Wizard: add handler ---

function showAddHandlerForm(type) {
  hideAddWizard();

  var wizard = document.getElementById('add-handler-wizard-' + type);
  if (!wizard) return;

  // Move wizard inside the relevant group

  // Skip step 1 - go directly to step 2 for the given type
  var name = nameForType(type);
  var html = '<div class="mg-wizard">';
  html += '<div class="mg-wizard-title">Add handler</div>';
  html += renderStep2Form(type, name, null, false);
  html += '<div id="wizard-status"></div>';
  html += '</div>';

  wizard.innerHTML = html;
  wizard.style.display = 'block';
  applyShowWhen(wizard);
}

function nameForType(type) {
  return { smtp: 'Email delivery', file: 'Local storage', webhook: 'Webhook' }[type] || 'New handler';
}

function typeLabelFor(type) {
  return { smtp: 'Send email (SMTP)', file: 'Save to file', webhook: 'Webhook' }[type] || type;
}

function hideAddWizard() {
  // Every slot, because there is one per group now and any of them may be open.
  var slots = document.querySelectorAll('.mg-handler-wizard');
  for (var i = 0; i < slots.length; i++) {
    slots[i].innerHTML = '';
    slots[i].style.display = 'none';
  }
  // Closing the wizard - by Cancel or after a successful save - discards it.
  clearHandlerDirty('new');
}

// --- Step 2 form (shared by add and edit) ---

function renderStep2Form(type, name, existingData, isEdit) {
  var d = existingData || {};
  // Dirty key per form instance: the add wizard is 'new', an edit form is the
  // handler id - so several open forms track (and clear) independently.
  var fid = isEdit ? d.id : 'new';
  var html = '<div oninput="markHandlerDirty(\'' + esc(fid) + '\')" onchange="markHandlerDirty(\'' + esc(fid) + '\')">';

  if (isEdit) {
    html += '<div class="mg-field">';
    html += '<label>ID</label>';
    html += '<span class="mg-readonly-value">' + esc(d.id || '') + '</span>';
    html += '</div>';
    html += '<div class="mg-field">';
    html += '<label>Type</label>';
    html += '<span class="mg-readonly-value">' + esc(typeLabelFor(type)) + '</span>';
    html += '</div>';
  }

  html += '<div class="mg-sec">Handler settings</div>';
  html += '<div class="mg-field">';
  html += '<label>Name</label>';
  html += '<input type="text" id="wiz-name" value="' + esc(d.name || name) + '" required>';
  html += '</div>';
  html += '<div class="mg-field">';
  html += '<label>Enabled</label>';
  html += '<input type="checkbox" id="wiz-enabled"' + (d.enabled !== 'false' ? ' checked' : '') + '>';
  html += '</div>';

  if (type === 'smtp') html += renderSmtpFields(d);
  else if (type === 'file') html += renderFileFields(d);
  else if (type === 'webhook') html += renderWebhookFields(d);

  html += '<div class="mg-wizard-actions">';
  if (isEdit) {
    html += '<button type="button" class="mg-btn" onclick="saveHandlerFromWizard(\'' + esc(d.id) + '\',\'' + type + '\',true)">Save</button>';
    html += '<button type="button" class="mg-btn" onclick="cancelHandlerEdit(\'' + esc(d.id) + '\')">Cancel</button>';
  } else {
    html += '<button type="button" class="mg-btn" onclick="saveHandlerFromWizard(null,\'' + type + '\',false)">Add handler</button>';
    html += '<button type="button" class="mg-btn" onclick="hideAddWizard()">Cancel</button>';
  }
  html += ' <span id="handler-dirty-' + esc(fid) + '" class="mg-note mg-note-info" style="display:none">&#9679; Unsaved changes</span>';
  html += '</div>';
  html += '</div>';

  return html;
}

function renderSmtpFields(d) {
  var sv = smtpConnectionValues || {};
  var html = '';

  html += '<div class="mg-sec">Email settings</div>';
  html += '<div class="mg-field"><label>From address</label>';
  html += '<input type="email" id="wiz-from" value="' + esc(d.from || 'webforms@example.com') + '" required>';
  html += '</div>';
  html += '<div class="mg-field"><label>To address</label>';
  html += '<input type="email" id="wiz-to" value="' + esc(d.to || 'admin@example.com') + '" required>';
  html += '</div>';
  html += '<div class="mg-field"><label>Subject prefix</label>';
  html += '<input type="text" id="wiz-subject_prefix" value="' + esc(d.subject_prefix !== undefined ? d.subject_prefix : '[Contact] ') + '">';
  html += '</div>';

  if (!smtpPlugin) return html;

  html += '<div class="mg-sec">SMTP connection</div>';

  var method = sv.method || 'sendmail';
  html += '<div class="mg-field"><label>Send method</label>';
  html += '<select id="wiz-method" onchange="applyShowWhen(this.closest(\'.mg-wizard\')||this.closest(\'.mg-handler-edit-form\'))">';
  ['sendmail', 'smtp'].forEach(function(o) {
    html += '<option' + (method === o ? ' selected' : '') + '>' + o + '</option>';
  });
  html += '</select></div>';

  html += '<div class="mg-field mg-config-field" data-show-key="wiz-method" data-show-val="sendmail">';
  html += '<label>Sendmail path</label>';
  html += '<input type="text" id="wiz-sendmail_path" value="' + esc(sv.sendmail_path || '/usr/sbin/sendmail') + '">';
  html += '</div>';

  html += '<div class="mg-field mg-config-field" data-show-key="wiz-method" data-show-val="smtp">';
  html += '<label>Host</label>';
  html += '<input type="text" id="wiz-host" value="' + esc(sv.host || 'localhost') + '">';
  html += '</div>';

  html += '<div class="mg-field mg-config-field" data-show-key="wiz-method" data-show-val="smtp">';
  html += '<label>Port</label>';
  html += '<input type="number" id="wiz-port" value="' + esc(sv.port || '587') + '" min="1" max="65535">';
  html += '</div>';

  html += '<div class="mg-field mg-config-field" data-show-key="wiz-method" data-show-val="smtp">';
  html += '<label>TLS</label>';
  html += '<select id="wiz-tls">';
  var tlsVal = sv.tls || 'false';
  ['false', 'starttls', 'true'].forEach(function(o) {
    html += '<option' + (tlsVal === o ? ' selected' : '') + '>' + o + '</option>';
  });
  html += '</select></div>';

  var authVal = sv.auth === 'true' || sv.auth === '1';
  html += '<div class="mg-field mg-config-field" data-show-key="wiz-method" data-show-val="smtp">';
  html += '<label>Authentication</label>';
  html += '<input type="checkbox" id="wiz-auth"' + (authVal ? ' checked' : '') + ' onchange="applyShowWhen(this.closest(\'.mg-wizard\')||this.closest(\'.mg-handler-edit-form\'))">';
  html += '</div>';

  // Auth fields: nested inside a smtp-only wrapper so they hide when method != smtp
  html += '<div class="mg-config-field" data-show-key="wiz-method" data-show-val="smtp">';
  html += '<div class="mg-field mg-config-field" data-show-key="wiz-auth" data-show-val="true,1">';
  html += '<label>Username</label>';
  html += '<input type="text" id="wiz-username" value="' + esc(sv.username || '') + '">';
  html += '</div>';
  html += '<div class="mg-field mg-config-field" data-show-key="wiz-auth" data-show-val="true,1">';
  html += '<label>Password</label>';
  html += '<input type="password" id="wiz-password" placeholder="leave blank to keep current" autocomplete="new-password">';
  html += '</div>';
  html += '<div class="mg-field mg-config-field" data-show-key="wiz-auth" data-show-val="true,1">';
  html += '<label>Password file (optional alternative)</label>';
  html += '<input type="text" id="wiz-password_file" value="' + esc(sv.password_file || '') + '" placeholder="e.g. lazysite/forms/.smtp-password">';
  html += '</div>';
  html += '</div>';

  // SM137: staged connection check (host/port/TLS/auth). Runs against the SAVED
  // smtp.conf, so save first; the note says so.
  html += '<div class="mg-field"><label>Connection</label><div>';
  html += '<button type="button" class="mg-btn mg-btn-sm" onclick="validateSmtp(this)">Validate SMTP connection</button>';
  html += ' <span class="mg-muted" style="font-size:0.8rem">checks the saved settings - save changes first</span>';
  html += '<div class="smtp-validate-result" style="margin-top:4px;font-size:0.85rem"></div>';
  html += '</div></div>';

  return html;
}

// SM137: run the form-smtp validate action and show the staged verdict inline.
function validateSmtp(btn) {
  var out = btn.parentNode.querySelector('.smtp-validate-result');
  var p = (window._plugins || []).find(function(x) { return x.id === 'form-smtp'; });
  if (!p) { if (out) out.textContent = 'The Form SMTP plugin is not available.'; return; }
  btn.disabled = true;
  if (out) { out.textContent = 'Checking host, port, TLS, auth…'; out.style.color = ''; }
  fetch(API + '?action=plugin-action&plugin=form-smtp', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ script: p._script, action_id: 'validate' })
  })
  .then(function(r) { return r.json(); })
  .then(function(d) {
    btn.disabled = false;
    if (!out) return;
    if (d && d.ok) { out.style.color = 'var(--mg-ok,#1a7f37)'; out.textContent = d.message || 'OK.'; }
    else { out.style.color = 'var(--mg-danger,#b03a3a)'; out.textContent = (d && d.error) || 'Validation failed.'; }
  })
  .catch(function(e) { btn.disabled = false; if (out) { out.style.color = 'var(--mg-danger,#b03a3a)'; out.textContent = 'Error: ' + e.message; } });
}

function renderFileFields(d) {
  var html = '<div class="mg-sec">File settings</div>';
  html += '<div class="mg-field"><label>Directory</label>';
  html += '<input type="text" id="wiz-path" value="' + esc(d.path || 'lazysite/forms/submissions') + '" required>';
  html += '</div>';
  // Only show the "View submissions" row on edit (not add): the handler
  // needs an id before we can probe. d.id is present on edit, absent on
  // the add wizard. checkSubmissionsDir() will populate the slot.
  if (d.id) {
    html += '<div class="mg-field"><label>Submissions</label>';
    html += '<div data-submissions-for="' + esc(d.id) + '">';
    html += '<span style="font-size:0.8rem;color:var(--mg-text-light)">Checking...</span>';
    html += '</div></div>';
  }
  return html;
}

function renderWebhookFields(d) {
  var html = '<div class="mg-sec">Webhook settings</div>';
  html += '<div class="mg-field"><label>URL</label>';
  html += '<input type="url" id="wiz-url" value="' + esc(d.url || '') + '" required placeholder="https://">';
  html += '</div>';
  html += '<div class="mg-field"><label>Format</label>';
  html += '<select id="wiz-format">';
  var fmt = d.format || 'json';
  ['json', 'slack'].forEach(function(o) {
    html += '<option' + (fmt === o ? ' selected' : '') + '>' + o + '</option>';
  });
  html += '</select></div>';
  return html;
}

// --- Save handler (add or edit) ---

function saveHandlerFromWizard(existingId, type, isEdit) {
  var handlerData = {
    type: type,
    name: val('wiz-name'),
    enabled: (document.getElementById('wiz-enabled') || {}).checked ? 'true' : 'false'
  };

  if (!handlerData.name) { mgShowWarning('Name is required', true); return; }

  handlerData.id = existingId || slugify(handlerData.name);
  if (!existingId && allHandlers.some(function(h) { return h.id === handlerData.id; })) {
    handlerData.id = handlerData.id + '-' + Date.now().toString().slice(-4);
  }

  var smtpConnData = null;

  if (type === 'smtp') {
    handlerData.from = val('wiz-from');
    handlerData.to = val('wiz-to');
    handlerData.subject_prefix = val('wiz-subject_prefix');
    if (!handlerData.from || !handlerData.to) {
      mgShowWarning('From and To addresses are required', true);
      return;
    }
    if (smtpPlugin) {
      smtpConnData = {
        method: val('wiz-method'),
        sendmail_path: val('wiz-sendmail_path'),
        host: val('wiz-host'),
        port: val('wiz-port'),
        tls: val('wiz-tls'),
        auth: (document.getElementById('wiz-auth') || {}).checked ? 'true' : 'false',
        username: val('wiz-username'),
        password_file: val('wiz-password_file')
      };
      // Password: only send when typed - plugin-save merges per key, so leaving
      // it blank keeps the stored one (never echoed back).
      if (val('wiz-password')) smtpConnData.password = val('wiz-password');
    }
  } else if (type === 'file') {
    handlerData.path = val('wiz-path');
    if (!handlerData.path) { mgShowWarning('Directory path is required', true); return; }
  } else if (type === 'webhook') {
    handlerData.url = val('wiz-url');
    handlerData.format = val('wiz-format');
    if (!handlerData.url) { mgShowWarning('URL is required', true); return; }
  }

  var statusId = isEdit ? 'handler-edit-status-' + existingId : 'wizard-status';
  var statusEl = document.getElementById(statusId);
  if (statusEl) statusEl.textContent = 'Saving...';

  fetch(API + '?action=handler-save', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(handlerData)
  })
  .then(function(r) { return r.json(); })
  .then(function(res) {
    if (!res.ok) throw new Error(res.error || 'Handler save failed');
    if (smtpConnData && smtpPlugin) {
      return fetch(API + '?action=plugin-save&plugin=form-smtp', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ script: smtpPlugin._script, values: smtpConnData })
      }).then(function(r) { return r.json(); });
    }
    return { ok: true };
  })
  .then(function(res) {
    if (!res.ok) throw new Error(res.error || 'SMTP config save failed');
    smtpConnectionLoaded = false;
    if (isEdit) cancelHandlerEdit(existingId);
    else hideAddWizard();
    loadHandlers();
  })
  .catch(function(err) {
    mgShowWarning('Error: ' + err.message, true);
    if (statusEl) statusEl.textContent = '';
  });
}

function slugify(str) {
  return str.toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '')
    .substring(0, 40);
}

// --- Edit handler ---

function editHandler(handler) {
  var div = document.getElementById('handler-edit-' + handler.id);
  if (!div) return;

  if (div.style.display !== 'none') { cancelHandlerEdit(handler.id); return; }

  if (handler.type === 'smtp' && !smtpConnectionLoaded && smtpPlugin) {
    div.textContent = 'Loading...';
    div.style.display = 'block';
    fetch(API + '?action=plugin-read&plugin=form-smtp', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ script: smtpPlugin._script })
    })
    .then(function(r) { return r.json(); })
    .then(function(data) {
      smtpConnectionValues = data.values || {};
      smtpConnectionLoaded = true;
      div.innerHTML = renderStep2Form(handler.type, handler.name, handler, true)
        + '<div id="handler-edit-status-' + handler.id + '"></div>';
      applyShowWhen(div);
    });
  } else {
    div.innerHTML = renderStep2Form(handler.type, handler.name, handler, true)
      + '<div id="handler-edit-status-' + handler.id + '"></div>';
    div.style.display = 'block';
    applyShowWhen(div);
    // Re-probe so the new edit-form slot gets populated; the collapsed
    // slot updates at the same time because both carry the same
    // data-submissions-for attribute.
    if (handler.type === 'file') checkSubmissionsDir(handler);
  }
}

function cancelHandlerEdit(id) {
  var div = document.getElementById('handler-edit-' + id);
  if (div) { div.innerHTML = ''; div.style.display = 'none'; }
  // Closing the edit form - by Cancel or after a successful save - discards it.
  clearHandlerDirty(id);
}

// --- Handler delete and refresh ---

function deleteHandler(handlerId) {
  mgConfirm('Delete handler "' + handlerId + '"?', { danger: true, ok: 'Delete' }).then(function(__ok) {
    if (!__ok) return;
    fetch(API + '?action=handler-delete', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id: handlerId })
  })
  .then(function(r) { return r.json(); })
  .then(function(res) {
    if (res.ok) { mgClearWarning(); loadHandlers(); }
    else { mgShowWarning(res.error || 'Delete failed', true); }
  });
  });
}

function loadHandlers() {
  fetch(API + '?action=handler-list&_t=' + Date.now())
    .then(function(r) { return r.json(); })
    .then(function(data) {
      allHandlers = (data.ok ? data.handlers : []) || [];
      renderHandlerList();
      refreshOpenTargets();
    });
}

function refreshOpenTargets() {
  var cards = document.querySelectorAll('[id^="form-targets-"]');
  for (var i = 0; i < cards.length; i++) {
    var div = cards[i];
    if (div.style.display !== 'none' && div._targets) {
      var formName = div.id.replace('form-targets-', '');
      renderFormTargets(formName, div._targets);
    }
  }
}

// --- Form targets ---

function toggleFormTargets(formName) {
  var div = document.getElementById('form-targets-' + formName);
  if (div.style.display !== 'none') { div.style.display = 'none'; return; }
  div.textContent = 'Loading...';
  div.style.display = 'block';

  fetch(API + '?action=form-targets-read&form=' + encodeURIComponent(formName))
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) { div.textContent = data.error; return; }
      var targets = (data.targets || []).map(function(t) { return t.handler || ''; });
      div._targets = targets;
      renderFormTargets(formName, targets);
    });
}

function renderFormTargets(formName, currentTargets) {
  var div = document.getElementById('form-targets-' + formName);
  if (!div) return;

  var html = '<div style="margin-bottom:0.5rem">';

  currentTargets.forEach(function(hid, idx) {
    var usedByOthers = [];
    currentTargets.forEach(function(id, i) {
      if (i !== idx && id) usedByOthers.push(id);
    });

    html += '<div class="mg-field" style="margin-bottom:0.25rem">';
    html += '<label>Target ' + (idx + 1) + '</label>';
    html += '<select data-form="' + esc(formName) + '" data-idx="' + idx + '" onchange="updateFormTarget(this)">';
    html += '<option value="">-- select handler --</option>';
    allHandlers.forEach(function(h) {
      if (usedByOthers.indexOf(h.id) >= 0 && h.id !== hid) return;
      var typeLabel = {smtp:'email', file:'file', webhook:'webhook'}[h.type] || h.type;
      var label = (h.name || h.id) + ' (' + typeLabel + ')';
      html += '<option value="' + esc(h.id) + '"' + (h.id === hid ? ' selected' : '') + '>' + esc(label) + '</option>';
    });
    html += '</select>';
    html += '<button class="mg-btn mg-btn-sm" data-impact="edit" onclick="deleteTarget(\'' + esc(formName) + '\',' + idx + ')">&times;</button>';
    html += '</div>';
  });

  html += '</div>';
  html += '<div class="mg-wizard-actions">';
  html += '<button class="mg-btn mg-btn-sm mg-btn" onclick="addTarget(\'' + esc(formName) + '\')">+ Add target</button>';
  html += '<button class="mg-btn mg-btn-sm mg-btn-primary" onclick="saveFormTargets(\'' + esc(formName) + '\')">Save</button>';
  // Re-rendered on every mutation, so seed the note from the guard's state.
  var dirtyNow = mgDirtyGuard.isDirty('targets-' + formName);
  html += ' <span id="targets-dirty-' + esc(formName) + '" class="mg-note mg-note-info"'
       +  (dirtyNow ? '' : ' style="display:none"') + '>&#9679; Unsaved changes &mdash; click Save</span>';
  html += '</div>';

  div.innerHTML = html;
}

function updateFormTarget(el) {
  var formName = el.dataset.form;
  var idx = parseInt(el.dataset.idx, 10);
  var div = document.getElementById('form-targets-' + formName);
  if (!div || !div._targets) return;
  div._targets[idx] = el.value;
  markTargetsDirty(formName);
  renderFormTargets(formName, div._targets);
}

function addTarget(formName) {
  var div = document.getElementById('form-targets-' + formName);
  if (!div._targets) div._targets = [];
  var usedIds = div._targets.filter(function(id) { return id; });
  var available = allHandlers.filter(function(h) { return usedIds.indexOf(h.id) < 0; });
  if (available.length === 0) {
    var msg = div.querySelector('.all-assigned-msg');
    if (!msg) {
      msg = document.createElement('div');
      msg.className = 'all-assigned-msg';
      msg.style.cssText = 'font-size:0.8rem;color:#6c757d;margin-top:0.25rem;';
      msg.textContent = 'All handlers assigned.';
      div.appendChild(msg);
      setTimeout(function() { if (msg.parentNode) msg.remove(); }, 3000);
    }
    return;
  }
  div._targets.push('');
  markTargetsDirty(formName);
  renderFormTargets(formName, div._targets);
}

function deleteTarget(formName, idx) {
  var div = document.getElementById('form-targets-' + formName);
  if (!div || !div._targets) return;
  div._targets.splice(idx, 1);
  markTargetsDirty(formName);
  renderFormTargets(formName, div._targets);
}

function saveFormTargets(formName) {
  var div = document.getElementById('form-targets-' + formName);
  var targets = (div._targets || []).filter(function(id) { return id; }).map(function(id) { return { handler: id }; });
  var status = document.getElementById('status-form-connections');

  fetch(API + '?action=form-targets-save&form=' + encodeURIComponent(formName), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ targets: targets })
  })
  .then(function(r) { return r.json(); })
  .then(function(data) {
    if (data.ok) {
      mgClearWarning();
      clearTargetsDirty(formName);
      if (status) { status.textContent = 'Targets saved.'; setTimeout(function() { status.textContent = ''; }, 3000); }
    } else {
      mgShowWarning(data.error || 'Save failed', true);
      if (status) status.textContent = '';
    }
  })
  .catch(function(e) {
    mgShowWarning('Error: ' + e.message, true);
  });
}

loadPlugins();
</script>
