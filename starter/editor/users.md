---
title: User Management
auth: admin
search: false
---

<div>
<style>
.users-wrap { font-family: system-ui, sans-serif; max-width: 700px; margin: 0 auto; }
.editor-nav { margin-bottom: 16px; }
.editor-nav a { margin-right: 16px; color: #07c; text-decoration: none; font-size: 14px; }
.editor-nav a:hover { text-decoration: underline; }
.editor-nav a.active { font-weight: 600; color: #333; border-bottom: 2px solid #07c; }
.section { border: 1px solid #ccc; border-radius: 4px; padding: 12px; margin-bottom: 16px; background: #f8f8f8; }
.section h3 { margin: 0 0 10px 0; font-size: 15px; }
.form-row { display: flex; gap: 8px; margin-bottom: 8px; align-items: center; }
.form-row label { width: 80px; font-size: 13px; text-align: right; flex-shrink: 0; }
.form-row input { flex: 1; padding: 4px 8px; font-size: 13px; }
.form-row button { padding: 4px 14px; cursor: pointer; }
.user-list { border: 1px solid #ccc; border-radius: 4px; margin-bottom: 16px; }
.user-item { display: flex; align-items: center; padding: 8px 12px; border-bottom: 1px solid #eee; gap: 8px; flex-wrap: wrap; }
.user-item:last-child { border-bottom: none; }
.user-item .username { font-weight: bold; flex: 1; min-width: 100px; }
.user-item .groups { font-size: 12px; color: #666; margin-right: 8px; }
.user-item button { padding: 2px 8px; font-size: 12px; cursor: pointer; }
.status-msg { padding: 6px 10px; margin-bottom: 8px; border-radius: 4px; font-size: 13px; }
.status-msg.error { background: #fee; color: #c00; }
.status-msg.ok { background: #efe; color: #060; }
</style>
</div>

<div class="users-wrap" id="app">

<nav class="editor-nav">
<a href="/editor/">Files</a>
<a href="/editor/themes">Themes</a>
<a href="/editor/users" class="active">Users</a>
<a href="/editor/cache">Cache</a>
</div>

<div id="status"></div>

<div class="section">
<h3>Add User</h3>
<div class="form-row">
<label>Username</label>
<input type="text" id="new-username" placeholder="username">
</div>
<div class="form-row">
<label>Password</label>
<input type="password" id="new-password" placeholder="password">
</div>
<div class="form-row">
<label>Groups</label>
<input type="text" id="new-groups" placeholder="editor, admin (comma-separated)">
</div>
<div class="form-row">
<label></label>
<button onclick="addUser()">Add User</button>
</div>
</div>

<h2 style="font-size:18px; margin-bottom:12px;">Users</h2>

<div class="user-list" id="user-list">
<div class="user-item"><span class="username">Loading...</span></div>
</div>

<div class="section">
<h3>Groups</h3>
<div id="groups-info" style="font-size:13px; color:#666;">Loading...</div>
</div>

</div>

<script>
var API = '/cgi-bin/lazysite-editor-api.pl';

function showStatus(msg, isError) {
  var el = document.getElementById('status');
  el.className = 'status-msg ' + (isError ? 'error' : 'ok');
  el.textContent = msg;
  if (!isError) setTimeout(function() { el.textContent = ''; el.className = ''; }, 3000);
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
    list.innerHTML = '<div class="user-item"><span class="username" style="color:#888;">No users</span></div>';
    return;
  }
  var html = '';
  for (var i = 0; i < users.length; i++) {
    var u = users[i];
    html += '<div class="user-item">';
    html += '<span class="username">' + escHtml(u) + '</span>';
    html += '<button onclick="changePassword(\'' + escHtml(u) + '\')">Password</button>';
    html += '<button onclick="removeUser(\'' + escHtml(u) + '\')">Remove</button>';
    html += '</div>';
  }
  list.innerHTML = html;
}

function renderGroups(groups) {
  var el = document.getElementById('groups-info');
  var keys = Object.keys(groups);
  if (keys.length === 0) {
    el.textContent = 'No groups defined.';
    return;
  }
  var html = '';
  keys.sort().forEach(function(g) {
    var members = Array.isArray(groups[g]) ? groups[g] : [];
    html += '<strong>' + escHtml(g) + ':</strong> ' + members.map(escHtml).join(', ') + '<br>';
  });
  el.innerHTML = html;
}

function addUser() {
  var username = document.getElementById('new-username').value.trim();
  var password = document.getElementById('new-password').value;
  var groups = document.getElementById('new-groups').value.trim();
  if (!username || !password) { showStatus('Username and password required.', true); return; }

  var groupList = groups ? groups.split(/\s*,\s*/).filter(Boolean) : [];

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

function manageGroups(username) {
  var groups = prompt('Set groups for "' + username + '" (comma-separated):');
  if (groups === null) return;
  var groupList = groups.split(/\s*,\s*/).filter(Boolean);
  apiCall({ action: 'group-add', username: username, group: groupList[0] })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      showStatus('Groups updated for "' + username + '".');
      loadUsers();
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
