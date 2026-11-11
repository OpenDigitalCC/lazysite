---
title: Address profiles
auth: manager
search: false
---

<div id="status" class="mg-status"></div>
<div class="mg-note mg-note-warn" id="proxy-warning" hidden></div>

<!-- SM1138 (slice A of SM1134, ruled 2026-10-17), SM1343 (0.16.5): named sets of
     addresses. A profile has no kind: each rule that names one allows or denies it.
     This page keeps the profiles; a page, a folder, a group, the manager and sign-in
     apply them. Reading is manage_users; changing is the operator's
     (Manager::AddressProfiles), so a viewer who is not the operator is shown the
     profiles and no controls. -->
<div class="mg-note mg-note-info">An address profile is a named set of addresses and CIDR ranges (IPv4 or IPv6). It neither allows nor denies by itself: each rule that names a profile chooses <strong>Allow</strong> or <strong>Deny</strong>, so one profile can let an office in on one page and keep it out of another. Where an address is in a profile allowed and one denied, <strong>deny wins</strong>. Only the operator changes the profiles.</div>

<div class="mg-card">
<div class="mg-card-header"><span class="mg-card-title">Profiles</span></div>
<div class="mg-card-body">
<div class="mg-list" id="profiles"><div class="mg-empty">Loading...</div></div>
<div class="mg-toolbar"><button class="mg-btn mg-btn-primary" id="new-btn" data-impact="commit" hidden>New profile</button></div>
<!-- SM1141, ruling 234: a profile a rule still names cannot be deleted; the refusal
     says where it is named, and there is no way past it. It may be changed. -->
<div class="mg-note mg-note-warn" id="in-use" hidden>
<p id="in-use-text"></p>
<div class="mg-toolbar">
<button class="mg-btn" id="keep-btn" data-impact="inert" onclick="hideInUse()">Close</button>
</div>
</div>
</div>
</div>

<div class="mg-card" id="editor" hidden>
<div class="mg-card-header"><span class="mg-card-title" id="editor-title">New profile</span></div>
<div class="mg-card-body">
<label class="mg-field"><span>Name (a-z, 0-9, _ and -)</span><input class="mg-inp" id="profile-name" maxlength="64" autocomplete="off"></label>
<div class="mg-list" id="entry-rows"></div>
<div class="mg-toolbar">
<button class="mg-btn" id="add-entry-btn" data-impact="edit">Add entry</button>
<button class="mg-btn mg-btn-primary" id="save-btn" data-impact="commit">Save profile</button>
<button class="mg-btn" id="cancel-btn" data-impact="inert">Cancel</button>
</div>
<p class="mg-muted">An entry is one address (203.0.113.7, 2001:db8::1) or a range (203.0.113.0/24, 2001:db8::/32). A range of every address is refused. An IPv4-mapped IPv6 address (::ffff:203.0.113.7) is an IPv6 address, matched only by an IPv6 entry.</p>
</div>
</div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';
var profiles = {};  // name => { entries: [{cidr, note}] }
var canEdit = false;
var editing = '';   // the name of the profile open in the editor, '' for a new one

function node(tag, cls, text) {
  var e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;    // names and notes are the operator's: text only
  return e;
}

// SM1192 (test plan 0.15.10, F-1): the server decides whether every visitor reaches
// this site as the front proxy (proxy_warning); this only shows its sentence, as
// text, where address rules are edited.
function showProxyWarning(msg) {
  var el = document.getElementById('proxy-warning');
  if (!el) return;
  el.textContent = msg || '';
  el.hidden = !msg;
}

function fail(msg) {
  if (typeof mgShowWarning === 'function') mgShowWarning(msg, true);
}

function profileSummary(l) {
  var n = (l.entries || []).length;
  return n + (n === 1 ? ' entry' : ' entries')
    + (l.updated_by ? ', last changed by ' + l.updated_by : '');
}

// The request for a profile from what the editor holds: blank rows are dropped, the
// name is checked as the server checks it, and nothing is sent that the server
// would refuse by shape (a profile has no kind, so none is sent). Returns
// { ok, body } or { ok: false, error }.
function buildBody(name, rows) {
  name = (name || '').replace(/^\s+|\s+$/g, '');
  if (!/^[a-z0-9_-]{1,64}$/.test(name)) {
    return { ok: false, error: 'A profile name is 1 to 64 characters of a-z, 0-9, _ or -.' };
  }
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
  return { ok: true, body: { name: name, entries: entries } };
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
  var l = name ? profiles[name] : null;
  editing = l ? name : '';
  document.getElementById('editor').hidden = false;
  document.getElementById('editor-title').textContent = l ? 'Edit ' + name : 'New profile';
  var nm = document.getElementById('profile-name');
  nm.value = l ? name : '';
  nm.readOnly = !!l;
  document.getElementById('entry-rows').textContent = '';
  ((l && l.entries) || []).forEach(function(e) { addRow(e.cidr, e.note); });
  if (!l) addRow('', '');
}

function renderProfiles(d) {
  var box = document.getElementById('profiles');
  box.textContent = '';
  canEdit = !!d.can_edit;
  document.getElementById('new-btn').hidden = !canEdit;
  var rows = d.profiles || [];
  profiles = {};
  rows.forEach(function(l) { profiles[l.name] = l; });
  if (!rows.length) { box.appendChild(node('div', 'mg-empty', 'There are no address profiles.')); return; }
  rows.forEach(function(l) {
    var r = node('div', 'mg-row');
    r.appendChild(node('span', 'mg-row-name', l.name));
    r.appendChild(node('span', 'mg-row-meta', profileSummary(l)));
    if (canEdit) {
      var acts = node('span', 'mg-row-actions');
      var e = node('button', 'mg-btn mg-btn-sm', 'Edit');
      e.setAttribute('data-impact', 'edit');
      e.addEventListener('click', function() { openEditor(l.name); });
      var x = node('button', 'mg-btn mg-btn-sm mg-btn-danger', 'Delete');
      x.setAttribute('data-impact', 'destroy');
      x.addEventListener('click', function() { deleteProfile(l.name); });
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

function loadProfiles() {
  fetch(API + '?action=address-profiles', { credentials: 'same-origin' })
    .then(function(res) { return res.json(); })
    .then(function(d) {
      if (!d.ok) {
        var box = document.getElementById('profiles');
        box.textContent = '';
        box.appendChild(node('div', 'mg-empty', d.error || 'Could not list the address profiles.'));
        return;
      }
      showProxyWarning(d.proxy_warning);
      renderProfiles(d);
    })
    .catch(function(e) { fail('Could not list the address profiles: ' + e.message); });
}

function saveProfile() {
  var b = buildBody(document.getElementById('profile-name').value, editorRows());
  if (!b.ok) { fail(b.error); return; }
  if (!editing && profiles[b.body.name] && !confirm('A profile called ' + b.body.name + ' exists. Replace it?')) return;
  fetch(API + '?action=address-profile-set', {
    method: 'POST', credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(b.body)
  })
    .then(function(res) { return res.json(); })
    .then(function(d) {
      if (!d.ok) { fail(d.error || 'The profile was not saved.'); return; }
      if (typeof mgClearWarning === 'function') mgClearWarning();
      document.getElementById('editor').hidden = true;
      editing = '';
      loadProfiles();
    })
    .catch(function(e) { fail('The profile was not saved: ' + e.message); });
}

var inUse = '';     // the profile the server refused to delete because a rule names it

function deleteProfile(name) {
  if (!confirm('Delete the address profile ' + name + '? A profile a rule names cannot be deleted.')) return;
  sendDelete(name);
}

// The server's in-use refusal says where the profile is named. There is no way
// past it (ruling 234): remove the profile from those rules first.
function showInUse(name, error) {
  inUse = name;
  document.getElementById('in-use-text').textContent = error;
  document.getElementById('in-use').hidden = false;
}

function hideInUse() {
  inUse = '';
  document.getElementById('in-use').hidden = true;
}

function sendDelete(name) {
  var body = { name: name };
  fetch(API + '?action=address-profile-delete', {
    method: 'POST', credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  })
    .then(function(res) { return res.json(); })
    .then(function(d) {
      if (!d.ok && d.kind === 'in-use') { showInUse(name, d.error || 'The profile is still in use.'); return; }
      if (!d.ok) { fail(d.error || 'The profile was not deleted.'); return; }
      hideInUse();
      if (editing === name) { editing = ''; document.getElementById('editor').hidden = true; }
      loadProfiles();
    })
    .catch(function(e) { fail('The profile was not deleted: ' + e.message); });
}

document.getElementById('new-btn').addEventListener('click', function() { openEditor(''); });
document.getElementById('add-entry-btn').addEventListener('click', function() { addRow('', ''); });
document.getElementById('save-btn').addEventListener('click', saveProfile);
document.getElementById('cancel-btn').addEventListener('click', function() {
  editing = '';
  document.getElementById('editor').hidden = true;
});

loadProfiles();
</script>
