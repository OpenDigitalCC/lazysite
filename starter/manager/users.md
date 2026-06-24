---
title: User Management
auth: manager
search: false
---

<div id="status" class="mg-status"></div>

<div class="mg-card">
<div class="mg-card-header">
<span class="mg-card-title">Users</span>
</div>
<div id="user-list" class="mg-acc-list">
<div class="mg-empty" style="padding:0.75rem;">Loading...</div>
</div>
<details class="mg-add-card" style="margin:0.5rem;">
<summary>+ Add user</summary>
<div class="mg-card-body">
<div class="mg-form-row">
<label>Type</label>
<select id="new-type">
<option value="human">Human (interactive login)</option>
<option value="ai">AI / backend (token)</option>
</select>
</div>
<div class="mg-form-row">
<label>Username</label>
<input type="text" id="new-username" placeholder="username">
</div>
<div class="mg-form-row">
<label>Groups</label>
<select multiple id="new-groups" class="mg-inp mg-inp-wide" size="3"></select>
</div>
<div class="mg-form-row">
<label>Create under</label>
<select id="new-parent"><option value="">(top level - under you, the manager)</option></select>
</div>
<div class="mg-form-row">
<label></label>
<button class="mg-btn mg-btn-outline" onclick="addUser()">Add user</button>
</div>
</div>
</details>
</div>

<div class="mg-card">
<div class="mg-card-header">
<span class="mg-card-title">Groups</span>
</div>
<div id="groups-info" class="mg-acc-list">Loading...</div>
<details class="mg-add-card" style="margin:0.5rem;">
<summary>+ Add group</summary>
<div class="mg-card-body mg-new-group-row">
<input type="text" id="new-group-name" placeholder="new group name">
<input type="text" id="new-group-member" placeholder="first member">
<button class="mg-btn mg-btn-outline" onclick="createGroup()">Add group</button>
</div>
</details>
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
var parentList = [];  // [username] - accounts that can own sub-users (create_sub_users)

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
    parentList = rows.filter(function(r) { return r.settings && r.settings.create_sub_users; })
                     .map(function(r) { return r.user; }).sort();
    populateAddUserGroups();
    populateAddUserParents();
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

// Wrap a card section in a bounded box with a heading.
function sec(title, inner) {
  return '<div class="mg-box"><div class="mg-sec">' + title + '</div>' + inner + '</div>';
}

function renderUserRow(row) {
  var u = row.user, s = row.settings || {}, ue = escHtml(u);
  var webdav   = !!s.webdav;
  var ui       = (s.ui === undefined || s.ui === null) ? true : !!s.ui;
  var disabled = !!s.disabled;
  var scope    = s.dav_scope || '';
  var status   = disabled ? '<span class="mg-tag mg-tag-off">disabled</span>'
                          : '<span class="mg-tag mg-tag-on">enabled</span>';
  // "automated" == no interactive login (the Access > Interactive login box
  // is off); a normal interactive account gets no tag. Same language as the
  // checkbox, so the summary and the control agree.
  var typeTag  = ui
    ? '<span class="mg-tag mg-tag-human">human</span> &middot; '
    : '<span class="mg-tag mg-tag-auto">AI</span> &middot; ';
  var by       = s.created_by ? ' &middot; by ' + escHtml(s.created_by) : '';
  var comment  = s.comment || '';
  var note     = comment ? '<span class="mg-acc-note">' + escHtml(comment) + '</span>' : '';
  var expTag   = '';
  if (s.expires_at) {
    expTag = (s.expires_at < Date.now() / 1000)
      ? ' &middot; <span class="mg-tag mg-tag-off">expired</span>'
      : ' &middot; <span class="mg-acc-note">expires ' + expiryDate(s.expires_at) + '</span>';
  }

  var h = '<details class="mg-acc"><summary>' +
    '<span class="mg-acc-name">' + ue + '</span>' + note +
    '<span class="mg-acc-tags">' + typeTag + status + by + expTag + '</span></summary>' +
    '<div class="mg-acc-body">';

  // --- Notes ---
  var nb = '<div class="mg-line"><span class="mg-line-lbl">Note</span>' +
    '<input type="text" class="mg-inp mg-inp-wide" id="note-' + ue + '" value="' + escHtml(comment) +
    '" placeholder="what this account is for (e.g. Claude dav publisher)">' +
    '<button class="mg-btn mg-btn-sm" onclick="saveComment(\'' + ue + '\')">Save</button>' +
    '<span class="mg-inline-msg" id="notemsg-' + ue + '"></span></div>';
  nb += '<div class="mg-line"><span class="mg-line-lbl">Email</span>' +
    '<input type="email" class="mg-inp" id="email-' + ue + '" value="' + escHtml(s.email || '') +
    '" placeholder="for emailed setup / reset links">' +
    '<button class="mg-btn mg-btn-sm" onclick="saveEmail(\'' + ue + '\')">Save</button>' +
    '<span class="mg-inline-msg" id="emailmsg-' + ue + '"></span></div>';
  h += sec('Notes', nb);

  // --- Access ---
  // Type is a Human/AI switch (the `ui` setting), matching the Add-user
  // form, rather than a lone "Interactive login" checkbox.
  var acc = '<div class="mg-line"><span class="mg-line-lbl">Type</span>' +
    '<select class="mg-inp" onchange="setUserType(\'' + ue + '\', this.value)">' +
    '<option value="human"' + (ui ? ' selected' : '') + '>Human (interactive login)</option>' +
    '<option value="ai"' + (ui ? '' : ' selected') + '>AI / backend (token)</option>' +
    '</select></div>';
  acc += '<div class="mg-checks">';
  acc += cap(ue, 'webdav', webdav, 'WebDAV');
  acc += cap(ue, 'manage_themes', !!s.manage_themes, 'Manage themes');
  acc += cap(ue, 'manage_layouts', !!s.manage_layouts, 'Manage layouts');
  acc += cap(ue, 'manage_config', !!s.manage_config, 'Manage config');
  acc += cap(ue, 'create_sub_users', !!s.create_sub_users, 'Create sub-users');
  acc += cap(ue, 'delegate_sub_user_creation', !!s.delegate_sub_user_creation, 'Delegate sub-users');
  acc += '</div>';
  h += sec('Access', acc);

  // --- Groups ---
  var mine = groupsForUser(u);
  var gnames = Object.keys(allGroups).sort();
  var grp = '<div class="mg-checks">';
  grp += gnames.length ? gnames.map(function(g) {
    var on = mine.indexOf(g) !== -1;
    return '<label class="mg-chk"><input type="checkbox"' + (on ? ' checked' : '') +
      ' onchange="toggleGroup(\'' + ue + '\',\'' + escHtml(g) + '\',this)"> ' + escHtml(g) + '</label>';
  }).join('') : '<span class="mg-empty">No groups yet.</span>';
  grp += '</div>';
  h += sec('Groups', grp);

  // --- Credentials ---
  var cred = '<div class="mg-line"><span class="mg-line-lbl">Password</span>' +
    '<input type="password" class="mg-inp" id="pw-' + ue + '" placeholder="new password">' +
    '<button class="mg-btn mg-btn-sm" onclick="savePassword(\'' + ue + '\')">Save</button>' +
    '<span class="mg-inline-msg" id="pwmsg-' + ue + '"></span></div>';
  cred += '<div class="mg-line"><span class="mg-line-lbl">Token</span>' +
    '<button class="mg-btn mg-btn-sm" onclick="generateCredential(\'' + ue + '\')">Generate credential</button>' +
    '<span class="mg-help" title="Mints a strong machine credential (prefix lzs_), shown once. Use it as the WebDAV / API password: it verifies far faster than the account password and is revoked by regenerating.">&#9432;</span></div>';
  cred += '<div class="mg-cred-reveal" id="cred-' + ue + '" style="display:none"></div>';
  cred += '<div class="mg-line"><span class="mg-line-lbl">Setup link</span>' +
    '<button class="mg-btn mg-btn-sm" onclick="setupLink(\'' + ue + '\',false)">Generate setup link</button>' +
    '<button class="mg-btn mg-btn-sm" onclick="setupLink(\'' + ue + '\',true)">Reset credential</button>' +
    (s.claim_pending ? ' <span class="mg-muted">(link outstanding)</span>' : '') +
    '<span class="mg-help" title="A one-time link the user opens to set their OWN password (or mint their own token) - you never see it. Reset credential revokes the current one first. Single-use, expires in 24h.">&#9432;</span></div>';
  cred += '<div class="mg-cred-reveal" id="setup-' + ue + '" style="display:none"></div>';
  cred += '<div class="mg-line"><span class="mg-line-lbl">Two-factor</span>' +
    (s.mfa_enrolled
      ? '<span class="mg-tag mg-tag-on">enabled</span> <button class="mg-btn mg-btn-sm" onclick="disable2fa(\'' + ue + '\')">Disable</button>'
      : '<button class="mg-btn mg-btn-sm" onclick="enable2fa(\'' + ue + '\')">Enable 2FA</button>') +
    '<span class="mg-inline-msg" id="mfamsg-' + ue + '"></span></div>';
  cred += '<div class="mg-cred-reveal" id="mfa-' + ue + '" style="display:none"></div>';
  h += sec('Credentials', cred);

  // --- WebDAV (publishing accounts only) ---
  if (webdav) {
    var davUrl = DAV_BASE + (scope ? scope.replace(/\/+$/, '') : '');
    var wd = '<div class="mg-line"><span class="mg-line-lbl">URL</span>' +
      '<code class="mg-code" id="dav-' + ue + '">' + escHtml(davUrl) + '</code>' +
      '<button class="mg-btn mg-btn-sm" onclick="copyText(\'dav-' + ue + '\')">Copy</button></div>';
    wd += '<div class="mg-line"><span class="mg-line-lbl">Username</span><code class="mg-code">' + ue + '</code></div>';
    wd += '<div class="mg-line"><span class="mg-line-lbl">Password</span>' +
      '<span class="mg-muted">use a <strong>Generate credential</strong> token (above) &mdash; far faster than the account password</span></div>';
    wd += '<div class="mg-line"><span class="mg-line-lbl">Scope</span>' +
      '<input type="text" class="mg-inp" id="scope-' + ue + '" value="' + escHtml(scope) + '" placeholder="/ (whole site)">' +
      '<button class="mg-btn mg-btn-sm" onclick="setUserScope(\'' + ue + '\')">Set</button>' +
      '<span class="mg-help" title="Limits this account\'s WebDAV writes to a path prefix under the docroot. Empty = whole site (minus denied paths).">&#9432;</span></div>';
    h += sec('WebDAV', wd);
  }

  // --- AI partner onboarding (publishing accounts only) ---
  if (webdav) {
    var ob = '<div class="mg-line"><button class="mg-btn mg-btn-sm" onclick="showOnboarding(\'' + ue + '\')">Generate brief</button>' +
      '<span class="mg-muted">single-use pairing key &rarr; access token; copy-paste to your partner</span></div>' +
      '<div id="onb-' + ue + '" style="display:none"></div>';
    h += sec('AI partner onboarding', ob);
  }

  // --- Account ---
  var ac = '<div class="mg-line">' +
    '<button class="mg-btn mg-btn-sm" onclick="toggleDisabled(\'' + ue + '\',' + (disabled ? 'true' : 'false') + ')">' +
    (disabled ? 'Enable' : 'Disable') + '</button>' +
    '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="deleteUser(\'' + ue + '\')">Delete</button></div>';
  ac += '<div class="mg-line"><a href="/manager/audit?user=' + encodeURIComponent(u) + '">View this account\'s audit log &rarr;</a></div>';
  ac += '<div class="mg-line"><span class="mg-line-lbl">Expires</span>' +
    '<input type="date" class="mg-inp" id="exp-' + ue + '" value="' + expiryDate(s.expires_at) + '">' +
    '<button class="mg-btn mg-btn-sm" onclick="setExpiry(\'' + ue + '\')">Set</button>' +
    '<button class="mg-btn mg-btn-sm" onclick="clearExpiry(\'' + ue + '\')">Clear</button>' +
    '<span class="mg-inline-msg" id="expmsg-' + ue + '"></span></div>';
  ac += '<div class="mg-line"><span class="mg-line-lbl">Rename</span>' +
    '<input type="text" class="mg-inp" id="rename-' + ue + '" placeholder="new username">' +
    '<button class="mg-btn mg-btn-sm" onclick="renameUser(\'' + ue + '\')">Rename</button>' +
    '<span class="mg-inline-msg" id="renmsg-' + ue + '"></span></div>';
  // Owner + reassign only for sub-users (accounts with a recorded parent).
  if (s.created_by) {
    var owner = s.managed_by || s.created_by;
    var ropts = '<option value="">reassign to&hellip;</option>' +
      allUsers.filter(function(x) { return x !== u; })
        .map(function(x) { return '<option value="' + escHtml(x) + '">' + escHtml(x) + '</option>'; }).join('');
    ac += '<div class="mg-line"><span class="mg-line-lbl">Owner</span>' +
      '<code class="mg-code">' + escHtml(owner) + '</code>' +
      '<select class="mg-inp" id="reassign-' + ue + '">' + ropts + '</select>' +
      '<button class="mg-btn mg-btn-sm" onclick="reassignUser(\'' + ue + '\')">Reassign</button></div>';
  }
  h += sec('Account', ac);

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

// Human/AI switch for an existing account (the `ui` setting). Reloads so
// the summary tag and any form state reflect the new type.
function setUserType(user, value) {
  var ui = (value === 'human') ? 'on' : 'off';
  apiCall({ action: 'settings-set', username: user, key: 'ui', value: ui })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error, true); return; }
      showStatus('"' + user + '" set to ' +
        (value === 'human' ? 'human (interactive login)' : 'AI / backend (token)') + '.');
      loadUsers();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
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

function closeOnboarding(user) {
  var box = document.getElementById('onb-' + user);
  if (box) { box.style.display = 'none'; box.innerHTML = ''; box._text = ''; }
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
        '<button class="mg-btn mg-btn-sm" onclick="downloadOnb(\'' + escHtml(user) + '\')">Download .md</button>' +
        '<button class="mg-btn mg-btn-sm" onclick="closeOnboarding(\'' + escHtml(user) + '\')">Close</button></div>' +
        '<div class="mg-muted" style="font-size:0.8em;margin-top:0.25rem">Single-use, expires in 24h. ' +
        'Generating another brief mints a fresh key and <strong>invalidates this one</strong> &mdash; only the most recent works.<br>' +
        'Contains a secret: deliver it out of band to the agent that does the writes (Claude Code / a script / yourself), ' +
        'or for a chat assistant use the MCP connector (token in connector settings). ' +
        '<strong>Don\'t paste it into a shared/logged chat</strong> &mdash; a key seen in a transcript is spent; regenerate.</div>';
      showStatus('Onboarding brief generated - a fresh single-use pairing key (any previous one is now invalid).');
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

// Save the free-text annotation (comment) for an account.
function saveComment(user) {
  var inp = document.getElementById('note-' + user);
  var msg = document.getElementById('notemsg-' + user);
  function say(t, ok) { if (msg) { msg.textContent = t; msg.className = 'mg-inline-msg ' + (ok ? 'mg-ok' : 'mg-err'); } }
  apiCall({ action: 'settings-set', username: user, key: 'comment', value: (inp && inp.value) || '' })
    .then(function(d) { if (!d.ok) { say(d.error, false); return; } say('Saved.', true); })
    .catch(function(e) { say('Error: ' + e.message, false); });
}

// Save the contact email (for emailed setup/reset links).
function saveEmail(user) {
  var inp = document.getElementById('email-' + user);
  var msg = document.getElementById('emailmsg-' + user);
  function say(t, ok) { if (msg) { msg.textContent = t; msg.className = 'mg-inline-msg ' + (ok ? 'mg-ok' : 'mg-err'); } }
  apiCall({ action: 'settings-set', username: user, key: 'email', value: (inp && inp.value) || '' })
    .then(function(d) { if (!d.ok) { say(d.error, false); return; } say('Saved.', true); })
    .catch(function(e) { say('Error: ' + e.message, false); });
}

// --- SM072: setup links + account expiry ---

// Mint a one-time setup link to hand to the user; reset=true also revokes
// the current credential first (Reset credential). The operator never sees
// the secret the user will set.
function setupLink(user, reset) {
  var box = document.getElementById('setup-' + user);
  function show(html) { if (box) { box.style.display = 'block'; box.innerHTML = html; } }
  apiCall({ action: 'claim-create', username: user, revoke: reset ? 1 : 0 })
    .then(function(d) {
      if (!d.ok) { show('<span class="mg-err">' + escHtml(d.error) + '</span>'); return; }
      var link = location.origin + '/claim?u=' + encodeURIComponent(user) + '&c=' + encodeURIComponent(d.claim);
      var what = d.purpose === 'mint-token'
        ? 'Opening the link mints this account a token.'
        : 'The user sets their own password when they open it.';
      show('<div class="mg-muted">' + (reset ? 'Current credential revoked. ' : '') + what +
        ' Single-use, expires in 24h &mdash; copy it now.</div>' +
        '<code class="mg-code" id="setuplink-' + user + '">' + escHtml(link) + '</code>' +
        '<button class="mg-btn mg-btn-sm" onclick="copyText(\'setuplink-' + user + '\')">Copy</button>');
    })
    .catch(function(e) { show('<span class="mg-err">Error: ' + escHtml(e.message) + '</span>'); });
}

// epoch -> YYYY-MM-DD for the date input (local time).
function expiryDate(epoch) {
  if (!epoch) return '';
  var d = new Date(epoch * 1000);
  return d.getFullYear() + '-' + ('0' + (d.getMonth() + 1)).slice(-2) + '-' + ('0' + d.getDate()).slice(-2);
}

function setExpiry(user) {
  var inp = document.getElementById('exp-' + user);
  var msg = document.getElementById('expmsg-' + user);
  function say(t, ok) { if (msg) { msg.textContent = t; msg.className = 'mg-inline-msg ' + (ok ? 'mg-ok' : 'mg-err'); } }
  var v = inp && inp.value;
  if (!v) { say('Pick a date, or use Clear.', false); return; }
  var epoch = Math.floor(new Date(v + 'T23:59:59').getTime() / 1000);   // end of the chosen day
  apiCall({ action: 'settings-set', username: user, key: 'expires_at', value: String(epoch) })
    .then(function(d) { if (!d.ok) { say(d.error, false); return; } say('Expires ' + v + '.', true); })
    .catch(function(e) { say('Error: ' + e.message, false); });
}

function clearExpiry(user) {
  var inp = document.getElementById('exp-' + user);
  var msg = document.getElementById('expmsg-' + user);
  apiCall({ action: 'settings-set', username: user, key: 'expires_at', value: '' })
    .then(function(d) {
      if (msg) { msg.textContent = d.ok ? 'No expiry.' : d.error; msg.className = 'mg-inline-msg ' + (d.ok ? 'mg-ok' : 'mg-err'); }
      if (d.ok && inp) inp.value = '';
    })
    .catch(function(e) {});
}

// Rename an account (credentials, settings, groups, provenance all move).
function renameUser(user) {
  var inp = document.getElementById('rename-' + user);
  var msg = document.getElementById('renmsg-' + user);
  function say(t, ok) { if (msg) { msg.textContent = t; msg.className = 'mg-inline-msg ' + (ok ? 'mg-ok' : 'mg-err'); } }
  var to = ((inp && inp.value) || '').trim();
  if (!to) { say('New username required.', false); return; }
  apiCall({ action: 'rename', username: user, to: to })
    .then(function(d) { if (!d.ok) { say(d.error, false); return; } say('Renamed.', true); loadUsers(); })
    .catch(function(e) { say('Error: ' + e.message, false); });
}

// Enrol TOTP: reveal the secret, otpauth URI, and recovery codes once.
function enable2fa(user) {
  var box = document.getElementById('mfa-' + user);
  function show(html) { if (box) { box.style.display = 'block'; box.innerHTML = html; } }
  apiCall({ action: 'mfa-enroll', username: user })
    .then(function(d) {
      if (!d.ok) { show('<span class="mg-err">' + escHtml(d.error) + '</span>'); return; }
      var codes = (d.recovery_codes || []).map(escHtml).join('<br>');
      show('<div class="mg-muted">Add to an authenticator app, then sign out and back in with a code. Shown once.</div>' +
        '<div class="mg-line"><span class="mg-line-lbl">Secret</span><code class="mg-code" id="mfasec-' + user + '">' + escHtml(d.secret) + '</code>' +
        '<button class="mg-btn mg-btn-sm" onclick="copyText(\'mfasec-' + user + '\')">Copy</button></div>' +
        '<div class="mg-line"><span class="mg-line-lbl">otpauth</span><code class="mg-code" id="mfauri-' + user + '">' + escHtml(d.otpauth_uri) + '</code>' +
        '<button class="mg-btn mg-btn-sm" onclick="copyText(\'mfauri-' + user + '\')">Copy</button></div>' +
        '<div class="mg-muted">Recovery codes (store now, each works once):</div>' +
        '<div class="mg-code" style="white-space:normal">' + codes + '</div>');
    })
    .catch(function(e) { show('<span class="mg-err">Error: ' + escHtml(e.message) + '</span>'); });
}

function disable2fa(user) {
  var msg = document.getElementById('mfamsg-' + user);
  if (!confirm('Disable two-factor for "' + user + '"?')) return;
  apiCall({ action: 'mfa-disable', username: user })
    .then(function(d) {
      if (msg) { msg.textContent = d.ok ? 'Disabled.' : d.error; msg.className = 'mg-inline-msg ' + (d.ok ? 'mg-ok' : 'mg-err'); }
      loadUsers();
    })
    .catch(function(e) {});
}

// Fill the Add-user group multi-select from the loaded groups.
function populateAddUserGroups() {
  var sel = document.getElementById('new-groups');
  if (!sel) return;
  var keys = Object.keys(allGroups).sort();
  sel.innerHTML = keys.length
    ? keys.map(function(g) { return '<option value="' + escHtml(g) + '">' + escHtml(g) + '</option>'; }).join('')
    : '<option value="" disabled>no groups yet</option>';
}

// Fill the "Create under" parent dropdown from accounts that can own sub-users.
function populateAddUserParents() {
  var sel = document.getElementById('new-parent');
  if (!sel) return;
  var cur = sel.value;
  sel.innerHTML = '<option value="">(top level - under you, the manager)</option>' +
    parentList.map(function(p) { return '<option value="' + escHtml(p) + '">under ' + escHtml(p) + '</option>'; }).join('');
  sel.value = cur;
}

function addUser() {
  var username = document.getElementById('new-username').value.trim();
  var type = document.getElementById('new-type').value;            // human | ai
  var parent = document.getElementById('new-parent').value;        // '' = top-level
  var sel = document.getElementById('new-groups');
  var gl = sel ? Array.prototype.slice.call(sel.selectedOptions)
                   .map(function(o) { return o.value; }).filter(Boolean) : [];
  if (!username) { showStatus('Username required.', true); return; }
  // Accounts are created with no password - credentials are set afterward
  // from the card (Generate setup link, or Generate credential). A parent
  // makes this a sub-user (owned by that account); otherwise top-level.
  var req = parent
    ? { action: 'account-create', username: username, password: '', created_by: parent }
    : { action: 'add', username: username, password: '' };
  apiCall(req)
    .then(function(d) {
      if (!d.ok) { showStatus(d.error, true); return; }
      var chain = Promise.resolve();
      gl.forEach(function(g) { chain = chain.then(function() { return apiCall({ action: 'group-add', username: username, group: g }); }); });
      if (type === 'ai') {
        // backend account: no interactive login, WebDAV on - the card then
        // leads with Generate setup link / onboarding brief.
        chain = chain.then(function() { return apiCall({ action: 'settings-set', username: username, key: 'ui', value: 'off' }); })
                     .then(function() { return apiCall({ action: 'settings-set', username: username, key: 'webdav', value: 'on' }); });
      }
      chain.then(function() {
        var where = parent ? (' under "' + parent + '"') : '';
        showStatus(type === 'ai'
          ? ('AI account "' + username + '" added' + where + ' - open its card to Generate a setup link or onboarding brief.')
          : ('User "' + username + '" added' + where + ' - use Generate setup link in its card so they set their own password.'));
        document.getElementById('new-username').value = '';
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
.mg-inp-wide { min-width:20rem; flex:1; }
.mg-acc-note { color:var(--mg-text-muted,#888); font-style:italic; font-size:0.85rem; }
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
.mg-tag-auto { color:var(--mg-text-muted,#888); }
.mg-tag-human { color:var(--mg-accent,#06c); }
.mg-box { border:1px solid var(--mg-border,#e5e5e5); border-radius:4px;
  padding:0.35rem 0.6rem 0.6rem; margin:0.5rem 0; background:var(--mg-bg,#fff); }
.mg-box .mg-sec { margin-top:0.2rem; }
.mg-new-group-row { display:flex; align-items:center; gap:0.5rem; flex-wrap:wrap;
  border-top:1px solid var(--mg-border,#e5e5e5); }
</style>
