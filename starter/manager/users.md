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
<span class="mg-card-title">Create sub-user</span>
</div>
<div class="mg-card-body">
<p class="mg-card-subtitle" style="margin:0 0 8px 0;">Creates an account owned by you (recorded as its parent). You need the "Sub-users" permission; partners typically get a token credential and an onboarding brief.</p>
<div class="mg-form-row">
<label>Username</label>
<input type="text" id="sub-username" placeholder="partner-name">
</div>
<div class="mg-form-row">
<label>Password</label>
<input type="password" id="sub-password" placeholder="password (or set a token credential after)">
</div>
<div class="mg-form-row">
<label></label>
<button class="mg-btn mg-btn-outline" onclick="createSubUser()">Create sub-user</button>
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
<button class="mg-btn mg-btn-outline" onclick="createGroup()">Add</button>
</div>
</div>

<div class="mg-card">
<div class="mg-card-header">
<span class="mg-card-title">Sessions</span>
</div>
<div class="mg-card-body">
<p class="mg-card-subtitle" style="margin:0 0 0.5rem">
Rotate the session-signing secret. Invalidates every signed cookie
currently in circulation, including your own. Everyone (including you)
will need to sign in again.
</p>
<button class="mg-btn mg-btn-danger" onclick="rotateAuthSecret()">Log out all users</button>
</div>
</div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';

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
      var users = data.users || [];
      // SM070: fetch each user's access-mechanism settings so the row
      // can show UI / WebDAV state and the scope.
      Promise.all(users.map(function(u) {
        return apiCall({ action: 'settings-get', username: u })
          .then(function(s) { return { user: u, settings: (s.ok ? s.settings : {}) }; })
          .catch(function() { return { user: u, settings: {} }; });
      })).then(renderUsers);
    })
    .catch(function(e) { showStatus('Failed to load users: ' + e.message, true); });
  apiCall({ action: 'groups' })
    .then(function(data) {
      if (!data.ok) return;
      renderGroups(data.groups || {});
    });
}

function renderUsers(rows) {
  var list = document.getElementById('user-list');
  if (rows.length === 0) {
    list.innerHTML = '<div class="mg-file-item"><span class="mg-file-name mg-empty">No users</span></div>';
    return;
  }
  var html = '';
  for (var i = 0; i < rows.length; i++) {
    var u = rows[i].user;
    var s = rows[i].settings || {};
    var ue = escHtml(u);
    var webdav = !!s.webdav;
    var ui = (s.ui === undefined || s.ui === null) ? true : !!s.ui;
    var scope = s.dav_scope || '';
    var disabled = !!s.disabled;

    var prov = '';
    if (s.created_by) {
      prov = 'created by ' + escHtml(s.created_by);
      if (s.managed_by && s.managed_by !== s.created_by) {
        prov += ', managed by ' + escHtml(s.managed_by);
      }
    }

    html += '<div class="mg-file-item mg-user-row">';
    html +=   '<span class="mg-file-name">' + ue +
              ( disabled ? ' <span style="color:#c33;font-size:0.75rem;">disabled</span>' : '' ) +
              '</span>';
    if (prov) html += '<span class="mg-file-meta">' + prov + '</span>';

    // Access mechanisms (SM070) + WebDAV scope.
    html += '<div class="mg-user-mech">';
    html += capBtn(ue, 'ui', ui, 'UI', 'Interactive (browser) login');
    html += capBtn(ue, 'webdav', webdav, 'WebDAV', 'WebDAV publishing access');
    html += '<input type="text" class="mg-scope-input" id="scope-' + ue + '" ' +
            'value="' + escHtml(scope) + '" placeholder="/path (WebDAV scope)">';
    html += '<button class="mg-btn mg-btn-sm" onclick="setUserScope(\'' + ue + '\')">Set scope</button>';
    html += '</div>';

    // Capabilities + sub-user permissions + account state (SM071).
    html += '<div class="mg-user-mech">';
    html += capBtn(ue, 'manage_themes',  !!s.manage_themes,  'Themes',    'Manage themes');
    html += capBtn(ue, 'manage_layouts', !!s.manage_layouts, 'Layouts',   'Manage layouts');
    html += capBtn(ue, 'manage_config',  !!s.manage_config,  'Config',    'Set allowlisted config');
    html += capBtn(ue, 'create_sub_users', !!s.create_sub_users, 'Sub-users', 'May create sub-users');
    html += capBtn(ue, 'delegate_sub_user_creation', !!s.delegate_sub_user_creation, 'Delegate', 'May pass on sub-user creation');
    html += '<button class="mg-btn mg-btn-sm mg-toggle ' + (disabled ? 'mg-off' : 'mg-on') + '" ' +
            'onclick="toggleDisabled(\'' + ue + '\',' + (disabled ? 'true' : 'false') + ')" ' +
            'title="Account enabled/disabled">' + (disabled ? 'Disabled' : 'Enabled') + '</button>';
    html += '</div>';

    html += '<div class="mg-file-actions">';
    html += '<button class="mg-btn mg-btn-sm" onclick="generateCredential(\'' + ue + '\')">Generate credential</button>';
    html += '<button class="mg-btn mg-btn-sm" onclick="downloadOnboarding(\'' + ue + '\')">Onboarding</button>';
    html += '<button class="mg-btn mg-btn-sm" onclick="reassignUser(\'' + ue + '\',\'' + escHtml(s.managed_by || s.created_by || '') + '\')">Reassign</button>';
    html += '<button class="mg-btn mg-btn-sm" onclick="changePassword(\'' + ue + '\')">Password</button>';
    html += '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="deleteUser(\'' + ue + '\')">Delete</button>';
    html += '</div>';
    html += '<div class="mg-cred-reveal" id="cred-' + ue + '" style="display:none"></div>';
    html += '</div>';
  }
  list.innerHTML = html;
}

// Render a settings-backed on/off toggle button (flips via settings-set).
function capBtn(user, key, on, label, title) {
  return '<button class="mg-btn mg-btn-sm mg-toggle ' + (on ? 'mg-on' : 'mg-off') + '" ' +
    'onclick="toggleSetting(\'' + user + '\',\'' + key + '\',' + (on ? 'true' : 'false') + ')" ' +
    'title="' + title + '">' + label + ': ' + (on ? 'on' : 'off') + '</button>';
}

// SM070: flip a per-user boolean mechanism (ui / webdav).
function toggleSetting(user, key, current) {
  var val = current ? 'off' : 'on';
  apiCall({ action: 'settings-set', username: user, key: key, value: val })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      showStatus(key + ' set ' + val + ' for "' + user + '".');
      loadUsers();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

// SM070: set or clear a user's WebDAV path scope.
function setUserScope(user) {
  var input = document.getElementById('scope-' + user);
  var val = ((input && input.value) || '').trim();
  apiCall({ action: 'settings-set', username: user, key: 'dav_scope', value: val })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      showStatus(val ? ('Scope set to ' + val + ' for "' + user + '".')
                     : ('Scope cleared for "' + user + '".'));
      loadUsers();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

// SM070: generate a strong credential and reveal it once in place. The
// row is NOT reloaded afterwards, so the one-time value stays visible
// until the operator navigates away or reloads.
function generateCredential(user) {
  if (!confirm('Generate a new credential for "' + user + '"? Any existing ' +
               'password or credential for this account will stop working.')) return;
  apiCall({ action: 'token', username: user })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      var panel = document.getElementById('cred-' + user);
      if (panel) {
        panel.style.display = '';
        panel.innerHTML =
          '<strong>Credential (shown once — store it now):</strong> ' +
          '<code class="mg-cred-value">' + escHtml(data.token) + '</code> ' +
          '<button class="mg-btn mg-btn-sm" onclick="copyCred(\'' + escHtml(user) + '\')">Copy</button>';
      }
      showStatus('Credential generated for "' + user + '".');
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

function copyCred(user) {
  var panel = document.getElementById('cred-' + user);
  var code = panel && panel.querySelector('.mg-cred-value');
  if (code && navigator.clipboard) {
    navigator.clipboard.writeText(code.textContent)
      .then(function() { showStatus('Credential copied to clipboard.'); });
  }
}

// SM071: enable/disable an account (ancestry-authorised server-side).
function toggleDisabled(user, disabled) {
  if (!disabled && !confirm('Disable "' + user + '"? They will be unable ' +
      'to authenticate anywhere until re-enabled.')) return;
  var act = disabled ? 'account-enable' : 'account-disable';
  apiCall({ action: act, username: user })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      showStatus((disabled ? 'Enabled' : 'Disabled') + ' "' + user + '".');
      loadUsers();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

// SM071: reassign an account to a new parent (managed_by). Server enforces
// that the actor is an ancestor of the account being moved.
function reassignUser(user, current) {
  var to = prompt('Reassign "' + user + '" to which parent account?', current || '');
  if (!to) return;
  apiCall({ action: 'account-reassign', username: user, to: to })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      showStatus('Reassigned "' + user + '" to "' + to + '".');
      loadUsers();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

// SM071: download a fresh onboarding brief (with a one-time pairing key)
// for an automated partner.
function downloadOnboarding(user) {
  apiCall({ action: 'onboarding', username: user })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      var blob = new Blob([data.onboarding], { type: 'text/markdown' });
      var a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = 'automated-partner-' + user + '.md';
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      URL.revokeObjectURL(a.href);
      showStatus('Onboarding brief for "' + user + '" downloaded ' +
                 '(contains a single-use pairing key).');
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

// SM071: create a sub-user owned by the current manager (account-create;
// the server records created_by/managed_by and enforces create_sub_users).
function createSubUser() {
  var u = (document.getElementById('sub-username').value || '').trim();
  var p = (document.getElementById('sub-password').value || '').trim();
  if (!u || !p) { showStatus('Sub-user username and password required.', true); return; }
  apiCall({ action: 'account-create', username: u, password: p })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error, true); return; }
      showStatus('Sub-user "' + u + '" created.');
      document.getElementById('sub-username').value = '';
      document.getElementById('sub-password').value = '';
      loadUsers();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
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
        'onclick="deleteGroupMember(\'' + escHtml(m) + '\',\'' + escHtml(g) + '\')">&times;</button></span>';
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

function deleteGroupMember(username, group) {
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
    deleteGroupMembersSequential(members, group, 0);
  });
}

function deleteGroupMembersSequential(members, group, i) {
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
      deleteGroupMembersSequential(members, group, i + 1);
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

// Rotate the server-side HMAC secret. Every outstanding signed
// cookie (including ours) becomes invalid on the next request, so
// we redirect straight to /login after success rather than leaving
// the user on a page that now has no valid session.
function rotateAuthSecret() {
  if (!confirm(
    'This will sign every user (including you) out immediately. ' +
    'Every cookie currently in circulation will stop working. ' +
    'Proceed?'
  )) return;

  fetch(API + '?action=rotate-auth-secret', { method: 'POST' })
    .then(function(r) { return r.json(); })
    .then(function(data) {
      if (!data.ok) { showStatus(data.error || 'Rotation failed', true); return; }
      // Our own session is dead now; send us to /login. The next
      // request would be rejected with 401 anyway; going to /login
      // directly is the cleanest UX.
      mgShowWarning(data.message || 'All sessions invalidated.', false);
      setTimeout(function() { location.href = '/login'; }, 1200);
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
/* SM070: per-user access-mechanism controls */
.mg-user-row { flex-wrap: wrap; }
.mg-user-mech {
  display: flex;
  align-items: center;
  gap: 0.375rem;
  flex-wrap: wrap;
  margin: 0 0.5rem;
}
.mg-toggle.mg-on  { border-color: var(--mg-success, #2a7); color: var(--mg-success, #2a7); }
.mg-toggle.mg-off { color: var(--mg-text-muted, #888); }
.mg-scope-input {
  width: 11rem;
  font-size: 0.8125rem;
  padding: 0.1875rem 0.375rem;
}
.mg-cred-reveal {
  flex-basis: 100%;
  margin-top: 0.375rem;
  padding: 0.375rem 0.5rem;
  background: var(--mg-bg-muted, #f6f6f6);
  border-radius: 3px;
  font-size: 0.875rem;
}
.mg-cred-value {
  font-family: monospace;
  word-break: break-all;
  background: var(--mg-bg, #fff);
  padding: 0.125rem 0.25rem;
  border-radius: 2px;
}
</style>
