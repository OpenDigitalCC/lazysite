---
title: User Management
auth: manager
search: false
---

<div id="status" class="mg-status"></div>

<details class="mg-add-card">
<summary>+ Add user</summary>
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
<button class="mg-btn mg-btn-outline" onclick="addUser()">Add user</button>
</div>
</div>
</details>

<details class="mg-add-card">
<summary>+ Create sub-user / partner</summary>
<div class="mg-card-body">
<p class="mg-card-subtitle" style="margin:0 0 8px 0;">Creates an account owned by you (recorded as its parent). You need the "Sub-users" capability. For an automated partner, create it here, enable WebDAV, then use the credential + onboarding brief in its row below.</p>
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
</details>

<div class="mg-card">
<div class="mg-card-header">
<span class="mg-card-title">Users</span>
</div>
<div id="user-list" class="mg-acc-list">
<div class="mg-empty" style="padding:0.75rem;">Loading...</div>
</div>
</div>

<div class="mg-card">
<div class="mg-card-header">
<span class="mg-card-title">Groups</span>
</div>
<div id="groups-info" class="mg-acc-list">Loading...</div>
<div class="mg-card-body mg-new-group-row">
<input type="text" id="new-group-name" placeholder="new group name">
<input type="text" id="new-group-member" placeholder="first member">
<button class="mg-btn mg-btn-outline" onclick="createGroup()">Add group</button>
</div>
</div>

<details class="mg-add-card mg-danger-card">
<summary>Sessions</summary>
<div class="mg-card-body">
<p class="mg-card-subtitle" style="margin:0 0 0.5rem">
Rotate the session-signing secret. Invalidates every signed cookie currently
in circulation, including your own &mdash; everyone must sign in again.
</p>
<button class="mg-btn mg-btn-danger" onclick="rotateAuthSecret()">Log out all users</button>
</div>
</details>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';
var DAV_BASE = location.origin + '/dav';
var allGroups = {};   // {group: [members]}
var allUsers  = [];   // [username]

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

// Load users + their settings + groups, then render both sections.
function loadUsers() {
  var gp = apiCall({ action: 'groups' })
    .then(function(d) { return (d.ok && d.groups) ? d.groups : {}; })
    .catch(function() { return {}; });
  var up = apiCall({ action: 'list' })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error, true); return []; }
      var users = d.users || [];
      return Promise.all(users.map(function(u) {
        return apiCall({ action: 'settings-get', username: u })
          .then(function(s) { return { user: u, settings: (s.ok ? s.settings : {}) }; })
          .catch(function() { return { user: u, settings: {} }; });
      }));
    });
  Promise.all([up, gp]).then(function(res) {
    var rows = res[0] || [];
    allGroups = res[1] || {};
    allUsers = rows.map(function(r) { return r.user; });
    renderUsers(rows);
    renderGroups();
  }).catch(function(e) { showStatus('Failed to load users: ' + e.message, true); });
}

function groupsForUser(user) {
  var out = [];
  Object.keys(allGroups).forEach(function(g) {
    var m = Array.isArray(allGroups[g]) ? allGroups[g] : [];
    if (m.indexOf(user) !== -1) out.push(g);
  });
  return out;
}

// One <details> accordion row per user.
function renderUsers(rows) {
  var list = document.getElementById('user-list');
  if (!rows.length) { list.innerHTML = '<div class="mg-empty" style="padding:0.75rem;">No users</div>'; return; }
  list.innerHTML = rows.map(renderUserRow).join('');
}

function cap(user, key, on, label) {
  return '<label class="mg-chk"><input type="checkbox"' + (on ? ' checked' : '') +
    ' onchange="toggleSetting(\'' + user + '\',\'' + key + '\',this)"> ' + label + '</label>';
}

function renderUserRow(row) {
  var u = row.user, s = row.settings || {}, ue = escHtml(u);
  var webdav   = !!s.webdav;
  var ui       = (s.ui === undefined || s.ui === null) ? true : !!s.ui;
  var disabled = !!s.disabled;
  var scope    = s.dav_scope || '';
  var type     = ui ? 'human' : 'automated';
  var status   = disabled ? '<span class="mg-tag mg-tag-off">disabled</span>' : '<span class="mg-tag mg-tag-on">enabled</span>';
  var by       = s.created_by ? ' &middot; by ' + escHtml(s.created_by) : '';

  var h = '<details class="mg-acc">';
  h += '<summary><span class="mg-acc-name">' + ue + '</span>' +
       '<span class="mg-acc-tags">' + type + ' &middot; ' + status + by + '</span></summary>';
  h += '<div class="mg-acc-body">';

  // --- Access ---
  h += '<div class="mg-sec">Access</div><div class="mg-checks">';
  h += cap(ue, 'ui', ui, 'Interactive login');
  h += cap(ue, 'webdav', webdav, 'WebDAV');
  h += cap(ue, 'manage_themes', !!s.manage_themes, 'Manage themes');
  h += cap(ue, 'manage_layouts', !!s.manage_layouts, 'Manage layouts');
  h += cap(ue, 'manage_config', !!s.manage_config, 'Manage config');
  h += cap(ue, 'create_sub_users', !!s.create_sub_users, 'Create sub-users');
  h += cap(ue, 'delegate_sub_user_creation', !!s.delegate_sub_user_creation, 'Delegate sub-users');
  h += '</div>';

  // --- Groups ---
  var mine = groupsForUser(u);
  h += '<div class="mg-sec">Groups</div><div class="mg-checks">';
  var gnames = Object.keys(allGroups).sort();
  if (gnames.length) {
    h += gnames.map(function(g) {
      var on = mine.indexOf(g) !== -1;
      return '<label class="mg-chk"><input type="checkbox"' + (on ? ' checked' : '') +
        ' onchange="toggleGroup(\'' + ue + '\',\'' + escHtml(g) + '\',this)"> ' + escHtml(g) + '</label>';
    }).join('');
  } else { h += '<span class="mg-empty">No groups yet.</span>'; }
  h += '</div>';

  // --- Credentials ---
  h += '<div class="mg-sec">Credentials</div>';
  h += '<div class="mg-line"><span class="mg-line-lbl">Password</span>' +
       '<input type="password" class="mg-inp" id="pw-' + ue + '" placeholder="new password">' +
       '<button class="mg-btn mg-btn-sm" onclick="savePassword(\'' + ue + '\')">Save</button>' +
       '<span class="mg-inline-msg" id="pwmsg-' + ue + '"></span></div>';
  h += '<div class="mg-line"><span class="mg-line-lbl">Token</span>' +
       '<button class="mg-btn mg-btn-sm" onclick="generateCredential(\'' + ue + '\')">Generate credential</button>' +
       '<span class="mg-help" title="Mints a strong, single-use machine credential (prefix lzs_), shown once. Use it as the password for WebDAV / API clients. Replaces any existing password or token.">&#9432;</span></div>';
  h += '<div class="mg-cred-reveal" id="cred-' + ue + '" style="display:none"></div>';

  // --- WebDAV (publishing accounts only) ---
  if (webdav) {
    var davUrl = DAV_BASE + (scope ? scope.replace(/\/+$/,'') : '');
    h += '<div class="mg-sec">WebDAV</div>';
    h += '<div class="mg-line"><span class="mg-line-lbl">URL</span>' +
         '<code class="mg-code" id="dav-' + ue + '">' + escHtml(davUrl) + '</code>' +
         '<button class="mg-btn mg-btn-sm" onclick="copyText(\'dav-' + ue + '\')">Copy</button></div>';
    h += '<div class="mg-line"><span class="mg-line-lbl">Username</span><code class="mg-code">' + ue + '</code>' +
         ' <span class="mg-muted">password = this account\'s password or a generated token</span></div>';
    h += '<div class="mg-line"><span class="mg-line-lbl">Scope</span>' +
         '<input type="text" class="mg-inp" id="scope-' + ue + '" value="' + escHtml(scope) + '" placeholder="/ (whole site)">' +
         '<button class="mg-btn mg-btn-sm" onclick="setUserScope(\'' + ue + '\')">Set</button>' +
         '<span class="mg-help" title="Limits this account\'s WebDAV writes to a path prefix under the docroot. Empty = whole site (minus denied paths).">&#9432;</span></div>';
  }

  // --- AI partner onboarding (publishing accounts only) ---
  if (webdav) {
    h += '<div class="mg-sec">AI partner onboarding</div>';
    h += '<div class="mg-line"><button class="mg-btn mg-btn-sm" onclick="showOnboarding(\'' + ue + '\')">Generate brief</button>' +
         '<span class="mg-muted">single-use pairing key &rarr; access token; copy-paste to your partner</span></div>';
    h += '<div id="onb-' + ue + '" style="display:none"></div>';
  }

  // --- Account ---
  h += '<div class="mg-sec">Account</div>';
  h += '<div class="mg-line">';
  h += '<button class="mg-btn mg-btn-sm" onclick="toggleDisabled(\'' + ue + '\',' + (disabled ? 'true' : 'false') + ')">' +
       (disabled ? 'Enable' : 'Disable') + '</button>';
  h += '<input type="text" class="mg-inp" id="reassign-' + ue + '" placeholder="reassign to parent" value="' +
       escHtml(s.managed_by || s.created_by || '') + '">';
  h += '<button class="mg-btn mg-btn-sm" onclick="reassignUser(\'' + ue + '\')">Reassign</button>';
  h += '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="deleteUser(\'' + ue + '\')">Delete</button>';
  h += '</div>';
  var prov = s.created_by ? ('created by ' + escHtml(s.created_by) +
             (s.managed_by && s.managed_by !== s.created_by ? ', managed by ' + escHtml(s.managed_by) : '')) : '';
  if (prov) h += '<div class="mg-prov">' + prov + '</div>';

  h += '</div></details>';
  return h;
}

// --- per-row actions ---

function toggleSetting(user, key, el) {
  var checked = el.checked;
  apiCall({ action: 'settings-set', username: user, key: key, value: checked ? 'on' : 'off' })
    .then(function(d) {
      if (!d.ok) { el.checked = !checked; showStatus(d.error, true); return; }
      showStatus(key + ' ' + (checked ? 'on' : 'off') + ' for "' + user + '".');
    })
    .catch(function(e) { el.checked = !checked; showStatus('Error: ' + e.message, true); });
}

function toggleGroup(user, group, el) {
  var checked = el.checked;
  var act = checked ? 'group-add' : 'group-remove';
  apiCall({ action: act, username: user, group: group })
    .then(function(d) {
      if (!d.ok) { el.checked = !checked; showStatus(d.error, true); return; }
      // keep local cache in sync so other rows reflect it without a reload
      var m = Array.isArray(allGroups[group]) ? allGroups[group] : (allGroups[group] = []);
      var idx = m.indexOf(user);
      if (checked && idx === -1) m.push(user);
      if (!checked && idx !== -1) m.splice(idx, 1);
      showStatus((checked ? 'Added ' : 'Removed ') + user + (checked ? ' to ' : ' from ') + group + '.');
    })
    .catch(function(e) { el.checked = !checked; showStatus('Error: ' + e.message, true); });
}

function setUserScope(user) {
  var input = document.getElementById('scope-' + user);
  var val = ((input && input.value) || '').trim();
  apiCall({ action: 'settings-set', username: user, key: 'dav_scope', value: val })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error, true); return; }
      var code = document.getElementById('dav-' + user);
      if (code) code.textContent = DAV_BASE + (val ? val.replace(/\/+$/, '') : '');
      showStatus(val ? ('Scope set to ' + val + ' for "' + user + '".') : ('Scope cleared for "' + user + '".'));
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

function savePassword(user) {
  var inp = document.getElementById('pw-' + user);
  var msg = document.getElementById('pwmsg-' + user);
  var pw = (inp && inp.value) || '';
  function say(t, ok) { if (msg) { msg.textContent = t; msg.className = 'mg-inline-msg ' + (ok ? 'mg-ok' : 'mg-err'); } }
  if (!pw) { say('Enter a password.', false); return; }
  apiCall({ action: 'passwd', username: user, password: pw })
    .then(function(d) {
      if (!d.ok) { say(d.error || 'Failed', false); return; }
      if (inp) inp.value = '';
      say('Password updated.', true);
    })
    .catch(function(e) { say('Error: ' + e.message, false); });
}

function generateCredential(user) {
  if (!confirm('Generate a new credential for "' + user + '"? Any existing password or credential for this account will stop working.')) return;
  apiCall({ action: 'token', username: user })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error, true); return; }
      var panel = document.getElementById('cred-' + user);
      if (panel) {
        panel.style.display = '';
        panel.innerHTML = '<strong>Credential (shown once &mdash; store it now):</strong> ' +
          '<code class="mg-cred-value">' + escHtml(d.token) + '</code> ' +
          '<button class="mg-btn mg-btn-sm" onclick="copyCred(\'' + escHtml(user) + '\')">Copy</button>';
      }
      showStatus('Credential generated for "' + user + '".');
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

function copyCred(user) {
  var panel = document.getElementById('cred-' + user);
  var code = panel && panel.querySelector('.mg-cred-value');
  if (code && navigator.clipboard) navigator.clipboard.writeText(code.textContent).then(function() { showStatus('Credential copied.'); });
}

function showOnboarding(user) {
  var box = document.getElementById('onb-' + user);
  apiCall({ action: 'onboarding', username: user })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error, true); return; }
      box._text = d.onboarding;
      box.style.display = '';
      box.innerHTML = '<textarea class="mg-onb" readonly rows="12">' + escHtml(d.onboarding) + '</textarea>' +
        '<div class="mg-line"><button class="mg-btn mg-btn-sm" onclick="copyOnboarding(\'' + escHtml(user) + '\')">Copy</button>' +
        '<button class="mg-btn mg-btn-sm" onclick="downloadOnb(\'' + escHtml(user) + '\')">Download .md</button></div>';
      showStatus('Onboarding brief generated (contains a single-use pairing key).');
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

function copyOnboarding(user) {
  var box = document.getElementById('onb-' + user);
  if (box && box._text && navigator.clipboard) navigator.clipboard.writeText(box._text).then(function() { showStatus('Onboarding copied.'); });
}

function downloadOnb(user) {
  var box = document.getElementById('onb-' + user);
  if (!box || !box._text) return;
  var blob = new Blob([box._text], { type: 'text/markdown' });
  var a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'automated-partner-' + user + '.md';
  document.body.appendChild(a); a.click(); document.body.removeChild(a);
  URL.revokeObjectURL(a.href);
}

function toggleDisabled(user, disabled) {
  if (!disabled && !confirm('Disable "' + user + '"? They will be unable to authenticate anywhere until re-enabled.')) return;
  var act = disabled ? 'account-enable' : 'account-disable';
  apiCall({ action: act, username: user })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error, true); return; }
      showStatus((disabled ? 'Enabled' : 'Disabled') + ' "' + user + '".');
      loadUsers();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

function reassignUser(user) {
  var inp = document.getElementById('reassign-' + user);
  var to = ((inp && inp.value) || '').trim();
  if (!to) { showStatus('Enter a parent username to reassign to.', true); return; }
  apiCall({ action: 'account-reassign', username: user, to: to })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error, true); return; }
      showStatus('Reassigned "' + user + '" to "' + to + '".');
      loadUsers();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

function deleteUser(user) {
  if (!confirm('Delete user "' + user + '"? This cannot be undone.')) return;
  apiCall({ action: 'remove', username: user })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error, true); return; }
      showStatus('User "' + user + '" removed.');
      loadUsers();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

function createSubUser() {
  var u = (document.getElementById('sub-username').value || '').trim();
  var p = (document.getElementById('sub-password').value || '').trim();
  if (!u || !p) { showStatus('Sub-user username and password required.', true); return; }
  apiCall({ action: 'account-create', username: u, password: p })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error, true); return; }
      showStatus('Sub-user "' + u + '" created.');
      document.getElementById('sub-username').value = '';
      document.getElementById('sub-password').value = '';
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
    .then(function(d) {
      if (!d.ok) { showStatus(d.error, true); return; }
      var gl = groups ? groups.split(',').map(function(x) { return x.trim(); }).filter(Boolean) : [];
      var chain = Promise.resolve();
      gl.forEach(function(g) { chain = chain.then(function() { return apiCall({ action: 'group-add', username: username, group: g }); }); });
      chain.then(function() {
        showStatus('User "' + username + '" added.');
        document.getElementById('new-username').value = '';
        document.getElementById('new-password').value = '';
        document.getElementById('new-groups').value = '';
        loadUsers();
      });
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

// --- Groups section: one accordion per group, members as checkboxes ---

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
      loadUsers();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

function deleteGroup(group) {
  var members = Array.isArray(allGroups[group]) ? allGroups[group] : [];
  if (!confirm('Delete group "' + group + '"?' + (members.length ? ' Removes ' + members.length + ' member(s).' : ''))) return;
  if (!members.length) { showStatus('Group "' + group + '" already empty.'); loadUsers(); return; }
  var chain = Promise.resolve();
  members.slice().forEach(function(m) { chain = chain.then(function() { return apiCall({ action: 'group-remove', username: m, group: group }); }); });
  chain.then(function() { showStatus('Group "' + group + '" deleted.'); loadUsers(); })
       .catch(function(e) { showStatus('Error: ' + e.message, true); loadUsers(); });
}

function copyText(id) {
  var el = document.getElementById(id);
  if (el && navigator.clipboard) navigator.clipboard.writeText(el.textContent).then(function() { showStatus('Copied.'); });
}

function rotateAuthSecret() {
  if (!confirm('This will sign every user (including you) out immediately. Every cookie currently in circulation will stop working. Proceed?')) return;
  fetch(API + '?action=rotate-auth-secret', { method: 'POST' })
    .then(function(r) { return r.json(); })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error || 'Rotation failed', true); return; }
      if (typeof mgShowWarning === 'function') mgShowWarning(d.message || 'All sessions invalidated.', false);
      setTimeout(function() { location.href = '/login'; }, 1200);
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

loadUsers();
</script>

<style>
.mg-add-card { border:1px solid var(--mg-border,#e5e5e5); border-radius:4px; margin:0 0 1rem; background:var(--mg-bg,#fff); }
.mg-add-card > summary { cursor:pointer; padding:0.5rem 0.75rem; font-weight:600; list-style:none; }
.mg-add-card > summary::-webkit-details-marker { display:none; }
.mg-add-card[open] > summary { border-bottom:1px solid var(--mg-border,#e5e5e5); }
.mg-danger-card > summary { color:var(--mg-danger,#c33); }

.mg-acc-list { padding:0; }
.mg-acc { border-bottom:1px solid var(--mg-border,#eee); }
.mg-acc > summary {
  cursor:pointer; padding:0.5rem 0.75rem; display:flex; align-items:center;
  gap:0.75rem; list-style:none;
}
.mg-acc > summary::-webkit-details-marker { display:none; }
.mg-acc > summary::before { content:'\25B8'; color:var(--mg-text-muted,#999); font-size:0.8em; }
.mg-acc[open] > summary::before { content:'\25BE'; }
.mg-acc > summary:hover { background:var(--mg-bg-muted,#f7f7f7); }
.mg-acc-name { font-weight:600; }
.mg-acc-tags { color:var(--mg-text-muted,#888); font-size:0.85rem; margin-left:auto; }
.mg-acc-body { padding:0.5rem 0.75rem 0.9rem 1.75rem; background:var(--mg-bg-muted,#fbfbfb); }

.mg-sec { font-size:0.72rem; text-transform:uppercase; letter-spacing:0.04em;
  color:var(--mg-text-muted,#999); margin:0.7rem 0 0.3rem; }
.mg-checks { display:flex; flex-wrap:wrap; gap:0.4rem 1rem; }
.mg-chk { font-size:0.875rem; display:inline-flex; align-items:center; gap:0.3rem; cursor:pointer; }
.mg-line { display:flex; align-items:center; gap:0.4rem; flex-wrap:wrap; margin:0.25rem 0; }
.mg-line-lbl { width:5.5rem; color:var(--mg-text-muted,#888); font-size:0.8rem; }
.mg-inp { font-size:0.8125rem; padding:0.2rem 0.4rem; min-width:11rem; }
.mg-code { font-family:monospace; background:var(--mg-bg,#fff); padding:0.1rem 0.3rem;
  border-radius:2px; word-break:break-all; }
.mg-muted { color:var(--mg-text-muted,#999); font-size:0.8rem; }
.mg-help { cursor:help; color:var(--mg-text-muted,#aaa); }
.mg-prov { color:var(--mg-text-muted,#999); font-size:0.8rem; margin-top:0.4rem; }
.mg-inline-msg { font-size:0.8rem; }
.mg-inline-msg.mg-ok  { color:var(--mg-success,#2a7); }
.mg-inline-msg.mg-err { color:var(--mg-danger,#c33); }
.mg-onb { width:100%; font-family:monospace; font-size:0.78rem; }
.mg-cred-reveal { margin:0.4rem 0; padding:0.4rem 0.5rem; background:var(--mg-bg,#fff);
  border:1px solid var(--mg-border,#e5e5e5); border-radius:3px; font-size:0.875rem; }
.mg-cred-value { font-family:monospace; word-break:break-all; background:var(--mg-bg-muted,#f6f6f6);
  padding:0.1rem 0.25rem; border-radius:2px; }
.mg-tag { font-size:0.72rem; padding:0.05rem 0.35rem; border-radius:3px; }
.mg-tag-on  { color:var(--mg-success,#2a7); }
.mg-tag-off { color:var(--mg-danger,#c33); }
.mg-new-group-row { display:flex; align-items:center; gap:0.5rem; flex-wrap:wrap;
  border-top:1px solid var(--mg-border,#e5e5e5); }
</style>
