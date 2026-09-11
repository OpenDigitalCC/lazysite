---
title: Handlers
auth: manager
search: false
---

<div id="status" class="mg-status"></div>

<!-- SM842: ONE WAY TO DELIVER. A handler is a named function a form or the
     schedule calls - it sends email, keeps a file, stores a row in a data
     table, or sends through a connector. This page is the manager's surface
     for all three things that name one: the handlers themselves, which forms
     call which, and what the timer calls. The same actions serve the control
     API, MCP and lazysite-handlers.pl, so nothing here can do what those
     cannot, or the other way round.

     The note is the rule the page cannot show by greying things out: who may
     create a handler depends on where it sends, and the refusal says which
     capability would work. -->
<div class="mg-note mg-note-info">A handler is a named function a form or the schedule calls: it sends
email, keeps each submission in a file, stores a row in a data table, or sends through a
connector. <strong>Where it sends decides who may configure it</strong> &mdash; a table handler needs
Data, a connector handler needs Connectors, email and file handlers need Forms. Binding a form to
a handler that exists needs Forms alone.</div>

<div class="mg-card">
  <div class="mg-card-header">
    <span class="mg-card-title">Handlers</span>
    <span class="mg-card-subtitle">the named functions a form or the schedule calls</span>
  </div>
  <div class="mg-card-body">
    <div class="mg-toolbar">
      <button class="mg-btn" data-impact="inert" onclick="newHandler()">New handler</button>
      <button class="mg-btn" data-impact="inert" onclick="load()">Refresh</button>
    </div>
    <div class="mg-expand" id="exp-new-handler" hidden></div>
    <div class="mg-list" id="handler-list">
      <div class="mg-row"><span class="mg-row-name">Loading...</span><span class="mg-row-meta"></span><span class="mg-row-actions"></span></div>
    </div>
  </div>
</div>

<div class="mg-card">
  <div class="mg-card-header">
    <span class="mg-card-title">Forms</span>
    <span class="mg-card-subtitle">which handlers each form calls when a visitor submits it</span>
  </div>
  <div class="mg-card-body">
    <div class="mg-list" id="form-list">
      <div class="mg-row"><span class="mg-row-name">Loading...</span><span class="mg-row-meta"></span><span class="mg-row-actions"></span></div>
    </div>
  </div>
</div>

<div class="mg-card">
  <div class="mg-card-header">
    <span class="mg-card-title">Schedule</span>
    <span class="mg-card-subtitle">which handler the timer calls, how often, with what</span>
  </div>
  <div class="mg-card-body">
    <div class="mg-toolbar">
      <button class="mg-btn" data-impact="inert" onclick="newEntry()">New schedule entry</button>
    </div>
    <div class="mg-expand" id="exp-new-entry" hidden></div>
    <div class="mg-list" id="schedule-list">
      <div class="mg-row"><span class="mg-row-name">Loading...</span><span class="mg-row-meta"></span><span class="mg-row-actions"></span></div>
    </div>
  </div>
</div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';
var HANDLERS = [];
var TYPES = [];
var FORMS = {};
var SCHEDULE = [];
var FLOOR = 300;

// SM806: A VALUE THE ENGINE KNOWS IS CHOSEN, NOT TYPED. null means not asked
// yet, or could not read - and neither is an empty list (SM784): the table list
// needs Data and the connector list needs Connectors, which a holder of Forms
// may not have. Where the list is unknown the field stays a text box and says
// so, and a configured value missing from the list is kept and marked.
var TABLES = null;
var CONNECTORS = null;

function escHtml(s) {
  return String(s == null ? '' : s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function showStatus(msg, isError) {
  var el = document.getElementById('status');
  if (isError) {
    if (typeof mgShowWarning === 'function') mgShowWarning(msg, true);
    if (el) { el.textContent = ''; el.className = 'mg-status'; }
    return;
  }
  if (typeof mgClearWarning === 'function') mgClearWarning();
  if (!el) return;
  if (!msg) { el.textContent = ''; el.className = 'mg-status'; return; }
  el.className = 'mg-status mg-status-success';
  el.textContent = msg;
  setTimeout(function() { showStatus(''); }, 3000);
}

// Saving behaviour 4: the answer to an action goes where the action was taken.
function editorStatus(key, msg, isError) {
  var el = document.getElementById('st-' + key);
  if (!el) { showStatus(msg, isError); return; }
  el.className = 'mg-status ' + (isError ? 'mg-status-error' : 'mg-status-success');
  el.textContent = msg;
}

// The layout wraps fetch and attaches X-CSRF-Token to every POST.
function post(action, body) {
  return fetch(API + '?action=' + action, {
    method: 'POST', credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  }).then(function(r) { return r.json(); });
}

function val(id) { var e = document.getElementById(id); return e ? e.value : ''; }
function checked(id) { var e = document.getElementById(id); return e ? e.checked : false; }

// --- unsaved changes (saving behaviours 1-3) --------------------------------

function dirtyNote(key) {
  return '<span id="dirty-' + key + '" class="mg-dirty-note">Unsaved changes</span>';
}
function watchEditor(key) {
  var note = document.getElementById('dirty-' + key);
  if (note) note.style.display = 'none';
  var box = document.getElementById('ed-' + key);
  if (!box) return;
  var mark = function(e) {
    if (e.target && e.target.classList) e.target.classList.add('mg-dirty');
    mgDirtyGuard.set(key, 'dirty-' + key);
  };
  box.addEventListener('input', mark);
  box.addEventListener('change', mark);
}
function cleanEditor(key) { mgDirtyGuard.clear(key); }

// --- loading ----------------------------------------------------------------

function loadChoices() {
  fetch(API + '?action=data-tables')
    .then(function(r) { return r.json(); })
    .then(function(d) {
      if (!d || !d.ok || !d.tables) return;
      TABLES = d.tables.map(function(t) { return (typeof t === 'string') ? t : (t.table || t.name); })
                       .filter(function(n) { return n; }).sort();
    })
    .catch(function() { /* stays null: unknown, not empty */ });
  fetch(API + '?action=connector-list')
    .then(function(r) { return r.json(); })
    .then(function(d) {
      if (!d || !d.ok || !d.connectors) return;
      CONNECTORS = d.connectors.map(function(c) { return c.id; }).sort();
    })
    .catch(function() { /* stays null */ });
}

function load() {
  fetch(API + '?action=handler-list')
    .then(function(r) { return r.json(); })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error, true); return; }
      HANDLERS = d.handlers || [];
      TYPES = d.types || [];
      FORMS = d.forms || {};
      renderHandlers();
      renderForms();
    })
    .catch(function(e) { showStatus('Failed to load handlers: ' + e.message, true); });
  fetch(API + '?action=schedule-list')
    .then(function(r) { return r.json(); })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error, true); return; }
      SCHEDULE = d.schedule || [];
      FLOOR = d.floor || 300;
      renderSchedule();
    })
    .catch(function(e) { showStatus('Failed to load the schedule: ' + e.message, true); });
}

function typeDef(type) {
  for (var i = 0; i < TYPES.length; i++) { if (TYPES[i].type === type) return TYPES[i]; }
  return null;
}
function typeLabel(type) { var t = typeDef(type); return t ? t.label : (type || 'unknown'); }
function handlerById(id) {
  for (var i = 0; i < HANDLERS.length; i++) { if (HANDLERS[i].id === id) return HANDLERS[i]; }
  return null;
}

// --- the one idiom: a row, and its card as the next sibling -----------------

function chev(listId, key, label, word) {
  return '<a href="#" class="mg-chev mg-chev-label" data-key="' + escHtml(key) + '"'
    + ' data-label="' + escHtml(label) + '"'
    + ' onclick="return toggleRow(this, \'' + listId + '\', \'' + escHtml(key) + '\')"'
    + ' aria-expanded="false" aria-label="Show details for ' + escHtml(label) + '"'
    + ' title="Show details for ' + escHtml(label) + '">' + word + '</a>';
}

function nameChev(a, verb) {
  var label = a.getAttribute('data-label') || '';
  a.setAttribute('aria-label', verb + ' details for ' + label);
  a.setAttribute('title', verb + ' details for ' + label);
}

function closeAll(listId) {
  var chevs = document.querySelectorAll('#' + listId + ' .mg-chev');
  for (var i = 0; i < chevs.length; i++) {
    chevs[i].classList.remove('mg-chev-open');
    chevs[i].setAttribute('aria-expanded', 'false');
    nameChev(chevs[i], 'Show');
  }
  var bodies = document.querySelectorAll('#' + listId + ' .mg-expand');
  for (var j = 0; j < bodies.length; j++) { bodies[j].hidden = true; }
}

var BUILD = {};
function toggleRow(a, listId, key) {
  var body = document.getElementById('exp-' + key);
  var opening = body.hidden;
  if (opening && !confirmLeave()) return false;
  closeAll(listId);
  if (opening) {
    body.innerHTML = BUILD[listId](key);
    body.hidden = false;
    a.classList.add('mg-chev-open');
    a.setAttribute('aria-expanded', 'true');
    nameChev(a, 'Hide');
    watchEditor(key);
  }
  return false;
}

// Saving behaviour 3: leaving an editor with unsaved changes asks first.
function confirmLeave() {
  var open = document.querySelectorAll('.mg-dirty');
  if (!open.length) return true;
  if (!window.confirm('An editor on this page has unsaved changes. Close it and lose them?')) return false;
  for (var i = 0; i < open.length; i++) open[i].classList.remove('mg-dirty');
  return true;
}

// --- handlers ---------------------------------------------------------------

function destinationOf(h) {
  if (h.type === 'smtp') return 'email to ' + (h.to || '?');
  if (h.type === 'file') return 'file in ' + (h.path || 'lazysite/forms/submissions');
  if (h.type === 'table') return 'rows into ' + (h.table || '?') + (h.keep_copy === 'false' ? '' : ', with a copy');
  if (h.type === 'connector') return 'through ' + (h.connector || '?');
  return h.type || 'unknown';
}

function usedText(u) {
  u = u || { forms: [], schedule: [] };
  var parts = [];
  if (u.forms.length) parts.push(u.forms.length + ' form' + (u.forms.length === 1 ? '' : 's'));
  if (u.schedule.length) parts.push(u.schedule.length + ' schedule entr' + (u.schedule.length === 1 ? 'y' : 'ies'));
  return parts.length ? 'used by ' + parts.join(' and ') : 'not used yet';
}

function renderHandlers() {
  var el = document.getElementById('handler-list');
  if (!HANDLERS.length) {
    el.innerHTML = '<div class="mg-empty">No handlers yet. A handler is what a form or the schedule calls.</div>';
    return;
  }
  el.innerHTML = HANDLERS.map(handlerRow).join('');
}

function handlerRow(h) {
  var key = 'h-' + h.id;
  var state = h.problem
    ? '<span class="mg-tag mg-tag-warn">' + escHtml(h.problem) + '</span>'
    : (h.enabled ? '<span class="mg-tag mg-tag-on">on</span>' : '<span class="mg-tag mg-tag-off">off</span>');
  return '<div class="mg-row">'
    + '<span class="mg-row-name">' + escHtml(h.id)
    + (h.name ? ' <span class="mg-row-meta">' + escHtml(h.name) + '</span>' : '') + '</span>'
    + '<span class="mg-row-meta">' + escHtml(typeLabel(h.type)) + ' &middot; ' + escHtml(destinationOf(h))
    + ' &middot; ' + escHtml(usedText(h.used_by)) + '</span>'
    + '<span class="mg-row-actions">' + state + ' ' + chev('handler-list', key, h.id, 'Configure') + '</span>'
    + '</div>'
    + '<div class="mg-expand" id="exp-' + escHtml(key) + '" hidden></div>';
}

BUILD['handler-list'] = function(key) { return handlerEditor(handlerById(key.replace(/^h-/, '')), key); };

// A field for each declared key, drawn from the type's schema - the same
// catalogue the engine validates against, so the page cannot offer a field the
// type does not take (a key the type does not declare is refused by name).
function fieldFor(key, f, value) {
  var id = 'f-' + key + '-' + f.key;
  var help = f.note || '';
  var cur = (value === undefined || value === null) ? (f['default'] === undefined ? '' : f['default']) : value;
  if (f.type === 'boolean') {
    return '<div class="mg-field"><label class="mg-chk"><input type="checkbox" id="' + id + '"'
      + (String(cur) === 'true' ? ' checked' : '') + '> ' + escHtml(f.label || f.key) + '</label>'
      + (help ? '<span class="mg-muted">' + escHtml(help) + '</span>' : '') + '</div>';
  }
  if (f.type === 'table' || f.type === 'connector') {
    return pickField(id, f.label || f.key, f.type === 'table' ? TABLES : CONNECTORS, String(cur), help,
      f.type === 'table' ? 'The table list could not be read (it needs Data), so type the name.'
                         : 'The connector list could not be read (it needs Connectors), so type the id.');
  }
  return '<div class="mg-field"><label for="' + id + '">' + escHtml(f.label || f.key) + '</label>'
    + '<input class="mg-inp" type="' + (f.type === 'email' ? 'email' : 'text') + '" id="' + id + '" value="' + escHtml(cur) + '">'
    + (help ? '<span class="mg-muted">' + escHtml(help) + '</span>' : '') + '</div>';
}

function pickField(id, label, options, value, help, unknownHelp) {
  value = value || '';
  if (options === null) {
    return '<div class="mg-field"><label for="' + id + '">' + escHtml(label) + '</label>'
      + '<input class="mg-inp" type="text" id="' + id + '" value="' + escHtml(value) + '">'
      + '<span class="mg-muted">' + escHtml(help + ' ' + unknownHelp) + '</span></div>';
  }
  var seen = false;
  var opts = '<option value="">(choose)</option>';
  for (var i = 0; i < options.length; i++) {
    if (options[i] === value) seen = true;
    opts += '<option value="' + escHtml(options[i]) + '"' + (options[i] === value ? ' selected' : '') + '>'
          + escHtml(options[i]) + '</option>';
  }
  if (value.length && !seen) {
    opts += '<option value="' + escHtml(value) + '" selected>' + escHtml(value) + ' — not on this site</option>';
  }
  return '<div class="mg-field"><label for="' + id + '">' + escHtml(label) + '</label>'
    + '<select class="mg-inp" id="' + id + '">' + opts + '</select>'
    + (help ? '<span class="mg-muted">' + escHtml(help) + '</span>' : '') + '</div>';
}

function handlerEditor(h, key, isNew) {
  h = h || { type: 'smtp', enabled: true };
  var t = typeDef(h.type) || { schema: [] };
  var html = '<div class="mg-expand-body" id="ed-' + key + '"><div class="mg-form-dense">';
  if (isNew) {
    html += '<div class="mg-field"><label for="f-' + key + '-id">Id</label>'
      + '<input class="mg-inp" type="text" id="f-' + key + '-id" value="">'
      + '<span class="mg-muted">How forms and the schedule name it: letters, digits, - and _.</span></div>'
      + '<div class="mg-field"><label for="f-' + key + '-type">Type</label>'
      + '<select class="mg-inp" id="f-' + key + '-type" onchange="retypeNew(this.value)">'
      + TYPES.map(function(x) {
          return '<option value="' + escHtml(x.type) + '"' + (x.type === h.type ? ' selected' : '') + '>' + escHtml(x.label) + '</option>';
        }).join('')
      + '</select></div>';
  } else {
    html += '<div class="mg-field"><label>Type</label><span class="mg-readonly-value">' + escHtml(typeLabel(h.type))
      + '</span><span class="mg-muted">Changing what a handler does is deleting it and making another.</span></div>';
  }
  html += '<div class="mg-field"><label for="f-' + key + '-name">Name</label>'
    + '<input class="mg-inp" type="text" id="f-' + key + '-name" value="' + escHtml(h.name || '') + '">'
    + '<span class="mg-muted">What it is, for the person reading this list.</span></div>'
    + '<div class="mg-field"><label class="mg-chk"><input type="checkbox" id="f-' + key + '-enabled"'
    + (h.enabled === false || h.enabled === 'false' ? '' : ' checked') + '> Enabled</label>'
    + '<span class="mg-muted">A switched-off handler delivers nothing, and a form whose only handler is off refuses the visitor rather than thanking them.</span></div>';
  (t.schema || []).forEach(function(f) { html += fieldFor(key, f, h[f.key]); });
  html += '</div>';
  if (t.note) html += '<p class="mg-note">' + escHtml(t.note) + '</p>';
  if (!isNew && h.used_by) {
    html += '<div class="mg-section-label">Used by</div><p class="mg-muted">'
      + (h.used_by.forms.length ? 'Forms: ' + h.used_by.forms.map(escHtml).join(', ') + '. ' : '')
      + (h.used_by.schedule.length ? 'Schedule: ' + h.used_by.schedule.map(escHtml).join(', ') + '.' : '')
      + (h.used_by.forms.length || h.used_by.schedule.length ? '' : 'Nothing calls it yet.') + '</p>';
  }
  html += '<div class="mg-toolbar">'
    + '<button class="mg-btn mg-btn-primary" data-impact="commit" onclick="saveHandler(\'' + escHtml(key) + '\', ' + (isNew ? 'true' : 'false') + ')">'
    + (isNew ? 'Create' : 'Save') + '</button>';
  if (isNew) {
    html += '<button class="mg-btn" data-impact="inert" onclick="closeNew(\'exp-new-handler\', \'' + escHtml(key) + '\')">Cancel</button>';
  } else {
    if (h.type === 'file' || (h.type === 'table' && h.keep_copy !== 'false')) {
      html += '<a class="mg-btn" href="/manager/plugin-config?submissions='
        + encodeURIComponent('/' + (h.type === 'file' ? (h.path || 'lazysite/forms/submissions') : 'lazysite/forms/submissions') + '/')
        + '">Submissions</a>';
    }
    html += '<button class="mg-btn mg-btn-danger" data-impact="destroy" onclick="deleteHandler(\'' + escHtml(h.id) + '\')">Delete</button>';
  }
  html += ' ' + dirtyNote(key) + '</div><div id="st-' + key + '" class="mg-status"></div></div>';
  return html;
}

function newHandler() {
  if (!confirmLeave()) return;
  closeAll('handler-list');
  openNew('exp-new-handler', 'new-handler', handlerEditor({ type: 'smtp', enabled: true }, 'new-handler', true));
}

function retypeNew(type) {
  var id = val('f-new-handler-id');
  var name = val('f-new-handler-name');
  openNew('exp-new-handler', 'new-handler', handlerEditor({ type: type, enabled: true, name: name }, 'new-handler', true));
  var i = document.getElementById('f-new-handler-id');
  if (i) i.value = id;
}

function openNew(boxId, key, html) {
  var box = document.getElementById(boxId);
  box.innerHTML = html;
  box.hidden = false;
  watchEditor(key);
}

function closeNew(boxId, key) {
  if (!confirmLeave()) return;
  var box = document.getElementById(boxId);
  box.hidden = true;
  box.innerHTML = '';
  cleanEditor(key);
}

function collectHandler(key, isNew) {
  var rec;
  if (isNew) {
    rec = { id: val('f-' + key + '-id'), type: val('f-' + key + '-type') };
  } else {
    var h = handlerById(key.replace(/^h-/, '')) || {};
    rec = { id: h.id, type: h.type };
  }
  rec.name = val('f-' + key + '-name');
  rec.enabled = checked('f-' + key + '-enabled') ? 'true' : 'false';
  var t = typeDef(rec.type) || { schema: [] };
  (t.schema || []).forEach(function(f) {
    var id = 'f-' + key + '-' + f.key;
    rec[f.key] = f.type === 'boolean' ? (checked(id) ? 'true' : 'false') : val(id);
  });
  return rec;
}

function saveHandler(key, isNew) {
  var rec = collectHandler(key, isNew);
  post('handler-save', rec)
    .then(function(d) {
      if (!d.ok) { editorStatus(key, d.error, true); return; }
      cleanEditor(key);
      showStatus(d.created ? 'Created ' + d.id : 'Saved ' + d.id);
      if (isNew) { var box = document.getElementById('exp-new-handler'); box.hidden = true; box.innerHTML = ''; }
      load();
    })
    .catch(function(e) { editorStatus(key, 'Save failed: ' + e.message, true); });
}

function deleteHandler(id) {
  mgConfirm('Delete the handler "' + id + '"? A handler that a form or the schedule still calls is not deleted - the answer says which.',
    { danger: true, ok: 'Delete' })
    .then(function(ok) {
      if (!ok) return;
      return post('handler-delete', { id: id }).then(function(d) {
        if (!d.ok) { editorStatus('h-' + id, d.error, true); return; }
        cleanEditor('h-' + id);
        showStatus('Deleted ' + id);
        load();
      });
    })
    .catch(function(e) { showStatus('Delete failed: ' + e.message, true); });
}

// --- forms ------------------------------------------------------------------

function renderForms() {
  var el = document.getElementById('form-list');
  var names = Object.keys(FORMS).sort();
  if (!names.length) {
    el.innerHTML = '<div class="mg-empty">No forms yet. A page gets a form with a :::form block and a "form:" name in its front matter.</div>';
    return;
  }
  el.innerHTML = names.map(function(n) {
    var ids = FORMS[n] || [];
    var key = 'f-' + n;
    return '<div class="mg-row">'
      + '<span class="mg-row-name">' + escHtml(n) + '</span>'
      + '<span class="mg-row-meta">' + (ids.length ? 'calls ' + ids.map(escHtml).join(', ') : 'calls nothing - it refuses every submission') + '</span>'
      + '<span class="mg-row-actions">' + chev('form-list', key, n, 'Handlers') + '</span>'
      + '</div>'
      + '<div class="mg-expand" id="exp-' + escHtml(key) + '" hidden></div>';
  }).join('');
}

BUILD['form-list'] = function(key) {
  var form = key.replace(/^f-/, '');
  var have = {};
  (FORMS[form] || []).forEach(function(id) { have[id] = 1; });
  var boxes = HANDLERS.map(function(h) {
    return '<label class="mg-chk"><input type="checkbox" data-handler="' + escHtml(h.id) + '"' + (have[h.id] ? ' checked' : '') + '> '
      + escHtml(h.id) + ' <span class="mg-muted">' + escHtml(typeLabel(h.type) + ' - ' + destinationOf(h)) + '</span></label>';
  }).join('');
  return '<div class="mg-expand-body" id="ed-' + key + '">'
    + '<div class="mg-section-label">Handlers this form calls</div>'
    + '<div class="mg-checks">' + (boxes || '<span class="mg-muted">No handlers yet - create one above.</span>') + '</div>'
    + '<p class="mg-muted">Every ticked handler is called for each submission. The visitor is thanked when at least one delivers.</p>'
    + '<div class="mg-toolbar"><button class="mg-btn mg-btn-primary" data-impact="commit" onclick="saveForm(\'' + escHtml(form) + '\')">Save</button> '
    + dirtyNote(key) + '</div><div id="st-' + key + '" class="mg-status"></div></div>';
};

function saveForm(form) {
  var key = 'f-' + form;
  var boxes = document.querySelectorAll('#ed-' + key + ' input[data-handler]');
  var ids = [];
  for (var i = 0; i < boxes.length; i++) { if (boxes[i].checked) ids.push(boxes[i].getAttribute('data-handler')); }
  post('form-targets-save', { form: form, handlers: ids })
    .then(function(d) {
      if (!d.ok) { editorStatus(key, d.error, true); return; }
      cleanEditor(key);
      showStatus('Saved ' + form);
      load();
    })
    .catch(function(e) { editorStatus(key, 'Save failed: ' + e.message, true); });
}

// --- the schedule -----------------------------------------------------------

function everyText(s) {
  s = parseInt(s, 10) || 0;
  if (s % 86400 === 0) return 'every ' + (s / 86400) + ' day' + (s === 86400 ? '' : 's');
  if (s % 3600 === 0) return 'every ' + (s / 3600) + ' hour' + (s === 3600 ? '' : 's');
  if (s % 60 === 0) return 'every ' + (s / 60) + ' minutes';
  return 'every ' + s + ' seconds';
}

function renderSchedule() {
  var el = document.getElementById('schedule-list');
  if (!SCHEDULE.length) {
    el.innerHTML = '<div class="mg-empty">Nothing is scheduled. An entry calls a handler on a timer, with fields you fix here.</div>';
    return;
  }
  el.innerHTML = SCHEDULE.map(function(e) {
    var key = 's-' + e.id;
    var state = e.problem
      ? '<span class="mg-tag mg-tag-warn">' + escHtml(e.problem) + '</span>'
      : (e.enabled ? '<span class="mg-tag mg-tag-on">on</span>' : '<span class="mg-tag mg-tag-off">off</span>');
    return '<div class="mg-row">'
      + '<span class="mg-row-name">' + escHtml(e.id) + '</span>'
      + '<span class="mg-row-meta">' + escHtml(everyText(e.every)) + ' &middot; calls ' + escHtml(e.handler)
      + (e.cap ? ' &middot; needs ' + escHtml(e.cap) : '') + '</span>'
      + '<span class="mg-row-actions">' + state + ' ' + chev('schedule-list', key, e.id, 'Configure') + '</span>'
      + '</div>'
      + '<div class="mg-expand" id="exp-' + escHtml(key) + '" hidden></div>';
  }).join('');
}

function entryById(id) {
  for (var i = 0; i < SCHEDULE.length; i++) { if (SCHEDULE[i].id === id) return SCHEDULE[i]; }
  return null;
}

// The payload is a flat set of fields: one `name = value` per line here, an
// object on the wire. Nothing a visitor sends ever reaches a scheduled call.
function payloadText(p) {
  return Object.keys(p || {}).sort().map(function(k) { return k + ' = ' + p[k]; }).join('\n');
}
function parsePayload(text) {
  var out = {};
  var lines = String(text || '').split(/\r?\n/);
  for (var i = 0; i < lines.length; i++) {
    var l = lines[i].replace(/^\s+|\s+$/g, '');
    if (!l.length) continue;
    var at = l.indexOf('=');
    if (at < 1) return { error: 'line ' + (i + 1) + ' is not name = value' };
    out[l.substring(0, at).replace(/\s+$/, '')] = l.substring(at + 1).replace(/^\s+/, '');
  }
  return { payload: out };
}

BUILD['schedule-list'] = function(key) { return entryEditor(entryById(key.replace(/^s-/, '')), key, false); };

function entryEditor(e, key, isNew) {
  e = e || { every: 3600, enabled: true, payload: {} };
  var opts = HANDLERS.map(function(h) { return h.id; });
  var html = '<div class="mg-expand-body" id="ed-' + key + '"><div class="mg-form-dense">';
  if (isNew) {
    html += '<div class="mg-field"><label for="f-' + key + '-id">Id</label>'
      + '<input class="mg-inp" type="text" id="f-' + key + '-id" value="">'
      + '<span class="mg-muted">Letters, digits, - and _.</span></div>';
  }
  html += pickField('f-' + key + '-handler', 'Handler', opts, e.handler || '', 'The function the timer calls. The job account must hold the capability of where it sends.', '')
    + '<div class="mg-field"><label for="f-' + key + '-every">Every (seconds)</label>'
    + '<input class="mg-inp" type="number" min="' + FLOOR + '" id="f-' + key + '-every" value="' + escHtml(e.every) + '">'
    + '<span class="mg-muted">At least ' + FLOOR + ' - the timer\'s own tick. 3600 is hourly, 86400 daily.</span></div>'
    + '<div class="mg-field"><label for="f-' + key + '-payload">Fields</label>'
    + '<textarea class="mg-inp" rows="4" id="f-' + key + '-payload">' + escHtml(payloadText(e.payload)) + '</textarea>'
    + '<span class="mg-muted">One name = value per line: what the handler is called with, every time.</span></div>'
    + '<div class="mg-field"><label class="mg-chk"><input type="checkbox" id="f-' + key + '-enabled"'
    + (e.enabled === false || e.enabled === 'false' ? '' : ' checked') + '> Enabled</label></div>'
    + '</div><div class="mg-toolbar">'
    + '<button class="mg-btn mg-btn-primary" data-impact="commit" onclick="saveEntry(\'' + escHtml(key) + '\', ' + (isNew ? 'true' : 'false') + ')">'
    + (isNew ? 'Create' : 'Save') + '</button>';
  if (isNew) {
    html += '<button class="mg-btn" data-impact="inert" onclick="closeNew(\'exp-new-entry\', \'' + escHtml(key) + '\')">Cancel</button>';
  } else {
    html += '<button class="mg-btn mg-btn-danger" data-impact="destroy" onclick="deleteEntry(\'' + escHtml(e.id) + '\')">Delete</button>';
  }
  html += ' ' + dirtyNote(key) + '</div><div id="st-' + key + '" class="mg-status"></div></div>';
  return html;
}

function newEntry() {
  if (!confirmLeave()) return;
  closeAll('schedule-list');
  openNew('exp-new-entry', 'new-entry', entryEditor(null, 'new-entry', true));
}

function saveEntry(key, isNew) {
  var p = parsePayload(val('f-' + key + '-payload'));
  if (p.error) { editorStatus(key, 'Fields: ' + p.error, true); return; }
  var rec = {
    id: isNew ? val('f-' + key + '-id') : key.replace(/^s-/, ''),
    handler: val('f-' + key + '-handler'),
    every: val('f-' + key + '-every'),
    payload: p.payload,
    enabled: checked('f-' + key + '-enabled') ? 'true' : 'false'
  };
  post('schedule-save', rec)
    .then(function(d) {
      if (!d.ok) { editorStatus(key, d.error, true); return; }
      cleanEditor(key);
      showStatus(d.created ? 'Scheduled ' + d.id : 'Saved ' + d.id);
      if (isNew) { var box = document.getElementById('exp-new-entry'); box.hidden = true; box.innerHTML = ''; }
      load();
    })
    .catch(function(e) { editorStatus(key, 'Save failed: ' + e.message, true); });
}

function deleteEntry(id) {
  mgConfirm('Remove the schedule entry "' + id + '"? The timer stops calling its handler; the handler itself stays.',
    { danger: true, ok: 'Remove' })
    .then(function(ok) {
      if (!ok) return;
      return post('schedule-delete', { id: id }).then(function(d) {
        if (!d.ok) { editorStatus('s-' + id, d.error, true); return; }
        cleanEditor('s-' + id);
        showStatus('Removed ' + id);
        load();
      });
    })
    .catch(function(e) { showStatus('Remove failed: ' + e.message, true); });
}

loadChoices();
load();
</script>
