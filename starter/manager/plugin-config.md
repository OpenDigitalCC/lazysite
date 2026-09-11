---
title: Extension Config
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

function esc(s) { return (s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;'); }
function val(id) { var el = document.getElementById(id); return el ? el.value : ''; }

// SM118 pattern (field report): every explicit-save surface on this page - the
// per-plugin config forms - flags unsaved changes via the shared mgDirtyGuard
// (manager layout). Each surface gets its own key so saving or cancelling one
// never un-flags another. SM842: the handler and form-target forms moved to
// the Handlers page, which carries its own.
function markPluginDirty(id)   { mgDirtyGuard.set('plugin-' + id, 'dirty-' + id); }
function clearPluginDirty(id)  { mgDirtyGuard.clear('plugin-' + id); }

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
    + '<button type="button" class="mg-sheet-close" onclick="mgPluginModalClose()" aria-label="Close">&times;</button></div>'
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

function loadPlugins() {
  document.getElementById('plugin-list').textContent = 'Scanning...';
  fetch(API + '?action=extension-list')
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) {
        document.getElementById('plugin-list').textContent = data.error || 'Failed to load extensions';
        return;
      }
      window._plugins = data.plugins || [];
      renderPlugins(data.plugins || []);
      openRequestedSubmissions();
    });
}

function renderPlugins(plugins) {
  var enabled = (plugins || []).filter(function(p) { return p._enabled; });

  if (!enabled.length) {
    document.getElementById('plugin-list').innerHTML =
      '<p class="mg-empty">No extensions enabled. Visit <a href="/manager/config">Configuration</a> to enable extensions.</p>';
    return;
  }

  var html = '';
  enabled.forEach(function(p) { html += renderPluginCard(p); });
  document.getElementById('plugin-list').innerHTML = html;
}

// SM842: the Handlers page links a file handler's store here, to the
// submissions viewer, as ?submissions=<store directory>.
function openRequestedSubmissions() {
  var m = /[?&]submissions=([^&]+)/.exec(window.location.search);
  if (!m) return;
  var dir = decodeURIComponent(m[1]);
  if (!/^\/[A-Za-z0-9_\/.-]*\/$/.test(dir) || /\.\./.test(dir)) return;
  toggleSubmissions('', dir);
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
  // SM842: the form handler's configuration is the Handlers page; its row
  // keeps the two things that are about what ARRIVED rather than where it goes.
  if (plugin.id === 'form-handler') {
    html += '<a class="mg-btn mg-btn-sm" href="/manager/handlers">Handlers</a>';
    html += '<button class="mg-btn mg-btn-sm" data-impact="inert" onclick="toggleSubmissions(\'\', \'/lazysite/forms/submissions/\')">Submissions</button>';
  }
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
  fetch(API + '?action=extension-read&plugin=' + encodeURIComponent(plugin.id), {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ script: plugin._script })
  })
  .then(function(r) { return window.mgJson ? window.mgJson(r) : r.json(); })
  .then(function(data) {
    // The modal may have been closed while the request was in flight; writing
    // into a detached node would silently do nothing, so check it is still ours.
    var b = document.getElementById('plugin-modal-body');
    if (!b) return;
    if (!data.ok) { b.textContent = data.error || 'Could not read this extension\'s configuration'; return; }
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
  fetch(API + '?action=extension-save&plugin=' + encodeURIComponent(pluginId), {
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
  fetch(API + '?action=extension-read&plugin=' + encodeURIComponent(pluginId), {
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
  fetch(API + '?action=extension-action&plugin=' + encodeURIComponent(plugin.id), {
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

// --- SM182/SM187: submissions viewer (scrollable modal + per-row delete) -----
// The raw .jsonl store lives in the reserved lazysite/ tree, so it can't be
// opened in the file editor. Show it in a scrollable MODAL table instead. A
// handled row can be deleted by its stable _id (server rewrites the store).
//
// SM793: EVERY VALUE ARRIVES AS TEXT. The table is built from DOM nodes and
// textContent, and each button's action is a closure rather than an attribute,
// so a stored value never passes through HTML at all - there is no escape to
// forget, and no quoting of an attribute to get wrong. The server returns the
// submission as it was sent, which is what the control API and MCP read too.

function subsNode(tag, cls, text) {
  var n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = String(text);
  return n;
}
function subsMessage(text) { return subsNode('p', 'mg-muted', text); }

function toggleSubmissions(handlerId, dirPath) {
  openSubsModal();
  setSubsBody(subsMessage('Loading submissions\u2026'), 'Submissions');
  fetch(API + '?action=list&path=' + encodeURIComponent(dirPath))
    .then(function(r) { return r.json(); })
    .then(function(data) {
      var files = (data.ok && data.entries ? data.entries : []).filter(function(f) {
        return f.type === 'file' && /\.jsonl$/.test(f.name || '');
      });
      if (!files.length) { setSubsBody(subsMessage('No submissions yet.'), 'Submissions'); return; }
      // A form selector in the modal header when the store holds more than one.
      var fsel = document.getElementById('subs-modal-forms');
      if (files.length > 1 && fsel) {
        var sel = document.createElement('select');
        sel.setAttribute('aria-label', 'Form');
        files.forEach(function(f) {
          var opt = subsNode('option', null, (f.name || '').replace(/\.jsonl$/, ''));
          opt.value = f.path;
          sel.appendChild(opt);
        });
        sel.addEventListener('change', function() { showSubmissionTable(sel.value, sel.options[sel.selectedIndex].text); });
        fsel.textContent = '';
        fsel.appendChild(sel);
      }
      showSubmissionTable(files[0].path, (files[0].name || '').replace(/\.jsonl$/, ''));
    })
    .catch(function() { setSubsBody(subsMessage('Could not list submissions.'), 'Submissions'); });
}

// SM216: a quarantine filter, kept per-open so a reload keeps the view.
var subsFilter  = 'all';   // 'all' | 'quarantined'
var subsCurrent = null;
var subsLoaded  = null;    // SM187: last-loaded {file,form,cols,rows} for CSV/bulk
function setSubsFilter(f) { subsFilter = f; if (subsCurrent) showSubmissionTable(subsCurrent.file, subsCurrent.form); }

function showSubmissionTable(filePath, formName) {
  subsCurrent = { file: filePath, form: formName };
  setSubsBody(subsMessage('Loading ' + formName + '\u2026'), 'Submissions: ' + formName);
  fetch(API + '?action=form-submissions&file=' + encodeURIComponent(filePath))
    .then(function(r) { return r.json(); })
    .then(function(d) {
      if (!d.ok) { setSubsBody(subsMessage(d.error || 'Could not read submissions'), 'Submissions'); return; }
      // SM216: _quarantined / _spam_reason are status meta, not form fields - drive
      // the row marking, not a data column.
      var META = { _quarantined: 1, _spam_reason: 1 };
      var cols = (d.columns || []).filter(function(c) { return !META[c]; });
      var rows = d.rows || [];
      if (!rows.length || !cols.length) {
        setSubsBody(subsMessage('No submissions in ' + formName + ' yet.'), 'Submissions: ' + formName);
        return;
      }
      var qcount = rows.filter(function(r) { return r._quarantined; }).length;
      var view = (subsFilter === 'quarantined') ? rows.filter(function(r) { return r._quarantined; }) : rows;
      subsLoaded = { file: filePath, form: formName, cols: cols, rows: rows };   // SM187

      var frag = document.createDocumentFragment();

      // SM187: a toolbar - quarantine filter (if any), CSV export and bulk delete
      // of the checked rows. SM847: toolbar buttons are the standard size.
      var bar = subsNode('div', 'mg-toolbar');
      var button = function(label, cls, onclick, disabled) {
        var b = subsNode('button', 'mg-btn' + (cls ? ' ' + cls : ''), label);
        b.type = 'button';
        b.disabled = !!disabled;
        b.addEventListener('click', onclick);
        return b;
      };
      if (qcount) {
        var qn = subsNode('span');
        qn.appendChild(subsNode('strong', null, qcount));
        qn.appendChild(document.createTextNode(' quarantined (suspected spam, kept out of notifications).'));
        bar.appendChild(qn);
        bar.appendChild(button('All', null, function() { setSubsFilter('all'); }, subsFilter === 'all'));
        bar.appendChild(button('Quarantine only', null, function() { setSubsFilter('quarantined'); }, subsFilter === 'quarantined'));
      }
      bar.appendChild(button('Download CSV', null, downloadSubmissionsCsv));
      bar.appendChild(button('Delete selected', 'mg-btn-danger', bulkDeleteSubmissions));
      frag.appendChild(bar);

      var wrap  = subsNode('div', 'mg-table-wrap');
      var table = subsNode('table', 'mg-table mg-submissions-table');
      var head  = document.createElement('tr');
      var th0   = document.createElement('th');
      var all   = document.createElement('input');
      all.type = 'checkbox'; all.title = 'Select all';
      all.addEventListener('click', function() { subsToggleAll(all); });
      th0.appendChild(all);
      head.appendChild(th0);
      head.appendChild(subsNode('th', null, 'Status'));
      cols.forEach(function(c) { head.appendChild(subsNode('th', null, c)); });
      head.appendChild(subsNode('th'));
      var thead = document.createElement('thead');
      thead.appendChild(head);
      table.appendChild(thead);

      var tbody = document.createElement('tbody');
      view.forEach(function(row) {
        var tr = document.createElement('tr');
        var cbCell = document.createElement('td');
        var cb = document.createElement('input');
        cb.type = 'checkbox'; cb.className = 'mg-sub-cb'; cb.value = String(row._id);
        cbCell.appendChild(cb);
        tr.appendChild(cbCell);
        var st = document.createElement('td');
        if (row._quarantined) {
          var tag = subsNode('span', 'mg-tag mg-tag-off', 'quarantined');
          tag.title = String(row._spam_reason || '');
          st.appendChild(tag);
        }
        tr.appendChild(st);
        cols.forEach(function(c) { tr.appendChild(subsNode('td', null, row[c] == null ? '' : row[c])); });
        var act = subsNode('td', 'mg-cell-actions');
        if (row._quarantined) {
          act.appendChild(button('Confirm', 'mg-btn-sm', function() { confirmSubmissionRow(filePath, row._id, formName); }));
        }
        act.appendChild(button('Delete', 'mg-btn-sm mg-btn-danger', function() { deleteSubmissionRow(filePath, row._id, formName); }));
        tr.appendChild(act);
        tbody.appendChild(tr);
      });
      table.appendChild(tbody);
      wrap.appendChild(table);
      frag.appendChild(wrap);

      var note = 'Showing ' + d.shown + ' of ' + d.total + ' submission' + (d.total === 1 ? '' : 's');
      if (d.truncated) note += ' (most recent ' + d.shown + ')';
      if (d.malformed) note += '; ' + d.malformed + ' unreadable line' + (d.malformed === 1 ? '' : 's') + ' skipped';
      frag.appendChild(subsMessage(note));
      setSubsBody(frag, 'Submissions: ' + formName);
    })
    .catch(function() { setSubsBody(subsMessage('Could not read submissions.'), 'Submissions'); });
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
    + '<button type="button" class="mg-sheet-close" onclick="closeSubsModal()" aria-label="Close">&times;</button></div>'
    + '<div id="subs-modal-body" style="flex:1;overflow:auto;padding:12px 14px;"></div></div>';
  ov.addEventListener('click', function(e) { if (e.target === ov) closeSubsModal(); });
  document.body.appendChild(ov);
}
function closeSubsModal() {
  var ov = document.getElementById('subs-modal');
  if (ov && ov.parentNode) ov.parentNode.removeChild(ov);
}
// SM793: a NODE, never a string of HTML - see the note above the viewer.
function setSubsBody(node, title) {
  var b = document.getElementById('subs-modal-body');
  var t = document.getElementById('subs-modal-title');
  if (t && title) t.textContent = title;
  if (b) { b.textContent = ''; b.appendChild(node); }
}

loadPlugins();
</script>
