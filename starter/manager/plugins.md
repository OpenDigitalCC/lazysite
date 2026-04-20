---
title: Plugins
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

function renderPluginCard(plugin) {
  var html = '<div class="mg-plugin-card" id="plugin-' + esc(plugin.id) + '">';
  html += '<div class="mg-plugin-title">' + esc(plugin.name) + '</div>';
  html += '<div class="mg-plugin-desc">' + esc(plugin.description) + '</div>';
  if (plugin.actions && plugin.actions.length) {
    html += '<div class="mg-wizard-actions">';
    plugin.actions.forEach(function(a, ai) {
      if (a.link) {
        html += '<a href="' + a.link + '">' + esc(a.label) + '</a>';
      } else {
        html += '<button class="mg-btn mg-btn-sm" onclick="(function(){var p=window._plugins.find(function(x){return x.id===\'' + plugin.id + '\'});runAction(p,p.actions[' + ai + '])})()">' + esc(a.label) + '</button>';
      }
    });
    html += '</div>';
  }
  if (plugin.config_schema && plugin.config_schema.length) {
    html += '<button class="mg-btn" onclick="loadConfig(window._plugins.find(function(x){return x.id===\'' + plugin.id + '\'}))">Configure</button>';
    html += '<div class="mg-card-body" id="config-' + plugin.id + '" style="display:none"></div>';
  }
  if (plugin.child_configs) {
    html += '<div class="mg-card-body" id="children-' + plugin.id + '">Loading...</div>';
  }
  html += '<div class="mg-status" id="status-' + esc(plugin.id) + '"></div>';
  html += '</div>';
  return html;
}

// --- Generic plugin config ---

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
    var v = values[f.key] !== undefined ? values[f.key] : (f.default || '');
    var sw = f.show_when;
    var da = sw ? ' data-show-key="'+sw.key+'" data-show-val="'+sw.value.join(',')+'"' : '';
    html += '<div class="mg-form-row mg-config-field"'+da+'>';
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
      html += '<input type="password" name="'+f.key+'" placeholder="leave blank to keep">';
    } else if (f.type === 'readonly') {
      html += '<span class="mg-readonly">'+esc(v)+'</span>';
    } else {
      var t = f.type==='email'?'email':f.type==='number'?'number':'text';
      html += '<input type="'+t+'" name="'+f.key+'" value="'+esc(v)+'"'+(f.required?' required':'')+'>';
    }
    html += '</div>';
  });
  html += '<div class="mg-form-row"><label></label><button type="submit" class="mg-btn mg-btn-outline">Save</button></div></form>';
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
    f.style.display = show ? (f.classList.contains('mg-form-row') ? 'flex' : 'block') : 'none';
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
      if (status) status.textContent = 'Saved. Reloading...';
      setTimeout(function() { location.reload(); }, 1000);
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
    if (!data.ok) {
      mgShowWarning(data.error || 'Action failed', true);
      status.textContent = '';
      return;
    }
    mgClearWarning();
    status.textContent = 'Done.';

    // Link Audit: render the report inline in the audit-report card
    // rather than opening it in a new tab. Other plugins keep the
    // existing open_url behaviour unchanged.
    if (plugin.id === 'audit' && action.id === 'run' && data.report_url) {
      renderAuditReport(data.report_url);
    }
    else if (action.on_complete === 'open_url' && data[action.result_key]) {
      window.open(data[action.result_key], '_blank');
    }
    setTimeout(function() { status.textContent = ''; }, 5000);
  })
  .catch(function(e) {
    mgShowWarning('Error: ' + e.message, true);
    status.textContent = '';
  });
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
        cardHtml += '<a href="/manager/edit?path=/' + encodeURIComponent(dir + '/' + f.name) + '" style="font-size:11px;color:#07c;">Edit raw</a>';
        cardHtml += '</div>';
        cardHtml += '<div id="form-targets-' + formName + '" style="display:none"></div>';
        cardHtml += '</div>';
      });
    } else {
      cardHtml += '<p style="font-size:13px;color:#888;">No form configs found.</p>';
    }
    cardHtml += '<div class="mg-status" id="status-form-connections"></div>';
    cardHtml += '</div>';

    var pluginCard = document.getElementById('plugin-' + plugin.id);
    pluginCard.insertAdjacentHTML('afterend', cardHtml);
  });
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
      html += '<div class="mg-handler-item-header">';
      html += '<span class="mg-handler-name">' + esc(h.name || h.id) + '</span>';
      html += '<span class="mg-badge ' + (enabled ? 'enabled' : 'disabled') + '">' + (enabled ? 'enabled' : 'disabled') + '</span>';
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
      html += '<div class="mg-handler-edit-form" id="handler-edit-' + h.id + '" style="display:none"></div>';
      html += '</div>';
    });

    if (ofType.length === 0) {
      html += '<p class="mg-empty">No ' + typeLabels[type].toLowerCase() + ' handlers configured.</p>';
    }

    html += '</div>';
  });

  html += '<div id="add-handler-wizard" style="display:none"></div>';

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
        // Directory exists: link into the file browser. The files page
        // reads its current directory from location.hash, so use # (not
        // a query param) for the path.
        html = '<a href="/manager/files#' + encodeURIComponent(path)
             + '" class="mg-btn mg-btn-sm">View submissions</a>';
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

// --- Wizard: add handler ---

function showAddHandlerForm(type) {
  hideAddWizard();

  var wizard = document.getElementById('add-handler-wizard');
  if (!wizard) return;

  // Move wizard inside the relevant group
  var group = document.getElementById('mg-handler-group-' + type);
  if (group) group.appendChild(wizard);

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
  var wizard = document.getElementById('add-handler-wizard');
  if (wizard) { wizard.innerHTML = ''; wizard.style.display = 'none'; }
}

// --- Step 2 form (shared by add and edit) ---

function renderStep2Form(type, name, existingData, isEdit) {
  var d = existingData || {};
  var html = '';

  if (isEdit) {
    html += '<div class="mg-form-row">';
    html += '<label>ID</label>';
    html += '<span class="mg-readonly">' + esc(d.id || '') + '</span>';
    html += '</div>';
    html += '<div class="mg-form-row">';
    html += '<label>Type</label>';
    html += '<span class="mg-readonly">' + esc(typeLabelFor(type)) + '</span>';
    html += '</div>';
  }

  html += '<div class="mg-wizard-section-label">Handler settings</div>';
  html += '<div class="mg-form-row">';
  html += '<label>Name</label>';
  html += '<input type="text" id="wiz-name" value="' + esc(d.name || name) + '" required>';
  html += '</div>';
  html += '<div class="mg-form-row">';
  html += '<label>Enabled</label>';
  html += '<input type="checkbox" id="wiz-enabled"' + (d.enabled !== 'false' ? ' checked' : '') + '>';
  html += '</div>';

  if (type === 'smtp') html += renderSmtpFields(d);
  else if (type === 'file') html += renderFileFields(d);
  else if (type === 'webhook') html += renderWebhookFields(d);

  html += '<div class="mg-wizard-actions">';
  if (isEdit) {
    html += '<button type="button" class="mg-btn mg-btn-outline" onclick="saveHandlerFromWizard(\'' + esc(d.id) + '\',\'' + type + '\',true)">Update</button>';
    html += '<button type="button" class="mg-btn" onclick="cancelHandlerEdit(\'' + esc(d.id) + '\')">Cancel</button>';
  } else {
    html += '<button type="button" class="mg-btn mg-btn-outline" onclick="saveHandlerFromWizard(null,\'' + type + '\',false)">Add handler</button>';
    html += '<button type="button" class="mg-btn" onclick="hideAddWizard()">Cancel</button>';
  }
  html += '</div>';

  return html;
}

function renderSmtpFields(d) {
  var sv = smtpConnectionValues || {};
  var html = '';

  html += '<div class="mg-wizard-section-label">Email settings</div>';
  html += '<div class="mg-form-row"><label>From address</label>';
  html += '<input type="email" id="wiz-from" value="' + esc(d.from || 'webforms@example.com') + '" required>';
  html += '</div>';
  html += '<div class="mg-form-row"><label>To address</label>';
  html += '<input type="email" id="wiz-to" value="' + esc(d.to || 'admin@example.com') + '" required>';
  html += '</div>';
  html += '<div class="mg-form-row"><label>Subject prefix</label>';
  html += '<input type="text" id="wiz-subject_prefix" value="' + esc(d.subject_prefix !== undefined ? d.subject_prefix : '[Contact] ') + '">';
  html += '</div>';

  if (!smtpPlugin) return html;

  html += '<div class="mg-wizard-section-label">SMTP connection</div>';

  var method = sv.method || 'sendmail';
  html += '<div class="mg-form-row"><label>Send method</label>';
  html += '<select id="wiz-method" onchange="applyShowWhen(this.closest(\'.mg-wizard\')||this.closest(\'.mg-handler-edit-form\'))">';
  ['sendmail', 'smtp'].forEach(function(o) {
    html += '<option' + (method === o ? ' selected' : '') + '>' + o + '</option>';
  });
  html += '</select></div>';

  html += '<div class="mg-form-row mg-config-field" data-show-key="wiz-method" data-show-val="sendmail">';
  html += '<label>Sendmail path</label>';
  html += '<input type="text" id="wiz-sendmail_path" value="' + esc(sv.sendmail_path || '/usr/sbin/sendmail') + '">';
  html += '</div>';

  html += '<div class="mg-form-row mg-config-field" data-show-key="wiz-method" data-show-val="smtp">';
  html += '<label>Host</label>';
  html += '<input type="text" id="wiz-host" value="' + esc(sv.host || 'localhost') + '">';
  html += '</div>';

  html += '<div class="mg-form-row mg-config-field" data-show-key="wiz-method" data-show-val="smtp">';
  html += '<label>Port</label>';
  html += '<input type="number" id="wiz-port" value="' + esc(sv.port || '587') + '" min="1" max="65535">';
  html += '</div>';

  html += '<div class="mg-form-row mg-config-field" data-show-key="wiz-method" data-show-val="smtp">';
  html += '<label>TLS</label>';
  html += '<select id="wiz-tls">';
  var tlsVal = sv.tls || 'false';
  ['false', 'starttls', 'true'].forEach(function(o) {
    html += '<option' + (tlsVal === o ? ' selected' : '') + '>' + o + '</option>';
  });
  html += '</select></div>';

  var authVal = sv.auth === 'true' || sv.auth === '1';
  html += '<div class="mg-form-row mg-config-field" data-show-key="wiz-method" data-show-val="smtp">';
  html += '<label>Authentication</label>';
  html += '<input type="checkbox" id="wiz-auth"' + (authVal ? ' checked' : '') + ' onchange="applyShowWhen(this.closest(\'.mg-wizard\')||this.closest(\'.mg-handler-edit-form\'))">';
  html += '</div>';

  // Auth fields: nested inside a smtp-only wrapper so they hide when method != smtp
  html += '<div class="mg-config-field" data-show-key="wiz-method" data-show-val="smtp">';
  html += '<div class="mg-form-row mg-config-field" data-show-key="wiz-auth" data-show-val="true,1">';
  html += '<label>Username</label>';
  html += '<input type="text" id="wiz-username" value="' + esc(sv.username || '') + '">';
  html += '</div>';
  html += '<div class="mg-form-row mg-config-field" data-show-key="wiz-auth" data-show-val="true,1">';
  html += '<label>Password file</label>';
  html += '<input type="text" id="wiz-password_file" value="' + esc(sv.password_file || 'lazysite/forms/.smtp-password') + '">';
  html += '</div>';
  html += '</div>';

  return html;
}

function renderFileFields(d) {
  var html = '<div class="mg-wizard-section-label">File settings</div>';
  html += '<div class="mg-form-row"><label>Directory</label>';
  html += '<input type="text" id="wiz-path" value="' + esc(d.path || 'lazysite/forms/submissions') + '" required>';
  html += '</div>';
  // Only show the "View submissions" row on edit (not add): the handler
  // needs an id before we can probe. d.id is present on edit, absent on
  // the add wizard. checkSubmissionsDir() will populate the slot.
  if (d.id) {
    html += '<div class="mg-form-row"><label>Submissions</label>';
    html += '<div data-submissions-for="' + esc(d.id) + '">';
    html += '<span style="font-size:0.8rem;color:var(--mg-text-light)">Checking...</span>';
    html += '</div></div>';
  }
  return html;
}

function renderWebhookFields(d) {
  var html = '<div class="mg-wizard-section-label">Webhook settings</div>';
  html += '<div class="mg-form-row"><label>URL</label>';
  html += '<input type="url" id="wiz-url" value="' + esc(d.url || '') + '" required placeholder="https://">';
  html += '</div>';
  html += '<div class="mg-form-row"><label>Format</label>';
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

  if (div.style.display !== 'none') {
    div.innerHTML = '';
    div.style.display = 'none';
    return;
  }

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
}

// --- Handler delete and refresh ---

function deleteHandler(handlerId) {
  if (!confirm('Delete handler "' + handlerId + '"?')) return;
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

    html += '<div class="mg-form-row" style="margin-bottom:0.25rem">';
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
    html += '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="deleteTarget(\'' + esc(formName) + '\',' + idx + ')">&times;</button>';
    html += '</div>';
  });

  html += '</div>';
  html += '<div class="mg-wizard-actions">';
  html += '<button class="mg-btn mg-btn-sm mg-btn-outline" onclick="addTarget(\'' + esc(formName) + '\')">+ Add target</button>';
  html += '<button class="mg-btn mg-btn-sm mg-btn-outline" onclick="saveFormTargets(\'' + esc(formName) + '\')">Save</button>';
  html += '</div>';

  div.innerHTML = html;
}

function updateFormTarget(el) {
  var formName = el.dataset.form;
  var idx = parseInt(el.dataset.idx, 10);
  var div = document.getElementById('form-targets-' + formName);
  if (!div || !div._targets) return;
  div._targets[idx] = el.value;
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
  renderFormTargets(formName, div._targets);
}

function deleteTarget(formName, idx) {
  var div = document.getElementById('form-targets-' + formName);
  if (!div || !div._targets) return;
  div._targets.splice(idx, 1);
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
