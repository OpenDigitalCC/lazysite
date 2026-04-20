---
title: User Management
auth: manager
search: false
---

<div id="status" class="mg-status"></div>

<div class="mg-card">
<div class="mg-card-header">
<span class="mg-card-title">Add User</span>
</div>
<div class="mg-card-body">
<div class="mg-form-row">
<label>Username</label>
<input type="text" id="new-username" placeholder="username">
</div>
<div class="mg-form-row">
<label>Password</label>
<input type="password" id="new-password" placeholder="password">
</div>
<div class="mg-form-row">
<label>Groups</label>
<input type="text" id="new-groups" placeholder="editor, admin (comma-separated)">
</div>
<div class="mg-form-row">
<label></label>
<button class="mg-btn mg-btn-outline" onclick="addUser()">Add User</button>
</div>
</div>
</div>

<div class="mg-card">
<div class="mg-card-header">
<span class="mg-card-title">Users</span>
</div>
<div id="user-list">
<div class="mg-file-item"><span class="mg-file-name">Loading...</span></div>
</div>
</div>

<div class="mg-card">
<div class="mg-card-header">
<span class="mg-card-title">Groups</span>
</div>
<div class="mg-card-body" id="groups-info">Loading...</div>
<div class="mg-card-body mg-new-group-row">
<label for="new-group-name">New group name:</label>
<input type="text" id="new-group-name" placeholder="group name">
<button class="mg-btn mg-btn-outline" onclick="createGroup()">Create</button>
</div>
</div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';

function showStatus(msg, isError) {
  var el = document.getElementById('status');
  el.className = 'mg-status' + (isError ? ' mg-status-error' : ' mg-status-success');
  el.textContent = msg;
  if (!isError) setTimeout(function() { el.textContent = ''; el.className = 'mg-status'; }, 3000);
}

function escHtml(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function apiCall(body) {
  return fetch(API + '?action=users', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body)
  }).then(function(r) { return r.json(); });
}

function loadUsers() {
  apiCall({ action: 'list' })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      renderUsers(data.users || []);
    })
    .catch(function(e) { showStatus('Failed to load users: ' + e.message, true); });
  apiCall({ action: 'groups' })
    .then(function(data) {
      if (!data.ok) return;
      renderGroups(data.groups || {});
    });
}

function renderUsers(users) {
  var list = document.getElementById('user-list');
  if (users.length === 0) {
    list.innerHTML = '<div class="mg-file-item"><span class="mg-file-name mg-empty">No users</span></div>';
    return;
  }
  var html = '';
  for (var i = 0; i < users.length; i++) {
    var u = users[i];
    html += '<div class="mg-file-item">';
    html += '<span class="mg-file-name">' + escHtml(u) + '</span>';
    html += '<div class="mg-file-actions">';
    html += '<button class="mg-btn mg-btn-sm" onclick="changePassword(\'' + escHtml(u) + '\')">Password</button>';
    html += '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="deleteUser(\'' + escHtml(u) + '\')">Delete</button>';
    html += '</div>';
    html += '</div>';
  }
  list.innerHTML = html;
}

function renderGroups(groups) {
  var el = document.getElementById('groups-info');
  var keys = Object.keys(groups);
  if (keys.length === 0) {
    el.innerHTML = '<span class="mg-empty">No groups defined.</span>';
    return;
  }
  var html = '<table class="mg-table"><thead><tr><th>Group</th><th>Members</th><th>Actions</th></tr></thead><tbody>';
  keys.sort().forEach(function(g) {
    var members = Array.isArray(groups[g]) ? groups[g] : [];
    var memberHtml = members.map(function(m) {
      return '<span class="mg-group-member">' + escHtml(m) +
        ' <button class="mg-chip-remove" title="Remove ' + escHtml(m) + ' from ' + escHtml(g) + '" ' +
        'onclick="removeGroupMember(\'' + escHtml(m) + '\',\'' + escHtml(g) + '\')">&times;</button></span>';
    }).join(' ');
    html += '<tr data-group="' + escHtml(g) + '">';
    html += '<td><strong>' + escHtml(g) + '</strong></td>';
    html += '<td>' + (memberHtml || '<span class="mg-empty">&mdash;</span>') + '</td>';
    html += '<td class="mg-group-actions">';
    html += '<button class="mg-btn mg-btn-sm" onclick="showAddMember(\'' + escHtml(g) + '\')">Add user</button> ';
    html += '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="deleteGroup(\'' + escHtml(g) + '\')">Delete</button>';
    html += '</td>';
    html += '</tr>';
    html += '<tr class="mg-add-member-row" data-add-for="' + escHtml(g) + '" style="display:none">';
    html += '<td colspan="3">';
    html += '<input type="text" class="mg-add-member-input" placeholder="username" ' +
      'onkeydown="if(event.key===\'Enter\')confirmAddMember(\'' + escHtml(g) + '\')"> ';
    html += '<button class="mg-btn mg-btn-sm mg-btn-outline" onclick="confirmAddMember(\'' + escHtml(g) + '\')">Confirm</button> ';
    html += '<button class="mg-btn mg-btn-sm" onclick="hideAddMember(\'' + escHtml(g) + '\')">Cancel</button>';
    html += '</td></tr>';
  });
  html += '</tbody></table>';
  el.innerHTML = html;
}

function showAddMember(group) {
  var row = document.querySelector('tr.mg-add-member-row[data-add-for="' + group + '"]');
  if (!row) return;
  row.style.display = '';
  var input = row.querySelector('input');
  if (input) { input.value = ''; input.focus(); }
}

function hideAddMember(group) {
  var row = document.querySelector('tr.mg-add-member-row[data-add-for="' + group + '"]');
  if (row) row.style.display = 'none';
}

function confirmAddMember(group) {
  var row = document.querySelector('tr.mg-add-member-row[data-add-for="' + group + '"]');
  if (!row) return;
  var input = row.querySelector('input');
  var username = (input.value || '').trim();
  if (!username) { showStatus('Username required.', true); return; }
  apiCall({ action: 'group-add', username: username, group: group })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      showStatus('Added "' + username + '" to "' + group + '".');
      loadUsers();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

function removeGroupMember(username, group) {
  if (!confirm('Remove "' + username + '" from group "' + group + '"?')) return;
  apiCall({ action: 'group-remove', username: username, group: group })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      showStatus('Removed "' + username + '" from "' + group + '".');
      loadUsers();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

function deleteGroup(group) {
  apiCall({ action: 'groups' }).then(function(data) {
    if (!data.ok) { showStatus(data.error, true); return; }
    var members = (data.groups && Array.isArray(data.groups[group])) ? data.groups[group] : [];
    var prompt = members.length
      ? 'Delete group "' + group + '"? This will remove ' + members.length + ' member' +
        (members.length === 1 ? '' : 's') + ' from it.'
      : 'Delete group "' + group + '"?';
    if (!confirm(prompt)) return;
    if (!members.length) { showStatus('Group "' + group + '" already empty.', false); loadUsers(); return; }
    removeGroupMembersSequential(members, group, 0);
  });
}

function removeGroupMembersSequential(members, group, i) {
  if (i >= members.length) {
    showStatus('Group "' + group + '" deleted.');
    loadUsers();
    return;
  }
  var username = members[i];
  apiCall({ action: 'group-remove', username: username, group: group })
    .then(function(r) {
      if (!r.ok) {
        showStatus('Failed removing ' + username + ' from "' + group + '": ' + r.error, true);
        loadUsers();
        return;
      }
      removeGroupMembersSequential(members, group, i + 1);
    })
    .catch(function(e) {
      showStatus('Error removing ' + username + ' from "' + group + '": ' + e.message, true);
      loadUsers();
    });
}

function createGroup() {
  var input = document.getElementById('new-group-name');
  var group = (input.value || '').trim();
  if (!group) { showStatus('Group name required.', true); return; }
  var username = prompt('First member username for group "' + group + '":');
  if (!username) return;
  username = username.trim();
  if (!username) return;
  apiCall({ action: 'group-add', username: username, group: group })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      showStatus('Group "' + group + '" created with member "' + username + '".');
      input.value = '';
      loadUsers();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

function addUser() {
  var username = document.getElementById('new-username').value.trim();
  var password = document.getElementById('new-password').value;
  var groups = document.getElementById('new-groups').value.trim();
  if (!username || !password) { showStatus('Username and password required.', true); return; }

  apiCall({ action: 'add', username: username, password: password })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      showStatus('User "' + username + '" added.');
      document.getElementById('new-username').value = '';
      document.getElementById('new-password').value = '';
      document.getElementById('new-groups').value = '';
      loadUsers();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

function changePassword(username) {
  var pw = prompt('New password for "' + username + '":');
  if (!pw) return;
  apiCall({ action: 'passwd', username: username, password: pw })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      showStatus('Password updated for "' + username + '".');
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

function deleteUser(username) {
  if (!confirm('Delete user "' + username + '"? This cannot be undone.')) return;
  apiCall({ action: 'remove', username: username })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      showStatus('User "' + username + '" removed.');
      loadUsers();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

loadUsers();
</script>

<style>
.mg-group-member {
  display: inline-block;
  padding: 0.125rem 0.375rem;
  margin: 0.125rem 0.25rem 0.125rem 0;
  background: var(--mg-bg-muted, #f0f0f0);
  border-radius: 3px;
  font-size: 0.875rem;
}
.mg-chip-remove {
  border: none;
  background: transparent;
  color: var(--mg-text-muted, #888);
  cursor: pointer;
  padding: 0 0.125rem;
  font-size: 1rem;
  line-height: 1;
}
.mg-chip-remove:hover { color: var(--mg-danger, #c00); }
.mg-group-actions { white-space: nowrap; }
.mg-add-member-row td { background: var(--mg-bg-muted, #fafafa); }
.mg-new-group-row {
  display: flex;
  align-items: center;
  gap: 0.5rem;
  border-top: 1px solid var(--mg-border, #e5e5e5);
}
</style>
