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
</div>

<script>
var API = '/cgi-bin/lazysite-editor-api.pl';

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
    html += '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="removeUser(\'' + escHtml(u) + '\')">Remove</button>';
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
  var html = '<table class="mg-table"><thead><tr><th>Group</th><th>Members</th></tr></thead><tbody>';
  keys.sort().forEach(function(g) {
    var members = Array.isArray(groups[g]) ? groups[g] : [];
    html += '<tr><td><strong>' + escHtml(g) + '</strong></td><td>' + members.map(escHtml).join(', ') + '</td></tr>';
  });
  html += '</tbody></table>';
  el.innerHTML = html;
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

function removeUser(username) {
  if (!confirm('Remove user "' + username + '"? This cannot be undone.')) return;
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
