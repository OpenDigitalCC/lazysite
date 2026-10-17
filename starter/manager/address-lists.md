---
title: Address lists
auth: manager
search: false
---

<div id="status" class="mg-status"></div>

<!-- SM1138 (slice A of SM1134, ruled 2026-10-17): named lists of addresses, each
     allowing or denying. This page keeps the lists; applying one to a page, a
     folder, a group or the manager is the later slices. Reading is manage_users;
     changing is the operator's (Manager::AddressLists), so a viewer who is not
     the operator is shown the lists and no controls. -->
<div class="mg-note mg-note-info">An address list is a named set of addresses and CIDR ranges (IPv4 or IPv6) that is either an <strong>allow</strong> list or a <strong>deny</strong> list. A rule that names a list applies it; where an allow list and a deny list both match an address, <strong>deny wins</strong>. Only the operator changes the lists.</div>

<div class="mg-card">
<div class="mg-card-header"><span class="mg-card-title">Lists</span></div>
<div class="mg-card-body">
<div class="mg-list" id="lists"><div class="mg-empty">Loading...</div></div>
<div class="mg-toolbar"><button class="mg-btn mg-btn-primary" id="new-btn" data-impact="commit" hidden>New list</button></div>
<!-- SM1141 (finished when the SM1134 slices were stacked): a list a rule still names
     is refused with where it is named; the operator may delete it anyway, after a
     second confirmation, and the server audits what still refers to it. -->
<div class="mg-note mg-note-warn" id="in-use" hidden>
<p id="in-use-text"></p>
<div class="mg-toolbar">
<button class="mg-btn mg-btn-danger" id="force-btn" data-impact="destroy" onclick="forceDelete()">Delete anyway</button>
<button class="mg-btn" id="keep-btn" data-impact="inert" onclick="hideInUse()">Keep the list</button>
</div>
</div>
</div>
</div>

<div class="mg-card" id="editor" hidden>
<div class="mg-card-header"><span class="mg-card-title" id="editor-title">New list</span></div>
<div class="mg-card-body">
<label class="mg-field"><span>Name (a-z, 0-9, _ and -)</span><input class="mg-inp" id="list-name" maxlength="64" autocomplete="off"></label>
<label class="mg-field"><span>Kind</span>
<select class="mg-inp" id="list-kind"><option value="allow">allow</option><option value="deny">deny</option></select></label>
<div class="mg-list" id="entry-rows"></div>
<div class="mg-toolbar">
<button class="mg-btn" id="add-entry-btn" data-impact="edit">Add entry</button>
<button class="mg-btn mg-btn-primary" id="save-btn" data-impact="commit">Save list</button>
<button class="mg-btn" id="cancel-btn" data-impact="inert">Cancel</button>
</div>
<p class="mg-muted">An entry is one address (203.0.113.7, 2001:db8::1) or a range (203.0.113.0/24, 2001:db8::/32). A range of every address is refused. An IPv4-mapped IPv6 address (::ffff:203.0.113.7) is an IPv6 address, matched only by an IPv6 entry.</p>
</div>
</div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';
var lists = {};     // name => { kind, entries: [{cidr, note}] }
var canEdit = false;
var editing = '';   // the name of the list open in the editor, '' for a new one

function node(tag, cls, text) {
  var e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;    // names and notes are the operator's: text only
  return e;
}

function fail(msg) {
  if (typeof mgShowWarning === 'function') mgShowWarning(msg, true);
}

function listSummary(l) {
  var n = (l.entries || []).length;
  return l.kind + ' list, ' + n + (n === 1 ? ' entry' : ' entries')
    + (l.updated_by ? ', last changed by ' + l.updated_by : '');
}

// The request for a list from what the editor holds: blank rows are dropped, the
// name is checked as the server checks it, and nothing is sent that the server
// would refuse by shape. Returns { ok, body } or { ok: false, error }.
function buildBody(name, kind, rows) {
  name = (name || '').replace(/^\s+|\s+$/g, '');
  if (!/^[a-z0-9_-]{1,64}$/.test(name)) {
    return { ok: false, error: 'A list name is 1 to 64 characters of a-z, 0-9, _ or -.' };
  }
  if (kind !== 'allow' && kind !== 'deny') return { ok: false, error: 'Choose allow or deny.' };
  var entries = [];
  var seen = {};
  for (var i = 0; i < rows.length; i++) {
    var cidr = (rows[i].cidr || '').replace(/^\s+|\s+$/g, '');
    var note = (rows[i].note || '').replace(/^\s+|\s+$/g, '');
    if (!cidr && !note) continue;
    if (!cidr) return { ok: false, error: 'An entry has a note and no address.' };
    if (seen[cidr]) return { ok: false, error: cidr + ' is listed twice.' };
    seen[cidr] = true;
    entries.push({ cidr: cidr, note: note });
  }
  return { ok: true, body: { name: name, kind: kind, entries: entries } };
}

function addRow(cidr, note) {
  var r = node('div', 'mg-row entry-row');
  var a = node('input', 'mg-inp entry-cidr');
  a.value = cidr || '';
  a.setAttribute('placeholder', 'address or CIDR range');
  a.setAttribute('aria-label', 'Address or CIDR range');
  var n = node('input', 'mg-inp entry-note');
  n.value = note || '';
  n.setAttribute('placeholder', 'note');
  n.setAttribute('aria-label', 'Note');
  var x = node('button', 'mg-btn mg-btn-sm mg-btn-danger', 'Remove');
  x.setAttribute('data-impact', 'destroy');
  x.addEventListener('click', function() { if (r.parentNode) r.parentNode.removeChild(r); });
  r.appendChild(a);
  r.appendChild(n);
  r.appendChild(x);
  document.getElementById('entry-rows').appendChild(r);
}

function editorRows() {
  return Array.prototype.map.call(document.querySelectorAll('#entry-rows .entry-row'), function(r) {
    return { cidr: r.querySelector('.entry-cidr').value, note: r.querySelector('.entry-note').value };
  });
}

function openEditor(name) {
  var l = name ? lists[name] : null;
  editing = l ? name : '';
  document.getElementById('editor').hidden = false;
  document.getElementById('editor-title').textContent = l ? 'Edit ' + name : 'New list';
  var nm = document.getElementById('list-name');
  nm.value = l ? name : '';
  nm.readOnly = !!l;
  document.getElementById('list-kind').value = l ? l.kind : 'allow';
  document.getElementById('entry-rows').textContent = '';
  ((l && l.entries) || []).forEach(function(e) { addRow(e.cidr, e.note); });
  if (!l) addRow('', '');
}

function renderLists(d) {
  var box = document.getElementById('lists');
  box.textContent = '';
  canEdit = !!d.can_edit;
  document.getElementById('new-btn').hidden = !canEdit;
  var rows = d.lists || [];
  lists = {};
  rows.forEach(function(l) { lists[l.name] = l; });
  if (!rows.length) { box.appendChild(node('div', 'mg-empty', 'There are no address lists.')); return; }
  rows.forEach(function(l) {
    var r = node('div', 'mg-row');
    r.appendChild(node('span', 'mg-row-name', l.name));
    r.appendChild(node('span', 'mg-row-meta', listSummary(l)));
    if (canEdit) {
      var acts = node('span', 'mg-row-actions');
      var e = node('button', 'mg-btn mg-btn-sm', 'Edit');
      e.setAttribute('data-impact', 'edit');
      e.addEventListener('click', function() { openEditor(l.name); });
      var x = node('button', 'mg-btn mg-btn-sm mg-btn-danger', 'Delete');
      x.setAttribute('data-impact', 'destroy');
      x.addEventListener('click', function() { deleteList(l.name); });
      acts.appendChild(e);
      acts.appendChild(x);
      r.appendChild(acts);
    }
    box.appendChild(r);
    (l.entries || []).forEach(function(en) {
      box.appendChild(node('div', 'mg-row-meta', en.cidr + (en.note ? ' - ' + en.note : '')));
    });
  });
}

function loadLists() {
  fetch(API + '?action=address-lists', { credentials: 'same-origin' })
    .then(function(res) { return res.json(); })
    .then(function(d) {
      if (!d.ok) {
        var box = document.getElementById('lists');
        box.textContent = '';
        box.appendChild(node('div', 'mg-empty', d.error || 'Could not list the address lists.'));
        return;
      }
      renderLists(d);
    })
    .catch(function(e) { fail('Could not list the address lists: ' + e.message); });
}

function saveList() {
  var b = buildBody(document.getElementById('list-name').value,
    document.getElementById('list-kind').value, editorRows());
  if (!b.ok) { fail(b.error); return; }
  if (!editing && lists[b.body.name] && !confirm('A list called ' + b.body.name + ' exists. Replace it?')) return;
  fetch(API + '?action=address-list-set', {
    method: 'POST', credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(b.body)
  })
    .then(function(res) { return res.json(); })
    .then(function(d) {
      if (!d.ok) { fail(d.error || 'The list was not saved.'); return; }
      if (typeof mgClearWarning === 'function') mgClearWarning();
      document.getElementById('editor').hidden = true;
      editing = '';
      loadLists();
    })
    .catch(function(e) { fail('The list was not saved: ' + e.message); });
}

var inUse = '';     // the list the server refused to delete because a rule names it

function deleteList(name) {
  if (!confirm('Delete the address list ' + name + '? A rule that names it will find no such list.')) return;
  sendDelete(name, false);
}

// The server's in-use refusal says where the list is named. Only the operator
// (canEdit) is offered the way past it; the server holds force to the operator too.
function showInUse(name, error) {
  inUse = name;
  document.getElementById('in-use-text').textContent = error;
  document.getElementById('in-use').hidden = !canEdit;
}

function hideInUse() {
  inUse = '';
  document.getElementById('in-use').hidden = true;
}

function forceDelete() {
  var name = inUse;
  if (!name) return;
  if (!confirm('Delete ' + name + ' anyway? An allow rule that still names it will admit nobody, '
    + 'so what it guards closes to every address.')) return;
  sendDelete(name, true);
}

function sendDelete(name, force) {
  var body = { name: name };
  if (force) body.force = true;
  fetch(API + '?action=address-list-delete', {
    method: 'POST', credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  })
    .then(function(res) { return res.json(); })
    .then(function(d) {
      if (!d.ok && d.kind === 'in-use' && !force) { showInUse(name, d.error || 'The list is still in use.'); return; }
      if (!d.ok) { fail(d.error || 'The list was not deleted.'); return; }
      hideInUse();
      if (editing === name) { editing = ''; document.getElementById('editor').hidden = true; }
      loadLists();
    })
    .catch(function(e) { fail('The list was not deleted: ' + e.message); });
}

document.getElementById('new-btn').addEventListener('click', function() { openEditor(''); });
document.getElementById('add-entry-btn').addEventListener('click', function() { addRow('', ''); });
document.getElementById('save-btn').addEventListener('click', saveList);
document.getElementById('cancel-btn').addEventListener('click', function() {
  editing = '';
  document.getElementById('editor').hidden = true;
});

loadLists();
</script>
