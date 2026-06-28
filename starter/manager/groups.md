---
title: Groups
auth: manager
search: false
---

<div id="status" class="mg-status"></div>

<div class="mg-domain-note">
A <b>group</b> (<code>@name</code>) is a set of accounts, shared by both access
domains - <b>file management</b> (manager UI / control API / connectors) and
<b>site access</b> (visitor / member login). A group is defined by its membership,
so it needs at least one member. Assign a specific user to groups from the
<a href="/manager/users">Users</a> page, or tick members here.
</div>

<div class="mg-card">
<div class="mg-card-header"><span class="mg-card-title">Groups</span></div>
<div id="groups-info" class="mg-acc-list">Loading...</div>
<details class="mg-add-card" style="margin:0.5rem;">
<summary>+ Add group</summary>
<div class="mg-card-body mg-new-group-row">
<input type="text" id="new-group-name" placeholder="new group name">
<select id="new-group-member" class="mg-inp"><option value="">first member&hellip;</option></select>
<button class="mg-btn mg-btn-primary" onclick="createGroup()">Add group</button>
</div>
</details>
</div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';
var allGroups = {};   // {group: [members]}
var allUsers  = [];   // [username]

function showStatus(msg, isError) {
  if (!msg) return;
  if (typeof mgToast === 'function') { mgToast(msg, isError ? 'error' : 'success'); return; }
  var el = document.getElementById('status');
  if (el) { el.textContent = msg; el.className = 'mg-status' + (isError ? ' mg-status-error' : ' mg-status-success'); }
}

function escHtml(s) {
  return (s == null ? '' : String(s))
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function apiCall(body) {
  return fetch(API + '?action=users', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  }).then(function(r) { return r.json(); });
}

function loadGroups() {
  var gp = apiCall({ action: 'groups' })
    .then(function(d) { return (d.ok && d.groups) ? d.groups : {}; })
    .catch(function() { return {}; });
  var up = apiCall({ action: 'list' })
    .then(function(d) { return (d.ok && d.users) ? d.users : []; })
    .catch(function() { return []; });
  Promise.all([gp, up]).then(function(res) {
    allGroups = res[0] || {};
    allUsers  = res[1] || [];
    renderGroups();
    populateNewGroupMember();
  }).catch(function(e) { showStatus('Failed to load groups: ' + e.message, true); });
}

// One accordion per group; members as checkboxes (tick to add/remove).
function renderGroups() {
  var el = document.getElementById('groups-info');
  var keys = Object.keys(allGroups).sort();
  if (!keys.length) { el.innerHTML = '<div class="mg-empty" style="padding:0.75rem;">No groups defined.</div>'; return; }
  el.innerHTML = keys.map(function(g) {
    var members = Array.isArray(allGroups[g]) ? allGroups[g] : [];
    var ge = escHtml(g);
    var h = '<details class="mg-acc"><summary><span class="mg-acc-name">' + ge + '</span>' +
            '<span class="mg-acc-tags">' + members.length + ' member' + (members.length === 1 ? '' : 's') + '</span></summary>';
    h += '<div class="mg-acc-body"><div class="mg-sec">Members</div><div class="mg-checks">';
    var roster = allUsers.length ? allUsers : members;
    h += roster.map(function(u) {
      var on = members.indexOf(u) !== -1;
      return '<label class="mg-chk"><input type="checkbox"' + (on ? ' checked' : '') +
        ' onchange="toggleGroup(\'' + escHtml(u) + '\',\'' + ge + '\',this)"> ' + escHtml(u) + '</label>';
    }).join('');
    h += '</div><div class="mg-line"><button class="mg-btn mg-btn-sm mg-btn-danger" onclick="deleteGroup(\'' + ge + '\')">Delete group</button></div>';
    h += '</div></details>';
    return h;
  }).join('');
}

function toggleGroup(user, group, el) {
  var checked = el.checked;
  var act = checked ? 'group-add' : 'group-remove';
  apiCall({ action: act, username: user, group: group })
    .then(function(d) {
      if (!d.ok) { el.checked = !checked; showStatus(d.error, true); return; }
      var m = Array.isArray(allGroups[group]) ? allGroups[group] : (allGroups[group] = []);
      var idx = m.indexOf(user);
      if (checked && idx === -1) m.push(user);
      if (!checked && idx !== -1) m.splice(idx, 1);
      showStatus((checked ? 'Added ' : 'Removed ') + user + (checked ? ' to ' : ' from ') + group + '.');
    })
    .catch(function(e) { el.checked = !checked; showStatus('Error: ' + e.message, true); });
}

function populateNewGroupMember() {
  var sel = document.getElementById('new-group-member');
  if (!sel) return;
  var cur = sel.value;
  sel.innerHTML = '<option value="">first member&hellip;</option>' +
    allUsers.map(function(u) { return '<option value="' + escHtml(u) + '">' + escHtml(u) + '</option>'; }).join('');
  sel.value = cur;
}

function createGroup() {
  var ni = document.getElementById('new-group-name');
  var mi = document.getElementById('new-group-member');
  var group = (ni.value || '').trim();
  var member = (mi.value || '').trim();
  if (!group) { showStatus('Group name required.', true); return; }
  if (!member) { showStatus('A first member is required (groups are defined by membership).', true); return; }
  apiCall({ action: 'group-add', username: member, group: group })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error, true); return; }
      showStatus('Group "' + group + '" created with member "' + member + '".');
      ni.value = ''; mi.value = '';
      loadGroups();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

function deleteGroup(group) {
  var members = Array.isArray(allGroups[group]) ? allGroups[group] : [];
  mgConfirm('Delete group "' + group + '"?' + (members.length ? ' Removes ' + members.length + ' member(s).' : ''), { danger: true, ok: 'Delete' }).then(function(__ok) {
    if (!__ok) return;
    if (!members.length) { showStatus('Group "' + group + '" already empty.'); loadGroups(); return; }
    var chain = Promise.resolve();
    members.slice().forEach(function(m) { chain = chain.then(function() { return apiCall({ action: 'group-remove', username: m, group: group }); }); });
    chain.then(function() { showStatus('Group "' + group + '" deleted.'); loadGroups(); })
         .catch(function(e) { showStatus('Error: ' + e.message, true); loadGroups(); });
  });
}

loadGroups();
</script>
