---
title: Users
auth: manager
search: false
query_params:
  - user
---

<div id="status" class="mg-status"></div>

<div class="mg-domain-note">
<b>Two access domains, one set of accounts.</b> The users and groups below are
shared by both: <b>file management</b> &mdash; internal access through the manager
UI, the control API and AI connectors, governed by each account's capabilities
and per-file rights; and <b>site access</b> &mdash; external visitor / member
login on the published site. The same username or <code>@group</code> is the same
identity in both domains; only <em>where</em> it is granted differs.
</div>

<div class="mg-card">
<div class="mg-card-header">
<span class="mg-card-title">User accounts</span>
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
<select id="new-parent"><option value="">Managed by you</option></select>
</div>
<div class="mg-form-row">
<label></label>
<button class="mg-btn mg-btn-primary" onclick="addUser()">Add user</button>
</div>
</div>
</details>
</div>

<p class="mg-card-subtitle" style="margin:0.25rem 0.5rem;">
Manage <a href="/manager/groups">Groups</a> and <a href="/manager/sessions">Sessions</a>
on their own pages (under Access in the menu). You can still assign a user to
groups from each user's card below.
</p>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';
var DAV_BASE = location.origin + '/dav';
var allGroups = {};   // {group: [members]}
var allUsers  = [];   // [username]
var parentList = [];  // [username] - accounts that can own sub-users (create_sub_users)
var MANAGER_GROUPS = [];  // SM094: site manager groups; members are operators
var ME = '';          // the current operator's username (from whoami) - a valid owner

// SM109 phase 2: route all status to the global toast.
function showStatus(msg, isError) {
  if (!msg) return;
  if (typeof mgToast === 'function') { mgToast(msg, isError ? 'error' : 'success'); return; }
  var el = document.getElementById('status');   // fallback if the global is absent
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
  var wp = fetch(API + '?action=whoami', { method: 'POST', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' }, body: '{}' })
    .then(function(r) { return r.json(); })
    .then(function(d) { if (d && d.ok && d.partner) ME = d.partner; return (d && d.ok && d.manager_groups) ? d.manager_groups : []; })
    .catch(function() { return []; });
  Promise.all([up, gp, wp]).then(function(res) {
    var rows = res[0] || [];
    allGroups = res[1] || {};
    MANAGER_GROUPS = res[2] || [];
    allUsers = rows.map(function(r) { return r.user; });
    renderUsers(rows);
    parentList = rows.filter(function(r) { return r.settings && r.settings.create_sub_users; })
                     .map(function(r) { return r.user; }).sort();
    populateAddUserGroups();
    populateAddUserParents();
  }).catch(function(e) { showStatus('Failed to load users: ' + e.message, true); });
}

var PERM_LABELS = {
  ui: 'Manager UI', webdav: 'WebDAV', api: 'API', mcp: 'MCP',
  manage_content: 'Content', manage_nav: 'Navigation', manage_forms: 'Forms',
  manage_themes: 'Themes', manage_layouts: 'Layouts', manage_config: 'Config + plugins',
  manage_users: 'Users & groups', analytics: 'Analytics',
  create_sub_users: 'Create sub-users', delegate_sub_user_creation: 'Delegate sub-users'
};

// Lazy-load the read-only channel x capability grid for a user when its panel opens.
function loadPermGrid(user, det) {
  if (!det || !det.open) return;
  var box = document.getElementById('permgrid-' + user);
  if (!box || box.getAttribute('data-loaded')) return;
  box.setAttribute('data-loaded', '1');
  apiCall({ action: 'permissions-grid', username: user }).then(function(d) {
    if (!d.ok) { box.textContent = d.error || 'Failed to load.'; box.removeAttribute('data-loaded'); return; }
    box.innerHTML = renderPermGrid(d);
  }).catch(function(e) { box.textContent = 'Error: ' + e.message; box.removeAttribute('data-loaded'); });
}

function renderPermGrid(d) {
  var chans = d.channels || [], acts = d.actions || [], gb = d.granted_by || {};
  var lbl = function(k) { return PERM_LABELS[k] || k; };
  var by  = function(cap) { return (gb[cap] && gb[cap].length) ? gb[cap] : null; };
  if (!d.groups || !d.groups.length) return '<p class="mg-empty">In no groups, so no capabilities.</p>';
  var h = '<table class="audit-table" style="font-size:12px"><thead><tr><th>Capability \\ Channel</th>';
  chans.forEach(function(c) {
    h += '<th title="' + (by(c) ? 'granted by: ' + by(c).join(', ') : 'not granted') + '">' + escHtml(lbl(c)) + '</th>';
  });
  h += '</tr></thead><tbody>';
  acts.forEach(function(a) {
    h += '<tr><td title="' + (by(a) ? 'granted by: ' + by(a).join(', ') : 'not granted') + '">' + escHtml(lbl(a)) + '</td>';
    chans.forEach(function(c) {
      var ok = by(a) && by(c);
      var tip = '';
      if (by(a)) tip += lbl(a) + ' via ' + by(a).join(', ');
      if (by(c)) tip += (tip ? '; ' : '') + lbl(c) + ' via ' + by(c).join(', ');
      h += '<td style="text-align:center;color:' + (ok ? '#1a7f37' : '#ccc') + '" title="'
        + escHtml(tip || 'not granted') + '">' + (ok ? '✓' : '·') + '</td>';
    });
    h += '</tr>';
  });
  h += '</tbody></table>';
  h += '<p class="mg-muted" style="font-size:11px;margin-top:0.3rem">&#10003; = has the action AND the channel; '
    + 'hover a cell or header for the granting group(s). Groups: ' + d.groups.map(escHtml).join(', ')
    + '. (Manager-UI login still uses the per-account toggle until the clean cut.)</p>';
  return h;
}

function groupsForUser(user) {
  var out = [];
  Object.keys(allGroups).forEach(function(g) {
    var m = Array.isArray(allGroups[g]) ? allGroups[g] : [];
    if (m.indexOf(user) !== -1) out.push(g);
  });
  return out;
}

// One <details> accordion row per user, with sub-users nested under their parent
// (managed_by/created_by) so the tree expands as the hierarchy it is.
function renderUsers(rows) {
  var list = document.getElementById('user-list');
  if (!rows.length) { list.innerHTML = '<div class="mg-empty" style="padding:0.75rem;">No users</div>'; return; }
  var byUser = {};
  rows.forEach(function(r) { byUser[r.user] = r; });
  var kids = {}, roots = [];
  rows.forEach(function(r) {
    var s = r.settings || {};
    var parent = s.managed_by || s.created_by || '';
    if (parent && byUser[parent] && parent !== r.user) {
      (kids[parent] = kids[parent] || []).push(r);
    } else {
      roots.push(r);
    }
  });
  function byName(a, b) { return a.user.localeCompare(b.user); }
  function node(row, parentName) {
    var ch = (kids[row.user] || []).sort(byName);
    var kidsHtml = ch.map(function(c) { return node(c, row.user); }).join('');
    return renderUserRow(row, kidsHtml, ch.length, parentName);
  }
  list.innerHTML = roots.sort(byName).map(function(r) { return node(r, ''); }).join('');
  focusUserFromUrl();
}

// Deep-link support: /manager/users?user=NAME opens that user's row and centres
// it (e.g. clicking a user in the audit log).
function focusUserFromUrl() {
  var m = location.search.match(/[?&]user=([^&]+)/);
  if (!m) return;
  var u = decodeURIComponent(m[1].replace(/\+/g, ' '));
  var sel = (window.CSS && CSS.escape) ? CSS.escape(u) : u.replace(/"/g, '\\"');
  var el = document.querySelector('#user-list details[data-user="' + sel + '"]');
  if (!el) return;
  // open the target and every ancestor <details>, so a nested sub-user is visible
  for (var p = el; p; p = p.parentElement) { if (p.tagName === 'DETAILS') p.open = true; }
  el.scrollIntoView({ block: 'center', behavior: 'smooth' });
}

function cap(user, key, on, label) {
  return '<label class="mg-chk"><input type="checkbox"' + (on ? ' checked' : '') +
    ' onchange="toggleSetting(\'' + user + '\',\'' + key + '\',this)"> ' + label + '</label>';
}

// Wrap a card section in a bounded box with a heading.
function sec(title, inner) {
  return '<div class="mg-box"><div class="mg-sec">' + title + '</div>' + inner + '</div>';
}

function renderUserRow(row, kidsHtml, subCount, parentName) {
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

  var subBadge = (subCount > 0)
    ? ' <span class="mg-subcount" title="' + subCount + ' sub-user' + (subCount > 1 ? 's' : '') + '">(+' + subCount + ')</span>'
    : '';
  // SM104: a sub-user shows whose account it is under; a top-level account shows nothing.
  var parentTag = parentName
    ? ' <span class="mg-subcount" title="sub-user of ' + escHtml(parentName) + '">&#8627; ' + escHtml(parentName) + '</span>'
    : '';
  var h = '<details class="mg-acc" data-user="' + ue + '"><summary>' +
    '<span class="mg-acc-name">' + ue + '</span>' + subBadge + parentTag + note +
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

  // Is this account an operator (member of a manager group)? Operators have full
  // manager access and bypass the per-account capabilities, so we hide the toggles
  // for them and show a note instead (SM094).
  var mineGroups = groupsForUser(u);
  var opGroups   = mineGroups.filter(function(g) { return MANAGER_GROUPS.indexOf(g) !== -1; });
  var isOperator = opGroups.length > 0;

  // --- Access ---
  // Type is a Human/AI switch (the `ui` setting), matching the Add-user
  // form, rather than a lone "Interactive login" checkbox.
  var acc = '<div class="mg-line"><span class="mg-line-lbl">Type</span>' +
    '<select class="mg-inp" onchange="setUserType(\'' + ue + '\', this.value)">' +
    '<option value="human"' + (ui ? ' selected' : '') + '>Human (interactive login)</option>' +
    '<option value="ai"' + (ui ? '' : ' selected') + '>AI / backend (token)</option>' +
    '</select></div>';
  h += sec('Access', acc);

  // --- Publishing access (the capability toggles) ---
  // These gate the partner surfaces (WebDAV / control API / AI connector). They are
  // ALWAYS shown and settable: operator (manager-group) status only bypasses the
  // cookie/UI path - an operator account that ALSO connects with a token is still
  // gated by these flags, so they must be settable for it too (the case that bit us:
  // a manager-group account whose connector could not manage themes/layouts).
  var pub = '';
  if (isOperator) {
    pub += '<p class="mg-muted">In <b>' + opGroups.map(escHtml).join(', ') +
      '</b> (operator): full access in the Manager UI via login. The capabilities below ' +
      'additionally govern this account\'s <b>token / WebDAV / connector</b> use &mdash; set ' +
      'them if it also connects as a partner (operator status does not lift them on that path).</p>';
  }
  pub += '<div class="mg-checks">' +
    cap(ue, 'webdav', webdav, 'WebDAV') +
    cap(ue, 'manage_content', !!s.manage_content, 'Manage content (pages)') +
    cap(ue, 'manage_nav', !!s.manage_nav, 'Manage navigation') +
    cap(ue, 'manage_forms', !!s.manage_forms, 'Manage forms') +
    cap(ue, 'manage_themes', !!s.manage_themes, 'Manage themes') +
    cap(ue, 'manage_layouts', !!s.manage_layouts, 'Manage layouts') +
    cap(ue, 'manage_config', !!s.manage_config, 'Manage config') +
    cap(ue, 'analytics', !!s.analytics, 'Analytics (visitor stats + audit)') +
    cap(ue, 'create_sub_users', !!s.create_sub_users, 'Create sub-users') +
    cap(ue, 'delegate_sub_user_creation', !!s.delegate_sub_user_creation, 'Delegate sub-users') +
    '</div>';
  h += sec('Publishing access (WebDAV / control API / AI connector)', pub);

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

  // --- Permissions viewer (read-only; derived from group membership) ---
  var pv = '<details ontoggle="loadPermGrid(\'' + ue + '\', this)">'
    + '<summary style="cursor:pointer">Show the channel &times; capability grid</summary>'
    + '<div id="permgrid-' + ue + '" style="margin-top:0.4rem">&hellip;</div></details>';
  h += sec('Permissions (derived)', pv);

  // --- Credentials (interactive login - human accounts only) ---
  // The connector credential (token) now lives in "Connect an AI assistant" below,
  // as one of the client choices (SM100), so it is not duplicated here.
  if (ui) {
    var cred = '<div class="mg-line"><span class="mg-line-lbl">Password</span>' +
      '<input type="password" class="mg-inp" id="pw-' + ue + '" placeholder="new password">' +
      '<button class="mg-btn mg-btn-sm" onclick="savePassword(\'' + ue + '\')">Save</button>' +
      '<span class="mg-inline-msg" id="pwmsg-' + ue + '"></span></div>';
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
  }

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

  // --- Connect an AI assistant (SM100: one flow - pick the client, get the one
  // credential that works; no three parallel controls to choose wrong between) ---
  if (webdav || !ui) {
    var conn =
      '<p class="mg-muted" style="margin:0 0 0.4rem">Pick how this account connects &mdash; we issue the one credential that works for it.</p>' +
      '<div class="mg-connect-pick">' +
        '<button class="mg-btn mg-btn-sm" onclick="connectAs(\'' + ue + '\',\'web\')">Claude.ai / ChatGPT (web)</button>' +
        '<button class="mg-btn mg-btn-sm" onclick="connectAs(\'' + ue + '\',\'desktop\')">Claude Desktop (connector)</button>' +
        '<button class="mg-btn mg-btn-sm" onclick="connectAs(\'' + ue + '\',\'code\')">Claude Code / script</button>' +
      '</div>' +
      '<div class="mg-connect-hint mg-muted" id="connhint-' + ue + '"></div>' +
      '<div class="mg-cred-reveal" id="cred-' + ue + '" style="display:none"></div>' +
      '<div id="onb-' + ue + '" style="display:none"></div>';
    h += sec('Connect an AI assistant', conn);
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
  // Parent: any account can be placed under another (sets managed_by), so the
  // hierarchy is editable after creation, not fixed - this is how you move a user
  // below another (SM104).
  {
    var owner = s.managed_by || s.created_by || '(top-level - no parent)';
    var ropts = '<option value="">move under&hellip;</option>' +
      allUsers.filter(function(x) { return x !== u; })
        .map(function(x) { return '<option value="' + escHtml(x) + '">' + escHtml(x) + '</option>'; }).join('');
    ac += '<div class="mg-line"><span class="mg-line-lbl">Parent</span>' +
      '<code class="mg-code">' + escHtml(owner) + '</code>' +
      '<select class="mg-inp" id="reassign-' + ue + '">' + ropts + '</select>' +
      '<button class="mg-btn mg-btn-sm" onclick="reassignUser(\'' + ue + '\')">Move</button></div>';
  }
  h += sec('Account', ac);

  // Sub-users nest INSIDE the parent's body, so collapsing the parent collapses
  // them too - the account tree expands as the hierarchy it is.
  if (kidsHtml) {
    h += sec('Sub-users', '<div class="mg-subusers" style="border-left:2px solid var(--mg-border,#e2e2e2);padding-left:0.6rem;display:flex;flex-direction:column;gap:0.4rem">' + kidsHtml + '</div>');
  }

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

// SM100: one connect entry point. Route the chosen client to the credential that
// works for it (web -> OAuth connect code, desktop -> token, code/script ->
// pairing brief) and show the reason inline, so there is no wrong-credential
// dead-end. Each branch calls the existing, unchanged flow.
function connectAs(user, client) {
  var hint = document.getElementById('connhint-' + user);
  if (client === 'web') {
    if (hint) hint.textContent = 'Claude.ai and ChatGPT are OAuth-only (no token field). You get a one-time connect code to paste at the sign-in prompt.';
    showConnector(user);
  } else if (client === 'desktop') {
    if (hint) hint.textContent = 'Claude Desktop connectors take a token. This generates one (username:token) for the connector settings.';
    generateCredential(user);
  } else {
    if (hint) hint.textContent = 'Claude Code and scripts connect over WebDAV/API (not MCP). This generates a single-use pairing brief to hand to the agent.';
    showOnboarding(user);
  }
}

function generateCredential(user) {
  mgConfirm('Generate a new credential for "' + user + '"? Any existing password or credential for this account will stop working.', { ok: 'Generate' }).then(function(__ok) {
    if (!__ok) return;
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
  });
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

// SM076: two-step, client-neutral connector setup. Step 1 is a styled
// instruction card (add the connector in any MCP web app, then enter the connect
// code at the OAuth prompt). We poll until the connection authenticates, then
// reveal Step 2 - the no-secret task prompt to paste to the assistant.
function showConnector(user) {
  var box = document.getElementById('onb-' + user);
  apiCall({ action: 'onboarding-web', username: user })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error, true); return; }
      box._prompt = d.assistant_prompt;
      box._code = d.connect_code;
      box._poll = (box._poll || 0) + 1;
      var ue = escHtml(user), dom = escHtml(d.domain), url = escHtml(d.connector_url), code = escHtml(d.connect_code);
      box.style.display = '';
      box.innerHTML =
        '<div class="mg-onb-card">' +
        '<div class="mg-onb-head"><strong>Step 1 &mdash; connect your AI assistant (do this once)</strong>' +
        '<button class="mg-btn mg-btn-sm" onclick="closeOnboarding(\'' + ue + '\')">Close</button></div>' +
        '<ol class="mg-onb-list">' +
        '<li>In your AI app, add a custom MCP connector with this URL:' +
        '<div class="mg-code-box"><div>Name&ensp;<code>' + dom + '</code></div>' +
        '<div>URL&ensp;<code>' + url + '</code></div></div>' +
        '<span class="mg-muted"><b>Claude.ai:</b> Settings &rarr; Connectors &rarr; Add custom connector. ' +
        '<b>ChatGPT:</b> Settings &rarr; Apps &rarr; Developer mode &rarr; create. ' +
        '<a href="/docs/ai-connector-setup" target="_blank">full guide</a></span></li>' +
        '<li>Open a <b>new chat</b> and use this prompt: <i>&ldquo;Enable the ' + dom +
        ' connector, and verify it is active by running whoami.&rdquo;</i></li>' +
        '<li>When it asks you to sign in, paste this one-time connect code:' +
        '<div class="mg-code-box mg-code-token"><code id="cc-' + ue + '">' + code + '</code>' +
        '<button class="mg-btn mg-btn-sm" onclick="copyConnectCode(\'' + ue + '\')">Copy</button></div>' +
        '<span class="mg-muted">Single-use, expires in 15&nbsp;min. If it expires before you use it, ' +
        '<a href="#" onclick="showConnector(\'' + ue + '\');return false;">get a fresh code</a>.</span></li>' +
        '</ol>' +
        '<div class="mg-onb-wait" id="conn-wait-' + ue + '">&#8987; waiting for Claude to connect&hellip;</div>' +
        '</div>' +
        '<div id="conn-step2-' + ue + '"></div>';
      showStatus('Connect code ready - follow Step 1 to connect Claude.ai.');
      pollConnector(user, box._poll, Date.now());
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

function pollConnector(user, gen, started) {
  var box = document.getElementById('onb-' + user);
  if (!box || box.style.display === 'none' || box._poll !== gen) return;   // closed/superseded
  apiCall({ action: 'credential-status', username: user })
    .then(function(d) {
      if (!box || box.style.display === 'none' || box._poll !== gen) return;
      if (d && d.ok && d.used) { revealPrompt(user); return; }
      var wait = document.getElementById('conn-wait-' + user);
      if (Date.now() - started > 180000) {
        if (wait) wait.innerHTML = '&nbsp;not detected yet &mdash; <a href="#" onclick="pollConnector(\'' +
          escHtml(user) + '\',' + gen + ',Date.now());return false;">check again</a>';
        return;
      }
      setTimeout(function() { pollConnector(user, gen, started); }, 3000);
    })
    .catch(function() { setTimeout(function() { pollConnector(user, gen, started); }, 5000); });
}

function revealPrompt(user) {
  var box = document.getElementById('onb-' + user);
  if (!box) return;
  var wait = document.getElementById('conn-wait-' + user);
  if (wait) wait.innerHTML = '<span class="mg-onb-ok">&#10003; connected</span>';
  var s2 = document.getElementById('conn-step2-' + user);
  if (s2) {
    s2.innerHTML = '<div class="mg-onb-card mg-onb-card-go">' +
      '<div class="mg-onb-head"><strong>Step 2 &mdash; paste this to Claude</strong> ' +
      '<span class="mg-muted">(no secret &mdash; safe in chat)</span></div>' +
      '<textarea class="mg-onb" readonly rows="7">' + escHtml(box._prompt) + '</textarea>' +
      '<div class="mg-line"><button class="mg-btn mg-btn-sm" onclick="copyPrompt(\'' + escHtml(user) + '\')">Copy prompt</button></div></div>';
  }
  showStatus('Connector authenticated - Claude is connected.');
}

function copyConnectCode(user) {
  var box = document.getElementById('onb-' + user);
  if (box && box._code && navigator.clipboard) navigator.clipboard.writeText(box._code).then(function() { showStatus('Connect code copied.'); });
}
function copyPrompt(user) {
  var box = document.getElementById('onb-' + user);
  if (box && box._prompt && navigator.clipboard) navigator.clipboard.writeText(box._prompt).then(function() { showStatus('Prompt copied.'); });
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
  var act = disabled ? 'account-enable' : 'account-disable';
  var go = function() {
    apiCall({ action: act, username: user })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error, true); return; }
      showStatus((disabled ? 'Enabled' : 'Disabled') + ' "' + user + '".');
      loadUsers();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
  };
  if (disabled) { go(); return; }
  mgConfirm('Disable "' + user + '"? They will be unable to authenticate anywhere until re-enabled.', { danger: true, ok: 'Disable' })
    .then(function(__ok) { if (__ok) go(); });
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
  mgConfirm('Delete user "' + user + '"? This cannot be undone.', { danger: true, ok: 'Delete' }).then(function(__ok) {
    if (!__ok) return;
    apiCall({ action: 'remove', username: user })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error, true); return; }
      showStatus('User "' + user + '" removed.');
      loadUsers();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
  });
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
  mgConfirm('Disable two-factor for "' + user + '"?', { danger: true, ok: 'Disable' }).then(function(__ok) {
    if (!__ok) return;
    apiCall({ action: 'mfa-disable', username: user })
    .then(function(d) {
      if (msg) { msg.textContent = d.ok ? 'Disabled.' : d.error; msg.className = 'mg-inline-msg ' + (d.ok ? 'mg-ok' : 'mg-err'); }
      loadUsers();
    })
    .catch(function(e) {});
  });
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
  // "Managed by you" (the operator) is the default and creates the account owned
  // by you - the same place "Reassign" moves a user "under the manager". A
  // top-level account has no owner. Other listed accounts can also own sub-users.
  var opts = '';
  if (ME) opts += '<option value="' + escHtml(ME) + '">Managed by you (' + escHtml(ME) + ')</option>';
  opts += '<option value="">Top-level (standalone, no owner)</option>';
  opts += parentList.filter(function(p) { return p !== ME; })
    .map(function(p) { return '<option value="' + escHtml(p) + '">under ' + escHtml(p) + '</option>'; }).join('');
  sel.innerHTML = opts;
  // Default to "Managed by you" on first populate (cur is '' before any choice,
  // which would otherwise select Top-level).
  sel.value = ( cur || (ME ? ME : '') );
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

function copyText(id) {
  var el = document.getElementById(id);
  if (el && navigator.clipboard) navigator.clipboard.writeText(el.textContent).then(function() { showStatus('Copied.'); });
}

loadUsers();
</script>

<!-- component styles consolidated into manager.css (SM109 phase 3) -->
