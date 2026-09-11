---
title: Connectors
auth: manager
search: false
---

<div id="status" class="mg-status"></div>

<!-- SM579 phase 2. Phase 1 shipped the connector as an API-first feature, which
     meant the operator who is meant to OWN the destination could only reach it
     through a token client. This is that page.

     The note is the boundary, stated where the decision is made rather than
     only in the docs: an author never supplies a URL. That is the whole SSRF
     answer, and a page that let one be typed into a form would undo it. -->
<div class="mg-note mg-note-info">A connector is a destination this site may send to,
written <strong>here</strong> and reached from a form or the schedule through a connector
handler (on the Handlers page), or from a page. A URL on its own is enough: a connector
needs no credential to send. An author never
supplies a URL &mdash; that is what stops the site being pointed at an internal address.
The credential is held apart from the definition and is never shown back: you can set it
or replace it, and the list says whether one is in place.</div>

<div class="mg-toolbar">
  <button class="mg-btn mg-btn-primary" data-impact="commit" onclick="newConnector()">New connector</button>
  <button class="mg-btn" data-impact="inert" onclick="loadConnectors()">Refresh</button>
</div>

<div class="mg-list" id="connector-list">
  <div class="mg-row"><span class="mg-row-name">Loading...</span></div>
</div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';
var CONNECTORS = [];
var SECRETS_READABLE = 1;

// SM806: A VALUE THE ENGINE KNOWS IS CHOSEN, NOT TYPED.
//
// A mistyped group name silently grants nothing; a mistyped table name is a
// connector that saves cleanly and fails at CALL time, which is the worst
// place to find out.
//
// null means NOT ASKED YET or COULD NOT READ, and neither is an empty list
// (SM784). An empty select would say "this site has no data tables", which is
// a statement about the site; where the list is unknown the field stays a text
// box and says so, because a connector must still be configurable by somebody
// who cannot read the list.
var GROUPS = null;
var TABLES = null;

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

// SM784, and the reason this page exists in the shape it does: has_secret has
// FOUR states, not two. 1 is set, 0 is not set, and null is "the secret store
// could not be read" - which must never be drawn as "not set", because that
// invites an operator to re-enter a credential that is still in place.
function secretState(c) {
  if (!SECRETS_READABLE || c.has_secret === null || c.has_secret === undefined) {
    return { tag: 'unknown', label: 'credential unknown', cls: 'mg-tag mg-tag-warn' };
  }
  return c.has_secret
    ? { tag: 'set', label: 'credential set', cls: 'mg-tag mg-tag-on' }
    : { tag: 'unset', label: 'no credential', cls: 'mg-tag mg-tag-off' };
}

function modesOf(c) {
  var m = c.modes || {};
  var on = [];
  if (m.scheduled) on.push('scheduled');
  if (m.authenticated) on.push('signed in');
  if (m.public) on.push('public');
  return on;
}

// Both lists are gated on capabilities a manage_connectors holder may not
// hold - groups on manage_users, tables on manage_data - so a refusal here is
// ordinary and must not stop the page working.
function loadChoices() {
  fetch(API + '?action=users&sub=groups')
    .then(function(r) { return r.json(); })
    .then(function(d) { if (d && d.ok && d.groups) { GROUPS = Object.keys(d.groups).sort(); } })
    .catch(function() { /* stays null: unknown, not empty */ });
  fetch(API + '?action=data-tables')
    .then(function(r) { return r.json(); })
    .then(function(d) {
      if (!d || !d.ok || !d.tables) return;
      TABLES = d.tables.map(function(t) { return (typeof t === 'string') ? t : (t.table || t.name); })
                       .filter(function(n) { return n; }).sort();
    })
    .catch(function() { /* stays null */ });
}

function loadConnectors() {
  fetch(API + '?action=connector-list')
    .then(function(r) { return r.json(); })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error, true); return; }
      CONNECTORS = d.connectors || [];
      SECRETS_READABLE = d.secrets_readable ? 1 : 0;
      // The API says so in one sentence; the page repeats it where the
      // consequence is, rather than only at the top.
      if (d.warning) { showStatus(d.warning, true); }
      renderConnectors();
    })
    .catch(function(e) { showStatus('Failed to load connectors: ' + e.message, true); });
}

function renderConnectors() {
  var el = document.getElementById('connector-list');
  if (!CONNECTORS.length) {
    el.innerHTML = '<div class="mg-empty">No connectors yet. A connector is what a form or a page sends through.</div>';
    return;
  }
  el.innerHTML = CONNECTORS.map(rowFor).join('');
}

// THE ONE IDIOM (style guide): a listing row, and the row's own card as its
// next sibling. The row carries what tells two connectors apart - where it
// sends, who may cause it, whether it has a credential - and everything that
// is configuration goes into the expander.
function rowFor(c) {
  var s = secretState(c);
  var modes = modesOf(c);
  var meta = [
    escHtml(c.method || 'POST') + ' ' + escHtml(c.url || ''),
    modes.length ? modes.join(', ') : 'no mode enabled',
    (c.rate_per_hour ? c.rate_per_hour + '/hour' : 'no rate cap')
  ].join(' &middot; ');
  var id = escHtml(c.id);
  return '<div class="mg-row">'
    + '<span class="mg-row-name">' + id
    + (c.name ? ' <span class="mg-row-meta">' + escHtml(c.name) + '</span>' : '')
    + '</span>'
    + '<span class="mg-row-meta">' + meta + '</span>'
    + '<span class="mg-row-actions">'
    + '<span class="' + s.cls + '">' + escHtml(s.label) + '</span> '
    // SM816: THE TRIGGER IS NAMED. It was an empty anchor - no text, no
    // aria-label, no title - and it is the ONLY route to Save and Delete, so an
    // operator reported there was no way to delete a connector. There was; it
    // had nothing to announce itself with. data-conn carries the id so
    // toggleRow can rename it as the state changes.
    + '<a href="#" class="mg-chev mg-chev-label" data-conn="' + id + '"'
    + ' onclick="return toggleRow(this, \'' + id + '\')"'
    + ' aria-expanded="false" aria-label="Show details for ' + id + '"'
    + ' title="Show details for ' + id + '">Configure</a>'
    + '</span></div>'
    + '<div class="mg-expand" id="exp-' + id + '" hidden></div>';
}

// SM816: the trigger's name tracks its state. aria-expanded already said open
// or closed; without a name there was nothing for it to be expanded ABOUT.
function nameChev(a, verb) {
  var id = a.getAttribute('data-conn') || '';
  a.setAttribute('aria-label', verb + ' details for ' + id);
  a.setAttribute('title', verb + ' details for ' + id);
}

// THE ONE IDIOM (style guide): the card is the row's next sibling, it is shown
// and hidden with the `hidden` ATTRIBUTE the stylesheet keys on
// (.mg-expand[hidden] { display: none }), and only one is open at a time.
//
// SM806: this rolled its own show/hide by emptying innerHTML, which is the
// inconsistency the guide exists to end - eight pages had already done it.
// The body is still BUILT on open, because a connector's detail includes a
// read of the call record and there is no reason to make that read for every
// row on the page.
function toggleRow(a, id) {
  var body = document.getElementById('exp-' + id);
  var opening = body.hidden;

  var chevs = document.querySelectorAll('#connector-list .mg-chev');
  for (var i = 0; i < chevs.length; i++) {
    chevs[i].classList.remove('mg-chev-open');
    chevs[i].setAttribute('aria-expanded', 'false');
    nameChev(chevs[i], 'Show');
  }
  var bodies = document.querySelectorAll('#connector-list .mg-expand');
  for (var j = 0; j < bodies.length; j++) { bodies[j].hidden = true; }

  if (opening) {
    body.innerHTML = editorFor(id);
    body.hidden = false;
    a.classList.add('mg-chev-open');
    a.setAttribute('aria-expanded', 'true');
    nameChev(a, 'Hide');
    loadCalls(id);
  }
  return false;
}

function connectorById(id) {
  for (var i = 0; i < CONNECTORS.length; i++) { if (CONNECTORS[i].id === id) return CONNECTORS[i]; }
  return { id: id, modes: {} };
}

function editorFor(id) {
  var c = connectorById(id);
  var m = c.modes || {};
  var st = secretState(c);
  var f = 'f-' + escHtml(id) + '-';
  return '<div class="mg-expand-body">'
    + '<div class="mg-form-dense">'
    + field(f + 'name', 'Label', 'text', c.name || '', 'What this destination is, for the person reading the list.')
    + field(f + 'url', 'URL', 'text', c.url || '', 'https:// anywhere, or http:// to 127.0.0.1 for a service on this host.')
    + selectField(f + 'method', 'Method', ['POST', 'GET'], c.method || 'POST', 'GET sends the payload as a query string.')
    // SM842: what a webhook could send, now that outbound HTTP is a connector.
    + selectField(f + 'format', 'Body', ['json', 'slack'], c.format || 'json', 'json sends the fields as an object; slack sends them as one message, which a Slack incoming webhook takes. POST only.')
    + field(f + 'secret_header', 'Credential header', 'text', c.secret_header || 'Authorization', 'The header the credential is sent in.')
    + field(f + 'secret_prefix', 'Credential prefix', 'text', c.secret_prefix === undefined ? 'Bearer ' : c.secret_prefix, 'Put before the credential. Blank for a bare key.')
    + field(f + 'rate_per_hour', 'Calls per hour', 'number', c.rate_per_hour === undefined ? 60 : c.rate_per_hour, 'The cap that stands between a mistake and a bill. 0 removes it.')
    + field(f + 'timeout', 'Timeout (seconds)', 'number', c.timeout === undefined ? 10 : c.timeout, '1 to 60. A visitor waits this long.')
    + pickField(f + 'answer_table', 'Answer table', TABLES, c.answer_table || '',
        'The data table the answer is kept in. Blank keeps nothing.',
        'The table list could not be read, so type the name.')
    + pickField(f + 'row_table', 'Row table', TABLES, c.row_table || '',
        'The table a page action may send a row from.',
        'The table list could not be read, so type the name.')
    + '</div>'

    + '<div class="mg-section-label">Who may cause a call</div>'
    + '<div class="mg-checks">'
    + check(f + 'm-scheduled', 'On a timer', m.scheduled, 'No request is involved, so nothing a visitor sends can reach the destination.')
    + check(f + 'm-authenticated', 'A signed-in caller', m.authenticated, 'Attributable to a person and revocable by removing a grant.')
    + check(f + 'm-public', 'A public form', m.public, 'THE MODE THAT CAN BE ABUSED. Only with input the implementor bounded - a select, not a free textbox.')
    + '</div>'

    + callersField(f, c.callers || [])

    + '<div class="mg-cred-reveal">Credential: <span class="mg-cred-value">' + escHtml(st.label) + '</span>'
    + (st.tag === 'unknown' ? ' &mdash; the secret store could not be read, so this is not a statement that none is set.' : '')
    + '</div>'
    + '<div class="mg-field"><label for="' + f + 'secret">Set or replace the credential</label>'
    + '<input class="mg-inp" type="password" id="' + f + 'secret" autocomplete="new-password" placeholder="leave blank to keep what is there">'
    + '</div>'

    + '<div class="mg-toolbar">'
    + '<button class="mg-btn mg-btn-primary" data-impact="commit" onclick="saveConnector(\'' + escHtml(id) + '\')">Save</button>'
    + '<button class="mg-btn mg-btn-danger" data-impact="destroy" onclick="deleteConnector(\'' + escHtml(id) + '\')">Delete</button>'
    + '</div>'

    + '<div class="mg-section-label">Recent calls</div>'
    + '<div id="calls-' + escHtml(id) + '"><span class="mg-muted">Loading...</span></div>'
    + '</div>';
}

// SM806: a select when the list is known, a text box when it is not - and in
// EITHER case the current value survives. A configured table that has since
// been dropped stays selected and marked, because silently changing what a
// connector points at is worse than showing something odd.
function pickField(id, label, options, value, help, unknownHelp) {
  value = value || '';
  if (options === null) {
    return field(id, label, 'text', value,
      help + ' ' + unknownHelp);
  }
  var seen = false;
  var opts = '<option value="">' + '(none)' + '</option>';
  for (var i = 0; i < options.length; i++) {
    if (options[i] === value) { seen = true; }
    opts += '<option value="' + escHtml(options[i]) + '"'
          + (options[i] === value ? ' selected' : '') + '>' + escHtml(options[i]) + '</option>';
  }
  if (value.length && !seen) {
    opts += '<option value="' + escHtml(value) + '" selected>'
          + escHtml(value) + ' \u2014 not on this site</option>';
  }
  return '<div class="mg-field"><label for="' + id + '">' + escHtml(label) + '</label>'
    + '<select class="mg-inp" id="' + id + '">' + opts + '</select>'
    + '<span class="mg-muted">' + escHtml(help) + '</span></div>';
}

// The caller groups, as checkboxes when the groups are known. Multi-valued, so
// it takes the shape the modes above already use rather than a second idiom.
function callersField(f, current) {
  var have = {};
  for (var i = 0; i < current.length; i++) { have[current[i]] = 1; }
  if (GROUPS === null) {
    return field(f + 'callers', 'Caller groups', 'text', current.join(', '),
      'Comma-separated. A signed-in caller must be in one of these, or hold Connectors. '
      + 'The group list could not be read, so type the names.');
  }
  var boxes = '';
  for (var j = 0; j < GROUPS.length; j++) {
    boxes += check(f + 'cg-' + GROUPS[j], GROUPS[j], have[GROUPS[j]], '');
  }
  // A group named on the connector that no longer exists still has to be
  // visible, or saving would quietly drop it.
  for (var k = 0; k < current.length; k++) {
    if (GROUPS.indexOf(current[k]) === -1) {
      boxes += check(f + 'cg-' + current[k], current[k], true, 'not a group on this site');
    }
  }
  if (!boxes) { boxes = '<span class="mg-muted">This site has no groups yet.</span>'; }
  return '<div class="mg-section-label">Caller groups</div>'
    + '<div class="mg-checks">' + boxes + '</div>'
    + '<div class="mg-field"><span class="mg-muted">A signed-in caller must be in one of '
    + 'these, or hold Connectors.</span></div>';
}

function field(id, label, type, value, help) {
  return '<div class="mg-field"><label for="' + id + '">' + escHtml(label) + '</label>'
    + '<input class="mg-inp" type="' + type + '" id="' + id + '" value="' + escHtml(value) + '">'
    + '<span class="mg-muted">' + escHtml(help) + '</span></div>';
}

function selectField(id, label, options, value, help) {
  var opts = options.map(function(o) {
    return '<option value="' + escHtml(o) + '"' + (o === value ? ' selected' : '') + '>' + escHtml(o) + '</option>';
  }).join('');
  return '<div class="mg-field"><label for="' + id + '">' + escHtml(label) + '</label>'
    + '<select class="mg-inp" id="' + id + '">' + opts + '</select>'
    + '<span class="mg-muted">' + escHtml(help) + '</span></div>';
}

function check(id, label, on, help) {
  return '<label class="mg-chk"><input type="checkbox" id="' + id + '"' + (on ? ' checked' : '') + '> '
    + escHtml(label) + ' <span class="mg-muted">' + escHtml(help) + '</span></label>';
}

// The layout wraps fetch and attaches X-CSRF-Token to every POST, so a page
// sends JSON with a plain fetch and nothing else.
function post(action, body) {
  return fetch(API + '?action=' + action, {
    method: 'POST', credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  }).then(function(r) { return r.json(); });
}

function val(id) { var e = document.getElementById(id); return e ? e.value : ''; }
function checked(id) { var e = document.getElementById(id); return e ? e.checked : false; }

function saveConnector(id) {
  var f = 'f-' + id + '-';
  var def = {
    name: val(f + 'name'),
    url: val(f + 'url'),
    method: val(f + 'method'),
    format: val(f + 'format'),
    secret_header: val(f + 'secret_header'),
    secret_prefix: val(f + 'secret_prefix'),
    rate_per_hour: val(f + 'rate_per_hour'),
    timeout: val(f + 'timeout'),
    answer_table: val(f + 'answer_table'),
    modes: {
      scheduled: checked(f + 'm-scheduled') ? 1 : 0,
      authenticated: checked(f + 'm-authenticated') ? 1 : 0,
      public: checked(f + 'm-public') ? 1 : 0
    },
    callers: val(f + 'callers').split(',').map(function(s) { return s.replace(/^\s+|\s+$/g, ''); }).filter(function(s) { return s.length; })
  };
  post('connector-save', { id: id, connector: def })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error, true); return; }
      var secret = val('f-' + id + '-secret');
      // The credential is a separate act deliberately: it is stored apart from
      // the definition, and a save that carried it would put it through the
      // same path as an ordinary field.
      if (!secret.length) { showStatus('Saved'); loadConnectors(); return; }
      return post('connector-secret-set', { id: id, secret: secret })
        .then(function(t) {
          if (!t.ok) { showStatus(t.error, true); return; }
          showStatus('Saved, and the credential was replaced');
          loadConnectors();
        });
    })
    .catch(function(e) { showStatus('Save failed: ' + e.message, true); });
}

function deleteConnector(id) {
  mgConfirm('Delete the connector "' + id + '"? Its credential is removed with it, and any form or page that names it stops working.',
    { danger: true, ok: 'Delete' })
    .then(function(ok) {
      if (!ok) return;
      return post('connector-delete', { id: id })
        .then(function(d) {
          if (!d.ok) { showStatus(d.error, true); return; }
          showStatus('Deleted');
          loadConnectors();
        });
    })
    .catch(function(e) { showStatus('Delete failed: ' + e.message, true); });
}

function newConnector() {
  mgPrompt('A short name for the connector (lower case, letters, digits, - and _):', '')
    .then(function(id) {
      if (!id) return;
      return post('connector-save',
        { id: id, connector: { name: '', url: 'https://example.test/', method: 'POST' } })
        .then(function(d) {
          if (!d.ok) { showStatus(d.error, true); return; }
          showStatus('Created - now set its URL and credential');
          loadConnectors();
        });
    })
    .catch(function(e) { showStatus('Could not create: ' + e.message, true); });
}

// The call record is the operator's window on what this connector has
// actually done: outcome and time, never the payload and never the answer.
// SM822: the record is kept for a window, and the panel says which. An operator
// found 47 entries from connectors deleted days earlier and had no way to know
// whether that was policy or neglect.
function retentionNote(j) {
  var d = j && j.retention_days;
  if (!d) { return ''; }
  return '<p class="mg-note">Calls are kept for ' + escHtml(String(d))
    + ' days, including calls from connectors that have since been deleted '
    + '- a deletion does not erase what the connector did.</p>';
}

function loadCalls(id) {
  // SM806: the parameter is `connector`, not `id`. Sending the wrong name
  // did not fail - the filter simply never applied, so every connector's
  // panel listed EVERY connector's calls, and a brand-new connector opened
  // showing somebody else's history. A filter that silently matches
  // everything is worse than one that errors.
  fetch(API + '?action=connector-calls&connector=' + encodeURIComponent(id))
    .then(function(r) { return r.json(); })
    .then(function(d) {
      var el = document.getElementById('calls-' + id);
      if (!el) return;
      if (!d.ok) { el.innerHTML = '<span class="mg-muted">' + escHtml(d.error || 'could not read the call record') + '</span>'; return; }
      var calls = d.calls || [];
      if (!calls.length) { el.innerHTML = '<div class="mg-empty">No calls recorded.</div>' + retentionNote(d); return; }
      el.innerHTML = '<div class="mg-table-wrap"><table class="mg-table">'
        + '<thead><tr><th>When</th><th>Trigger</th><th>Outcome</th><th>HTTP</th></tr></thead><tbody>'
        + calls.map(function(c) {
          return '<tr><td>' + escHtml(c.at_iso || c.at || '') + '</td>'
            + '<td>' + escHtml(c.mode || '') + '</td>'
            + '<td>' + escHtml(c.state || '') + (c.why ? ' <span class="mg-muted">' + escHtml(c.why) + '</span>' : '') + '</td>'
            + '<td>' + escHtml(c.http == null ? '' : c.http) + '</td></tr>';
        }).join('')
        + '</tbody></table></div>'
        + retentionNote(d);
    })
    .catch(function() {
      var el = document.getElementById('calls-' + id);
      if (el) el.innerHTML = '<span class="mg-muted">could not read the call record</span>';
    });
}

loadChoices();
loadConnectors();
</script>
