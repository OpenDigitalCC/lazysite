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
</div>

<div class="mg-card">
<div class="mg-card-header"><span class="mg-card-title">Add user</span></div>
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
<input type="text" id="new-username" placeholder="username" autocomplete="off">
</div>
<div class="mg-form-row">
<label>Groups</label>
<div style="flex:1">
<div class="mg-tokens" id="new-group-tokens"></div>
<!-- SM305: a select, like every other place a principal is named. The options
     are filled by renderNewUserGroups() once the group list has loaded. -->
<div class="mg-tokens-pick"><select id="new-group-input" class="mg-inp mg-principal-pick" style="max-width:14rem"><option value="">add a group&hellip;</option></select> <button class="mg-btn mg-btn-sm mg-btn-primary" onclick="addNewUserGroupFromInput()">Add</button></div>
</div>
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
</div>

<p class="mg-card-subtitle" style="margin:0.25rem 0.5rem;">
Manage <a href="/manager/groups">Groups</a> and <a href="/manager/sessions">Sessions &amp; keys</a>
on their own pages (under Access in the menu). You can still assign a user to
groups from each user's card below.
</p>

<!-- SM144: the full-width editor sheet. One consistent surface for editing ANY
     account, opened by a row's Configure button - the same size and position
     however deep the account sits in the tree. A coloured header names the
     account being configured. Click the backdrop or press Esc to close. -->
<div id="cfg-sheet" class="mg-sheet" hidden onclick="if(event.target===this)closeConfig()">
  <div class="mg-sheet-panel" role="dialog" aria-label="Account settings">
    <div class="mg-sheet-head">
      <span id="cfg-sheet-title" class="mg-sheet-title"></span>
      <button type="button" class="mg-sheet-close" onclick="closeConfig()" aria-label="Close settings">&times;</button>
    </div>
    <div class="mg-sheet-body" id="cfg-sheet-body"></div>
  </div>
</div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';
var DAV_BASE = location.origin + '/dav';
var allGroups = {};   // {group: [members]}
var uiGroups  = {};   // {group: true} - groups that grant the `ui` (manager) capability
var allUsers  = [];   // [username]
var groupLabels = {}; // {group: description-or-label} - for the add-user picker
var parentList = [];  // [username] - accounts that can own sub-users (create_sub_users)
// SM376: ONE OWNER for "does this account have a parent".
//
// This fallback was written out six times, and all six were wrong the same way.
// account-promote clears managed_by to the EMPTY STRING - a deliberate "no
// parent" - and created_by is immutable by design and never clears. In
// JavaScript "" is falsy, so `s.managed_by || s.created_by` reads a cleared
// parent as an absent one and re-parents the account to its creator forever.
//
// The visible result is an account that cannot be moved: the tree draws it
// under a creator that no longer manages it, while the "top level (no parent)"
// control is HIDDEN - correctly, by its own lights - because top_level is
// already true. So the operator sees a nested account and no way to un-nest it,
// which is exactly what it looks like when a control is missing.
//
// top_level is the ANSWER to this question, not a hint about it, so it wins.
function parentOfSettings(s) {
  s = s || {};
  if (s.top_level) return '';
  return s.managed_by || s.created_by || '';
}

var parentOf = {};    // {username: parent} - the managed_by/created_by hierarchy
var ME = '';          // the current operator's username (from whoami) - a valid owner
var amOperator = false; // SM194: is the current user a FULL operator (manage_users)? - gates the operator-only promote / scope-independent controls (the API enforces it regardless)
var channelServices = {};   // SM180: {channel: 0|1} - is each channel's SITE service enabled

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

// Load users + their settings + groups in ONE request (users-page), then render.
// Was three separate CGI calls (users-detail + group-settings-get + whoami) -
// each a Perl cold start on a plain-CGI host; folding them cuts page-load latency.
// SM103: recent-change markers - a dot on an account changed within the window.
var recentChanges = {};
function recentDot(key) {
  var c = recentChanges[key];
  if (!c) return '';
  var when = c.ts ? new Date(c.ts).toLocaleString() : '';
  var title = 'Changed ' + when + (c.user ? ' by ' + c.user : '')
            + (c.action ? ' (' + c.action + ')' : '');
  return ' <span class="mg-recent-dot" title="' + escHtml(title) + '" aria-label="'
       + escHtml(title) + '" style="display:inline-block;width:8px;height:8px;'
       + 'border-radius:50%;background:var(--mg-accent,#3a7bd5);vertical-align:middle;"></span>';
}

function loadUsers() {
  // SM180: load which channel services are enabled site-wide, so the per-user
  // capability grid can flag a granted channel whose service is OFF as dormant.
  // Fires in parallel; resolves well before a grid is opened on demand.
  fetch(API + '?action=channel-services').then(function(r) { return r.json(); })
    .then(function(d) { channelServices = (d.ok && d.services) || {}; }, function() { channelServices = {}; });
  // recent-changes is a TOP-LEVEL api action (as the Files page calls it) -
  // not a users sub-action; tunnelling it through action=users made the
  // sub-dispatcher reject it (field report: audit noise
  // "user-recent-changes ... Unknown action: recent-changes").
  fetch(API + '?action=recent-changes').then(function(r) { return r.json(); }).then(
    function(rc) { recentChanges = (rc && rc.ok && rc.changes) || {}; },
    function()   { recentChanges = {}; }
  ).then(function() {
  apiCall({ action: 'users-page' }).then(function(d) {
    if (!d.ok) { showStatus(d.error || 'Failed to load users.', true); return; }
    if (d.partner || d.me) ME = d.partner || d.me;
    // Groups: {group: members}, plus the add-user picker's purpose labels.
    var g = {};
    uiGroups = {};
    amOperator = false;
    if (d.groups) Object.keys(d.groups).forEach(function(name) {
      var info = d.groups[name] || {};
      g[name] = info.members || [];
      // Track which groups grant `ui` (manager/web-login access) so a group
      // change that would remove an account's last one can warn before it commits.
      if (info.caps && info.caps.ui) uiGroups[name] = true;
      // SM194: am I a full operator? - true if I'm in any group granting manage_users
      // (the same caps the payload already carries). Gates the operator-only controls.
      if (ME && info.caps && info.caps.manage_users && (info.members || []).indexOf(ME) !== -1) {
        amOperator = true;
      }
      groupLabels[name] = info.description
        || (info.label && info.label !== name ? info.label : '');
    });
    var rows = (d.users || []).filter(function(r) { return r && r.user != null; });
    allGroups = g;
    allUsers = rows.map(function(r) { return r.user; });
    parentOf = {};
    rows.forEach(function(r) {
      parentOf[r.user] = parentOfSettings(r.settings);
    });
    renderUsers(rows);
    parentList = rows.filter(function(r) { return r.settings && r.settings.create_sub_users; })
                     .map(function(r) { return r.user; }).sort();
    populateAddUserGroups();
    populateAddUserParents();
  }).catch(function(e) { showStatus('Failed to load users: ' + e.message, true); });
  });
}

var PERM_LABELS = {
  ui: 'Manager UI', webdav: 'WebDAV', api: 'API', mcp: 'MCP',
  manage_content: 'Content', manage_nav: 'Navigation', manage_forms: 'Forms',
  manage_themes: 'Themes', manage_layouts: 'Layouts', manage_data: 'Data tables',
  manage_domains: 'Domains & site packages', manage_config: 'Config + plugins',
  manage_users: 'Users & groups', analytics: 'Analytics', audit: 'Audit trail',
  notifications: 'Notifications', feedback: 'Agent feedback',
  read_submissions: 'Read submissions',
  create_sub_users: 'Create sub-users', delegate_sub_user_creation: 'Delegate sub-users'
};

// (Re)load the read-only channel x capability grid for a user. Fetches fresh
// every time the panel opens - so changes made on the Groups page show up
// without a full reload - and on demand via the Recheck button. `det` is the
// <details> element from ontoggle (absent when called from Recheck).
function loadPermGrid(user, det) {
  if (det && !det.open) return;   // ontoggle also fires on close
  var box = document.getElementById('permgrid-' + user);
  if (!box) return;
  box.innerHTML = '<span class="mg-muted">Checking&hellip;</span>';
  apiCall({ action: 'permissions-grid', username: user }).then(function(d) {
    if (!d.ok) { box.textContent = d.error || 'Failed to load.'; return; }
    box.innerHTML = renderPermGrid(d, user);
  }).catch(function(e) { box.textContent = 'Error: ' + e.message; });
}

function renderPermGrid(d, user) {
  var chans = d.channels || [], acts = d.actions || [], gb = d.granted_by || {};
  var surf = d.surface || {};   // SM197: cap -> { channel: 1 } where the cap has a real surface
  var lbl = function(k) { return PERM_LABELS[k] || k; };
  var by  = function(cap) { return (gb[cap] && gb[cap].length) ? gb[cap] : null; };
  var recheck = '<button class="mg-btn mg-btn-sm" style="margin-bottom:0.4rem" '
    + 'onclick="loadPermGrid(\'' + escHtml(user) + '\')">Recheck</button>';
  if (!d.groups || !d.groups.length) return recheck + '<p class="mg-empty">In no groups, so no capabilities.</p>';
  var h = recheck + '<table class="audit-table" style="font-size:12px"><thead><tr><th>Capability \\ Channel</th>';
  chans.forEach(function(c) {
    // SM180: a channel the user HAS but whose site service is off is dormant.
    var dormant = by(c) && channelServices[c] === 0;
    var warn = dormant ? ' <span class="mg-cap-dormant" title="The ' + escHtml(lbl(c))
      + ' service is switched OFF site-wide — this channel is granted but inert until an '
      + 'admin enables it in Settings → Services.">&#9888;</span>' : '';
    var title = by(c) ? (dormant ? 'granted, but the service is OFF site-wide' : 'granted by: ' + by(c).join(', ')) : 'not granted';
    h += '<th style="text-align:center" title="' + escHtml(title) + '">' + escHtml(lbl(c)) + warn + '</th>';
  });
  h += '</tr></thead><tbody>';
  acts.forEach(function(a) {
    h += '<tr><td title="' + (by(a) ? 'granted by: ' + by(a).join(', ') : 'not granted') + '">' + escHtml(lbl(a)) + '</td>';
    chans.forEach(function(c) {
      // SM197: a cell is a real "can do this here" only when the capability is
      // granted (by a group), the channel is held, AND the capability actually
      // has a surface on that channel. Granted-but-no-surface is shown distinctly
      // (a muted dash) rather than a green tick it never earned.
      var granted  = by(a) && by(c);
      var surfaced = !!(surf[a] && surf[a][c]);
      var by_tip = '';
      if (by(a)) by_tip += lbl(a) + ' via ' + by(a).join(', ');
      if (by(c)) by_tip += (by_tip ? '; ' : '') + lbl(c) + ' via ' + by(c).join(', ');
      var glyph, color, tip;
      if (granted && surfaced) { glyph = '✓'; color = '#1a7f37'; tip = by_tip; }
      else if (granted && !surfaced) {
        glyph = '–'; color = '#c9a227';
        tip = lbl(a) + ' has no ' + lbl(c) + ' surface — nothing to do through this channel'
            + (by_tip ? ' (' + by_tip + ')' : '');
      } else { glyph = '·'; color = '#ccc'; tip = by_tip || 'not granted'; }
      h += '<td style="text-align:center;color:' + color + '" title="'
        + escHtml(tip) + '">' + glyph + '</td>';
    });
    h += '</tr>';
  });
  h += '</tbody></table>';
  h += '<p class="mg-muted" style="font-size:11px;margin-top:0.3rem">&#10003; = the capability is granted, '
    + 'the channel is held, and the capability has a real surface on that channel; &ndash; = granted and the '
    + 'channel is held, but this capability does nothing on that channel; &middot; = not granted. '
    + 'Hover a cell or header for the granting group(s). Groups: ' + d.groups.map(escHtml).join(', ')
    + '. Manager-UI access is the <b>Manager UI</b> channel capability, granted through a group.</p>';
  return h;
}

// Every account below `u` in the managed_by hierarchy. Used to keep a user's
// own sub-tree (and itself) out of its "move under" targets - moving a parent
// under its own descendant would be a cycle (the server rejects it too).
function descendantsOf(u) {
  var kids = {};
  allUsers.forEach(function(x) {
    var p = parentOf[x] || '';
    (kids[p] = kids[p] || []).push(x);
  });
  var out = {}, stack = (kids[u] || []).slice();
  while (stack.length) {
    var v = stack.pop();
    if (out[v]) continue;
    out[v] = true;
    (kids[v] || []).forEach(function(w) { stack.push(w); });
  }
  return out;
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
  if (!rows.length) { list.innerHTML = '<div class="mg-empty" style="padding:0.75rem;">No users</div>'; rowsByUser = {}; closeConfig(); return; }
  var byUser = {};
  rows.forEach(function(r) { byUser[r.user] = r; });
  rowsByUser = byUser;   // the editor sheet reads accounts by name from here
  var kids = {}, roots = [];
  rows.forEach(function(r) {
    var s = r.settings || {};
    var parent = parentOfSettings(s);
    if (parent && byUser[parent] && parent !== r.user) {
      (kids[parent] = kids[parent] || []).push(r);
    } else {
      roots.push(r);
    }
  });
  function byName(a, b) { return String(a.user || '').localeCompare(String(b.user || '')); }
  function node(row, parentName) {
    var ch = (kids[row.user] || []).sort(byName);
    var kidsHtml = ch.map(function(c) { return node(c, row.user); }).join('');
    return renderUserRow(row, kidsHtml, ch.length, parentName);
  }
  list.innerHTML = roots.sort(byName).map(function(r) { return node(r, ''); }).join('');
  focusUserFromUrl();
  // Keep an open editor in sync with the fresh data (a save reloads the tree),
  // or close it if its account is gone (deleted / renamed).
  if (currentConfigUser) {
    if (rowsByUser[currentConfigUser]) renderConfigSheet(currentConfigUser);
    else closeConfig();
  }
}

// Deep-link support: /manager/users?user=NAME opens that user's row and centres
// it (e.g. clicking a user in the audit log).
function focusUserFromUrl() {
  var m = location.search.match(/[?&]user=([^&]+)/);
  if (!m) return;
  var u = decodeURIComponent(m[1].replace(/\+/g, ' '));
  var sel = (window.CSS && CSS.escape) ? CSS.escape(u) : u.replace(/"/g, '\\"');
  var el = document.querySelector('#user-list [data-user="' + sel + '"]');
  if (!el) return;
  // open every ancestor <details>, so a nested sub-user's row is visible
  for (var p = el.parentElement; p; p = p.parentElement) { if (p.tagName === 'DETAILS') p.open = true; }
  el.scrollIntoView({ block: 'center', behavior: 'smooth' });
  // A deep link lands you IN the target's editor, not just on its row.
  if (rowsByUser[u]) configureUser(u);
}

// Wrap a card section in a bounded box with a heading.
function sec(title, inner) {
  return '<div class="mg-box"><div class="mg-sec">' + title + '</div>' + inner + '</div>';
}

// SM144: the TREE ROW is for *selecting* an account. ONE line per account -
// name, role, lineage, and its Configure button, all visible at once (no
// expand-to-reveal step). Sub-users nest beneath as an indented tree; a parent
// row is a <details> so its sub-tree can be collapsed, but the row itself is
// always a single line. Editing opens in the full-width editor sheet
// (configureUser), which never nests - so the tree can go arbitrarily deep
// without the editor ever shrinking.
function renderUserRow(row, kidsHtml, subCount, parentName) {
  var u = row.user, s = row.settings || {}, ue = escHtml(u);
  var disabled = !!s.disabled;
  var ui       = (s.ui === undefined || s.ui === null) ? true : !!s.ui;
  var roleTag  = ui ? '<span class="mg-tag mg-tag-human">human</span>'
                    : '<span class="mg-tag mg-tag-auto">AI</span>';
  // Sub-user count only ("(+3)"). A sub-user's parent is obvious from the nesting,
  // so it is not repeated on the row.
  var lineChip = (subCount > 0)
    ? '<span class="mg-subcount" title="' + subCount + ' sub-user' + (subCount > 1 ? 's' : '') + '">(+' + subCount + ')</span>'
    : '';
  var comment  = s.comment || '';
  var note     = comment ? '<span class="mg-acc-note">' + escHtml(comment) + '</span>' : '';
  var flags    = disabled ? '<span class="mg-tag mg-tag-off">disabled</span>' : '';
  if (s.expires_at && s.expires_at < Date.now() / 1000) flags += ' <span class="mg-tag mg-tag-off">expired</span>';
  var isSub    = !!parentName;

  // The single row. Clicking the NAME EXPANDS/collapses the row - the same as
  // the disclosure triangle - because it is a plain span inside the parent's
  // <summary> (a leaf has nothing to expand, so its name is inert). Opening the
  // editor is ONLY the Configure button; the name no longer doubles as it (field
  // report: name-opens-modal was confusing). Configure stopPropagation keeps its
  // click from also toggling a parent's subtree.
  var nameEl = '<span class="mg-acc-name" title="' + ue + '">' + ue + '</span>';
  var line =
    nameEl + recentDot(u) + roleTag + lineChip + note +
    '<span class="mg-acc-spacer"></span>' + flags +
    '<button type="button" class="mg-btn mg-btn-sm mg-configbtn" data-cfg="' + ue + '" ' +
    'onclick="event.stopPropagation();configureUser(\'' + ue + '\')">Edit</button>';

  if (kidsHtml) {
    // A parent: collapsible subtree (starts collapsed), row stays one line.
    return '<details class="mg-acc' + (isSub ? ' mg-sub' : '') + '" data-user="' + ue + '">' +
      '<summary class="mg-acc-line">' + line + '</summary>' +
      '<div class="mg-acc-kids">' + kidsHtml + '</div></details>';
  }
  // A leaf: a plain one-line row (no disclosure triangle).
  return '<div class="mg-acc mg-acc-leaf' + (isSub ? ' mg-sub' : '') + '" data-user="' + ue + '">' +
    '<div class="mg-acc-line">' + line + '</div></div>';
}

// Build the "move under" options in TREE ORDER, indented by depth, so the
// dropdown shows the hierarchy. Skips the moving account and its descendants
// (excl), which cannot become its own parent.
function orderedParentOptions(self, excl) {
  var kids = {};
  Object.keys(rowsByUser).forEach(function(x) {
    var s = (rowsByUser[x] || {}).settings || {};
    var p = parentOfSettings(s);
    (kids[p] = kids[p] || []).push(x);
  });
  function byName(a, b) { return a.localeCompare(b); }
  var out = '';
  (function walk(parent, depth) {
    (kids[parent] || []).sort(byName).forEach(function(x) {
      if (x !== self && !excl[x]) {
        var pad = '';
        for (var i = 0; i < depth; i++) pad += '   ';
        out += '<option value="' + escHtml(x) + '">' + pad + (depth ? '↳ ' : '') + escHtml(x) + '</option>';
      }
      walk(x, depth + 1);   // still descend, so a deep tree shows fully
    });
  })('', 0);
  return out;
}

// The one-line "who is this" for an account. A sub-user names its parent; a
// top-level account names its role and how many sub-users hang off it. subCount
// is passed from the tree; when omitted (the editor header) it is derived.
function lineageText(user, parentName, subCount) {
  if (parentName) return 'sub-user of ' + escHtml(parentName);
  var n = (typeof subCount === 'number') ? subCount : childCountOf(user);
  return n > 0 ? ('top-level account · ' + n + ' sub-user' + (n > 1 ? 's' : '')) : 'top-level account';
}

function childCountOf(user) {
  var n = 0;
  Object.keys(rowsByUser).forEach(function(x) {
    var r = rowsByUser[x], s = (r && r.settings) || {};
    if (parentOfSettings(s) === user) n++;
  });
  return n;
}

// The EDITOR CONTENT (configuring): every setting for ONE account. Rendered into
// the full-width sheet by renderConfigSheet - never inline in the tree, so its
// width is identical at any depth. Only one account's settings exist in the DOM
// at a time, so the per-field ids stay unique.
function accountSettingsHtml(row) {
  var u = row.user, s = row.settings || {}, ue = escHtml(u);
  var webdav   = !!s.webdav;
  var ui       = (s.ui === undefined || s.ui === null) ? true : !!s.ui;
  var mcp      = !!s.mcp;
  var api      = !!s.api;
  var disabled = !!s.disabled;
  var scopes   = Array.isArray(s.dav_scopes) ? s.dav_scopes : [];   // SM155: group-derived
  var scope    = scopes.length === 1 ? scopes[0] : '';
  var comment  = s.comment || '';
  var h = '';

  // --- General (Type, Note, Email) - the first card ---
  // Type is a Human/AI switch (the `ui` setting), matching the Add-user form.
  var gen = '<div class="mg-line"><span class="mg-line-lbl">Type</span>' +
    '<select class="mg-inp" onchange="setUserType(\'' + ue + '\', this.value)">' +
    '<option value="human"' + (ui ? ' selected' : '') + '>Human (interactive login)</option>' +
    '<option value="ai"' + (ui ? '' : ' selected') + '>AI / backend (token)</option>' +
    '</select></div>';
  gen += '<div class="mg-line"><span class="mg-line-lbl">Note</span>' +
    '<input type="text" class="mg-inp mg-inp-wide" autocomplete="off" id="note-' + ue + '" value="' + escHtml(comment) +
    '" placeholder="what this account is for (e.g. Claude dav publisher)">' +
    '<button class="mg-btn mg-btn-sm mg-btn-primary" onclick="saveComment(\'' + ue + '\')">Save</button>' +
    '<span class="mg-inline-msg" id="notemsg-' + ue + '"></span></div>';
  gen += '<div class="mg-line"><span class="mg-line-lbl">Email</span>' +
    '<input type="email" class="mg-inp" id="email-' + ue + '" value="' + escHtml(s.email || '') +
    '" placeholder="for emailed setup / reset links">' +
    '<button class="mg-btn mg-btn-sm mg-btn-primary" onclick="saveEmail(\'' + ue + '\')">Save</button>' +
    '<span class="mg-inline-msg" id="emailmsg-' + ue + '"></span></div>';
  h += sec('General', gen);

  // --- Credentials (interactive login - human accounts only) ---
  // The connector credential (token) now lives in "Connect an AI assistant" below,
  // as one of the client choices (SM100), so it is not duplicated here.
  if (ui) {
    var cred = '<div class="mg-line"><span class="mg-line-lbl">Password</span>' +
      '<input type="password" class="mg-inp" id="pw-' + ue + '" placeholder="new password" autocomplete="new-password">' +
      '<button class="mg-btn mg-btn-sm mg-btn-primary" onclick="savePassword(\'' + ue + '\')">Save</button>' +
      '<span class="mg-inline-msg" id="pwmsg-' + ue + '"></span></div>';
    cred += '<div class="mg-line"><span class="mg-line-lbl">Setup link</span>' +
      '<button class="mg-btn mg-btn-sm" onclick="setupLink(\'' + ue + '\',false)">Generate setup link</button>' +
      (s.claim_pending
        ? '<button class="mg-btn mg-btn-sm" onclick="cancelSetupLink(\'' + ue + '\')">Cancel setup link</button> <span class="mg-muted">(link outstanding)</span>'
        : '') +
      '<span class="mg-help" title="A one-time link the user opens to set their OWN password (or mint their own token) - you never see it. Single-use, expires in 24h. Cancel it here to stop the URL working.">&#9432;</span></div>';
    cred += '<div class="mg-cred-reveal" id="setup-' + ue + '" style="display:none"></div>';
    var mfaCtl;
    if (s.mfa_enrolled) {
      mfaCtl = '<span class="mg-tag mg-tag-on">enabled</span> ' +
        '<button class="mg-btn mg-btn-sm" onclick="disable2fa(\'' + ue + '\')">Disable 2FA</button>';
    } else if (s.mfa_pending) {
      // Enrolled but never confirmed - not enforced. Offer to finish or drop it.
      mfaCtl = '<span class="mg-tag mg-tag-off">setup not confirmed</span> ' +
        '<button class="mg-btn mg-btn-sm mg-btn-primary" onclick="setup2fa(\'' + ue + '\')">Restart setup</button> ' +
        '<button class="mg-btn mg-btn-sm" onclick="cancel2fa(\'' + ue + '\')">Cancel setup</button>';
    } else {
      mfaCtl = '<span class="mg-tag mg-tag-off">not set up</span> ' +
        '<button class="mg-btn mg-btn-sm mg-btn-primary" onclick="setup2fa(\'' + ue + '\')">Set up 2FA</button>';
    }
    cred += '<div class="mg-line"><span class="mg-line-lbl">Two-factor</span>' + mfaCtl +
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
      '<span class="mg-muted">authenticate with an <strong>access token</strong> &mdash; generate one under <em>Connect an AI assistant</em> below' +
      (ui ? '; WebDAV also accepts this account&rsquo;s password, but a token is simpler'
          : ' (an AI account has no password)') + '</span></div>';
    // SM155: scope is a GROUP setting now (the domain binding). Show the
    // effective scope(s) read-only and point to Groups to change it.
    var scopeTxt = scopes.length ? scopes.join(', ') : 'whole site (minus denied paths)';
    wd += '<div class="mg-line"><span class="mg-line-lbl">Scope</span>' +
      '<span class="mg-muted">' + escHtml(scopeTxt) + ' &mdash; set on the account\'s <a href="/manager/groups">group(s)</a> (Domain binding)</span>' +
      '<span class="mg-help" title="A group\'s dav_scope confines its members\' WebDAV/API/MCP/UI access to a content root. Members of several scoped groups get the union.">&#9432;</span></div>';
    h += sec('WebDAV', wd);
  }

  // --- Connect an AI assistant (SM100: one flow - pick the client, get the one
  // credential that works; no three parallel controls to choose wrong between) ---
  // SM127: only offered for accounts that actually hold a remote-agent channel
  // (api/mcp). A manager/human account (ui, no api/mcp) is not connectable as an
  // AI - and the transport gate would refuse it anyway - so the panel is hidden,
  // removing the path by which a manager account was accidentally connected.
  if (mcp || api) {
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

  // --- Capabilities (read-only; derived from group membership, SM095) ---
  var pv = '<p class="mg-muted" style="margin:0 0 0.3rem">Derived from '
    + '<b>group membership</b> (above) &mdash; edit on the '
    + '<a href="/manager/groups">Groups</a> page.</p>'
    + '<details ontoggle="loadPermGrid(\'' + ue + '\', this)">'
    + '<summary style="cursor:pointer">Show the channel &times; capability grid</summary>'
    + '<div id="permgrid-' + ue + '" style="margin-top:0.4rem">&hellip;</div></details>';
  h += sec('Capabilities', pv);

  // --- Account ---
  var ac = '<div class="mg-line"><a href="/manager/audit?user=' + encodeURIComponent(u) + '">View this account\'s audit log &rarr;</a></div>';
  ac += '<div class="mg-line"><span class="mg-line-lbl">Expires</span>' +
    '<input type="date" class="mg-inp" id="exp-' + ue + '" value="' + expiryDate(s.expires_at) + '">' +
    '<button class="mg-btn mg-btn-sm" onclick="setExpiry(\'' + ue + '\')">Set</button>' +
    '<button class="mg-btn mg-btn-sm" onclick="clearExpiry(\'' + ue + '\')">Clear</button>' +
    '<span class="mg-inline-msg" id="expmsg-' + ue + '"></span></div>';
  ac += '<div class="mg-line"><span class="mg-line-lbl">Rename</span>' +
    '<input type="text" class="mg-inp" id="rename-' + ue + '" placeholder="new username" autocomplete="off">' +
    '<button class="mg-btn mg-btn-sm" onclick="renameUser(\'' + ue + '\')">Rename</button>' +
    '<span class="mg-inline-msg" id="renmsg-' + ue + '"></span></div>';
  // Parent: any account can be placed under another (sets managed_by), so the
  // hierarchy is editable after creation, not fixed - this is how you move a user
  // below another (SM104).
  {
    var owner = parentOfSettings(s) || '(top-level - no parent)';
    // Exclude the user itself and its whole sub-tree: those targets would form a
    // cycle (and the server refuses them), so don't offer them.
    var desc = descendantsOf(u);
    // Offer the targets in TREE ORDER, indented by depth, so the hierarchy is
    // visible in the dropdown (was a flat alphabetical list). Top-level first,
    // then each account's sub-tree beneath it; the account itself and its own
    // descendants are excluded (they would form a cycle).
    // SM194: "promote to top level" (clear managed_by) is an operator-only choice
    // IN this dropdown - not a separate button - offered only when the account is
    // not already top-level. reassignUser routes the sentinel to promoteUser.
    var ropts = '<option value="">move under&hellip;</option>' +
      ( (amOperator && !s.top_level)
        ? '<option value="__promote_top__">&uarr; top level (no parent)</option>' : '' ) +
      orderedParentOptions(u, desc);
    ac += '<div class="mg-line"><span class="mg-line-lbl">Parent</span>' +
      '<code class="mg-code">' + escHtml(owner) + '</code>' +
      '<select class="mg-inp" id="reassign-' + ue + '">' + ropts + '</select>' +
      '<button class="mg-btn mg-btn-sm" onclick="reassignUser(\'' + ue + '\')">Move</button></div>';
    // SM194: scope emancipation (operator-only, the API refuses a delegate regardless).
    // Deliberately SEPARATE from the parent move: "Independent of creator" lifts the
    // immutable created_by scope ceiling; promotion (clearing managed_by) does not,
    // and is the "top level (no parent)" choice in the Parent dropdown above.
    if (amOperator) {
      // SM233: the row label names the SUBJECT (what the control governs) and the
      // checkbox names the EFFECT. "Independent of creator" named a relationship
      // and left the reader to guess what it was independent FOR. The ceiling line
      // below is what actually makes the control legible - it shows whether the
      // toggle would change anything at all.
      var ceil = s.scope_ceiling || [];
      var ceilNote = s.scope_independent
        ? '<span class="mg-muted" style="font-size:0.85em">Nothing caps this account.</span>'
        : (ceil.length
            ? '<span class="mg-muted" style="font-size:0.85em">Currently capped by: '
              + ceil.map(escHtml).join(' &rarr; ') + '</span>'
            : '<span class="mg-muted" style="font-size:0.85em">Nothing caps this account (no creator).</span>');
      ac += '<div class="mg-line"><span class="mg-line-lbl">Content access</span>' +
        '<label class="mg-chk"><input type="checkbox"' + (s.scope_independent ? ' checked' : '') +
        ' onchange="toggleScopeIndependent(\'' + ue + '\', this.checked)"> Set by its own grants alone</label>' +
        '<span class="mg-help" title="Off: this account can reach at most what the account that created it can reach, and that limit follows the whole chain of creators. On: its access is decided by its own domain grants alone, so it may reach content its creator cannot. The record of who created it is unchanged either way. This is separate from the Parent setting above - moving an account to top level does not affect it.">&#9432;</span>' +
        '<span class="mg-inline-msg" id="scimsg-' + ue + '"></span></div>' +
        '<div class="mg-line"><span class="mg-line-lbl"></span>' + ceilNote + '</div>';
    }
  }
  h += sec('Account configuration', ac);

  // --- Danger zone (its own box, last): the irreversible / lock-out actions. ---
  var danger = '<div class="mg-line">' +
    '<button class="mg-btn mg-btn-sm" onclick="toggleDisabled(\'' + ue + '\',' + (disabled ? 'true' : 'false') + ')">' +
    (disabled ? 'Enable account' : 'Disable account') + '</button>' +
    '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="deleteUser(\'' + ue + '\')">Delete account</button></div>';
  h += '<div class="mg-box mg-box-danger"><div class="mg-sec">Danger zone</div>' + danger + '</div>';

  return h;
}

// --- The full-width editor sheet (SM144): configuring an account ---
// One consistent surface, the same size and position however deep the account
// sits in the tree. Driven by whichever Configure button was pressed.
var rowsByUser = {};            // username -> row, refreshed each render
var currentConfigUser = null;   // account whose sheet is open (null = closed)

// Open the editor sheet for an account, or toggle it shut if already open.
function configureUser(user) {
  if (currentConfigUser === user) { closeConfig(); return; }
  currentConfigUser = user;
  // Carry the open account in the URL so a full page refresh (F5) reopens it
  // (focusUserFromUrl reads ?user=). No navigation - just replaceState.
  try { history.replaceState(null, '', '/manager/users?user=' + encodeURIComponent(user)); } catch (e) {}
  renderConfigSheet(user);
}

// (Re)fill the sheet for the open account - also called after a reload so the
// editor reflects fresh data (a save reloads the tree underneath).
function renderConfigSheet(user) {
  var row = rowsByUser[user];
  if (!row) { closeConfig(); return; }
  var s = row.settings || {};
  var ui = (s.ui === undefined || s.ui === null) ? true : !!s.ui;
  var parent = parentOfSettings(s);
  var lineage = lineageText(user, parent, undefined);
  document.getElementById('cfg-sheet-title').innerHTML =
    'Configuring ' + escHtml(user) +
    ' <span class="mg-sheet-sub">' + (ui ? 'human' : 'AI') + ' &middot; ' + lineage + '</span>';
  document.getElementById('cfg-sheet-body').innerHTML = accountSettingsHtml(row);
  var sheet = document.getElementById('cfg-sheet');
  sheet.hidden = false;
  document.body.classList.add('mg-sheet-open');
  var b = document.getElementById('cfg-sheet-body'); if (b) b.scrollTop = 0;
  markConfiguring(user);
}

function closeConfig() {
  currentConfigUser = null;
  var sheet = document.getElementById('cfg-sheet');
  if (sheet) sheet.hidden = true;
  var body = document.getElementById('cfg-sheet-body'); if (body) body.innerHTML = '';
  document.body.classList.remove('mg-sheet-open');
  try { history.replaceState(null, '', '/manager/users'); } catch (e) {}
  markConfiguring(null);
}

// Highlight the Configure button of the account whose sheet is open.
function markConfiguring(user) {
  var btns = document.querySelectorAll('.mg-configbtn');
  for (var i = 0; i < btns.length; i++) {
    btns[i].classList.toggle('active', !!user && btns[i].getAttribute('data-cfg') === user);
  }
}

// Esc closes; a click on the backdrop (not the panel) closes. Wired once.
document.addEventListener('keydown', function(e) {
  if (e.key === 'Escape' && currentConfigUser) closeConfig();
});

// --- per-row actions ---

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

  // Proactive warning: removing an account from its LAST `ui`-granting group
  // takes away its manager interface / web login - it will only be reachable via
  // the API/MCP connector, and a browser sign-in lands on the "not permitted"
  // page. Confirm before committing a change that disables web login.
  if (!checked && uiGroups[group]) {
    var keepsUi = Object.keys(uiGroups).some(function(gg) {
      if (gg === group) return false;
      return (allGroups[gg] || []).indexOf(user) !== -1;
    });
    if (!keepsUi) {
      var go = window.confirm('Removing "' + user + '" from "' + group +
        '" will disable their manager interface (web login): "' + group +
        '" is their only group with Manager UI access. They will still be able to '
        + 'connect via the API / MCP connector. Continue?');
      if (!go) { el.checked = true; return; }   // operator cancelled - revert, no change
    }
  }

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

// SM155: per-account scope removed - the domain binding is a GROUP setting now
// (Groups page > Domain binding). setUserScope() is gone with it.

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
      box._expires = d.connect_code_expires_at || 0;
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
        '<button class="mg-btn mg-btn-sm" onclick="copyConnectCode(\'' + ue + '\')">Copy</button>' +
        '<button class="mg-btn mg-btn-sm" id="cc-regen-' + ue + '" onclick="regenerateConnectCode(\'' + ue + '\')">Regenerate</button></div>' +
        '<span class="mg-muted" id="cc-life-' + ue + '">Single-use.</span></li>' +
        '</ol>' +
        '<div class="mg-onb-wait" id="conn-wait-' + ue + '">&#8987; waiting for the AI agent to connect&hellip;</div>' +
        '</div>' +
        '<div id="conn-step2-' + ue + '"></div>';
      showStatus('Connect code ready - follow Step 1 to connect the agent.');
      tickConnectCode(user, box._poll);
      pollConnector(user, box._poll, Date.now());
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

// SM277 (deferred half of SM200): a connect code lives 30 minutes, and the
// panel used to print that as a fixed sentence - so a code that had lapsed
// looked exactly like one that had not, and the only way to get a fresh one was
// a link buried in the prose that re-entered the whole flow. Count the life
// down, say plainly when it has gone, and put Regenerate where the operator is
// already looking.
//
// The gen check is the same superseded-panel guard pollConnector uses: a second
// Regenerate must not leave the first timer writing into the panel.
function tickConnectCode(user, gen) {
  var box = document.getElementById('onb-' + user);
  if (!box || box.style.display === 'none' || box._poll !== gen) return;
  var life = document.getElementById('cc-life-' + user);
  if (!life) return;
  var left = box._expires ? Math.round(box._expires - Date.now() / 1000) : 0;
  if (!box._expires) {
    life.innerHTML = 'Single-use, expires in 30&nbsp;min.';
  } else if (left <= 0) {
    life.innerHTML = '<b>This code has expired.</b> Regenerate to get a fresh one - ' +
      'the connector you added stays as it is.';
    var cc = document.getElementById('cc-' + user);
    if (cc) cc.classList.add('mg-code-stale');
    return;                                  // stop ticking; nothing left to count
  } else if (left < 120) {
    life.innerHTML = 'Single-use, expires in <b>' + left + '&nbsp;s</b>.';
  } else {
    life.innerHTML = 'Single-use, expires in <b>' + Math.ceil(left / 60) + '&nbsp;min</b>.';
  }
  setTimeout(function() { tickConnectCode(user, gen); }, left > 0 && left < 120 ? 1000 : 15000);
}

// Re-mint IN PLACE: swap the code, restart the clock and the poll, and leave the
// rest of the card alone. Re-running showConnector would rebuild the whole panel
// and scroll the operator back to the top of a flow they are midway through.
function regenerateConnectCode(user) {
  var box = document.getElementById('onb-' + user);
  if (!box) return;
  var btn = document.getElementById('cc-regen-' + user);
  if (btn) { btn.disabled = true; btn.textContent = 'Working...'; }
  apiCall({ action: 'onboarding-web', username: user })
    .then(function(d) {
      if (btn) { btn.disabled = false; btn.textContent = 'Regenerate'; }
      if (!d.ok && d.error) { showStatus(d.error, true); return; }
      box._prompt = d.assistant_prompt;
      box._code = d.connect_code;
      box._expires = d.connect_code_expires_at || 0;
      box._poll = (box._poll || 0) + 1;      // supersede the old timer and poll
      var cc = document.getElementById('cc-' + user);
      if (cc) { cc.textContent = d.connect_code; cc.classList.remove('mg-code-stale'); }
      var wait = document.getElementById('conn-wait-' + user);
      if (wait) wait.style.display = '';
      tickConnectCode(user, box._poll);
      pollConnector(user, box._poll, Date.now());
      showStatus('Fresh connect code issued - the previous one no longer works.');
    })
    .catch(function(e) {
      if (btn) { btn.disabled = false; btn.textContent = 'Regenerate'; }
      showStatus('Error: ' + e.message, true);
    });
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
      '<div class="mg-onb-head"><strong>Step 2 &mdash; paste this to the agent</strong> ' +
      '<span class="mg-muted">(no secret &mdash; safe in chat)</span></div>' +
      '<textarea class="mg-onb" readonly rows="7">' + escHtml(box._prompt) + '</textarea>' +
      '<div class="mg-line"><button class="mg-btn mg-btn-sm" onclick="copyPrompt(\'' + escHtml(user) + '\')">Copy prompt</button></div>' +
      // SM200: the agent's tool list is fixed when a chat opens, so a connector
      // finished mid-conversation only surfaces in a fresh chat.
      '<div class="mg-muted" style="font-size:12px;margin-top:0.4rem">&#128161; If the agent ' +
      'doesn\'t see this site\'s tools, start a <b>new chat</b> and paste the prompt there - the ' +
      'tool list is fixed when a chat opens, so a connector finished mid-conversation only ' +
      'appears in a fresh chat.</div></div>';
  }
  showStatus('Connector authenticated - the agent is connected.');
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
  if (to === '__promote_top__') { promoteUser(user); return; }  // SM194: the top-level choice
  if (!to) { showStatus('Enter a parent username to reassign to.', true); return; }
  apiCall({ action: 'account-reassign', username: user, to: to })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error, true); return; }
      showStatus('Reassigned "' + user + '" to "' + to + '".');
      loadUsers();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

// SM194: promote to top level (clears managed_by). Operator-only; the created_by
// scope ceiling is unaffected - that is emancipated separately below.
function promoteUser(user) {
  mgConfirm('Promote "' + user + '" to top level? This clears its managing parent. '
    + 'Its content access is unchanged - that is the "Content access" setting, which '
    + 'is separate.',
    { ok: 'Promote' }).then(function(__ok) {
    if (!__ok) { return; }
    apiCall({ action: 'account-promote', username: user })
      .then(function(d) {
        if (!d.ok) { showStatus(d.error, true); return; }
        showStatus('Promoted "' + user + '" to top level.');
        loadUsers();
      })
      .catch(function(e) { showStatus('Error: ' + e.message, true); });
  });
}

// SM194: toggle scope emancipation (the explicit, separate lift of the created_by
// ceiling). Operator-only. created_by is never rewritten.
function toggleScopeIndependent(user, on) {
  apiCall({ action: 'account-scope-independent', username: user, value: on ? 1 : 0 })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error, true); loadUsers(); return; }  // reload to revert the checkbox
      showStatus('"' + user + '" content access is ' + (on
        ? 'now set by its own grants alone.'
        : 'limited again by the account that created it.'));
      loadUsers();   // SM233: refresh so the ceiling line reflects the new state
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); loadUsers(); });
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

// Cancel an outstanding setup link (clears the pending claim; the account and
// its current credential are untouched).
function cancelSetupLink(user) {
  mgConfirm('Cancel the outstanding setup link for "' + user + '"? Its URL stops working immediately. The account and its current credential are untouched.',
    { danger: true, ok: 'Cancel link' }).then(function(__ok) {
    if (!__ok) return;
    apiCall({ action: 'claim-cancel', username: user })
      .then(function(d) {
        if (!d.ok) { showStatus(d.error, true); return; }
        showStatus(d.cancelled ? ('Setup link for "' + user + '" cancelled.') : 'No outstanding link.');
        loadUsers();
      })
      .catch(function(e) { showStatus('Error: ' + e.message, true); });
  });
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

// Set up TOTP: enrol, then show a QR to scan, the copyable secret beneath (for
// manual entry), and the recovery codes behind a disclosure. All shown once.
function setup2fa(user) {
  var box = document.getElementById('mfa-' + user);
  function show(html) { if (box) { box.style.display = 'block'; box.innerHTML = html; } }
  show('<span class="mg-muted">Setting up&hellip;</span>');
  apiCall({ action: 'mfa-enroll', username: user })
    .then(function(d) {
      if (!d.ok) { show('<span class="mg-err">' + escHtml(d.error) + '</span>'); return; }
      var codes = (d.recovery_codes || []).map(escHtml).join('<br>');
      show('<div class="mg-muted">Scan this with an authenticator app (Google Authenticator, Aegis, 1Password&hellip;), then enter a code below to confirm. 2FA is <b>not on</b> until you confirm.</div>' +
        '<div class="mg-qr" id="mfaqr-' + user + '"><span class="mg-muted">rendering QR&hellip;</span></div>' +
        '<div class="mg-line"><span class="mg-line-lbl">Secret</span><code class="mg-code" id="mfasec-' + user + '">' + escHtml(d.secret) + '</code>' +
        '<button class="mg-btn mg-btn-sm" onclick="copyText(\'mfasec-' + user + '\')">Copy</button>' +
        '<span class="mg-help" title="Can\'t scan? Add the account manually in your app with this secret.">&#9432;</span></div>' +
        '<div class="mg-line"><span class="mg-line-lbl">Confirm</span>' +
        '<input type="text" inputmode="numeric" autocomplete="one-time-code" maxlength="6" class="mg-inp" id="mfacode-' + user + '" placeholder="6-digit code">' +
        '<button class="mg-btn mg-btn-sm mg-btn-primary" onclick="confirm2fa(\'' + user + '\')">Confirm &amp; enable</button>' +
        '<button class="mg-btn mg-btn-sm" onclick="cancel2fa(\'' + user + '\')">Cancel setup</button>' +
        '<span class="mg-inline-msg" id="mfacmsg-' + user + '"></span></div>' +
        '<details style="margin-top:0.4rem"><summary style="cursor:pointer">Show recovery codes</summary>' +
        '<div class="mg-muted">Store these now &mdash; each works once if you lose the authenticator. Shown only now.</div>' +
        '<div class="mg-code" style="white-space:normal">' + codes + '</div></details>');
      renderQR('mfaqr-' + user, d.otpauth_uri);
    })
    .catch(function(e) { show('<span class="mg-err">Error: ' + escHtml(e.message) + '</span>'); });
}

// Confirm a pending 2FA setup with a code from the app. Only now is 2FA turned
// on. If it is the operator's OWN account, sign them straight out to sign back
// in with 2FA - so they prove it works now, not discover a lockout tomorrow.
function confirm2fa(user) {
  var inp = document.getElementById('mfacode-' + user);
  var msg = document.getElementById('mfacmsg-' + user);
  function say(t, ok) { if (msg) { msg.textContent = t; msg.className = 'mg-inline-msg ' + (ok ? 'mg-ok' : 'mg-err'); } }
  var code = ((inp && inp.value) || '').replace(/\s/g, '');
  if (!code) { say('Enter the 6-digit code from your app.', false); return; }
  apiCall({ action: 'mfa-confirm', username: user, code: code })
    .then(function(d) {
      if (!d.ok) { say(d.error || 'That code did not match.', false); return; }
      if (user === ME) {
        say('2FA enabled. Signing you out to sign back in with it…', true);
        setTimeout(function() { location.href = '/login'; }, 1300);
      } else {
        say('2FA enabled for this account.', true);
        setTimeout(loadUsers, 800);
      }
    })
    .catch(function(e) { say('Error: ' + e.message, false); });
}

// Abandon a pending 2FA setup (clears the unconfirmed secret; nothing was ever
// enforced).
function cancel2fa(user) {
  apiCall({ action: 'mfa-disable', username: user })
    .then(function(d) {
      var box = document.getElementById('mfa-' + user);
      if (box) { box.style.display = 'none'; box.innerHTML = ''; }
      showStatus(d.ok ? 'Two-factor setup cancelled.' : (d.error || 'Cancel failed'), !d.ok);
      loadUsers();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

// Lazily load the bundled QR library (only when 2FA setup needs it), then run cb.
var _qrQueue = null;
function withQR(cb) {
  if (window.qrcode) { cb(); return; }
  if (_qrQueue) { _qrQueue.push(cb); return; }
  _qrQueue = [cb];
  var s = document.createElement('script');
  s.src = '/assets/qrcode.js';
  s.onload = function() { var q = _qrQueue; _qrQueue = null; q.forEach(function(f) { f(); }); };
  s.onerror = function() { var q = _qrQueue; _qrQueue = null; q.forEach(function(f) { f(true); }); };
  document.head.appendChild(s);
}

// Render an otpauth URI as an inline SVG QR. The library only COMPUTES the
// module matrix (qr.isDark); we build the SVG from integers here, so the URI is
// never inserted into the DOM as markup - no injection surface.
function renderQR(elId, text) {
  withQR(function(err) {
    var el = document.getElementById(elId);
    if (!el) return;
    if (err || !window.qrcode) { el.innerHTML = '<span class="mg-muted">(QR unavailable - add the account manually with the secret below)</span>'; return; }
    var qr = qrcode(0, 'M'); qr.addData(text); qr.make();
    var n = qr.getModuleCount(), cell = 4, m = 4, sz = (n + 2 * m) * cell, r = '';
    for (var y = 0; y < n; y++) for (var x = 0; x < n; x++) {
      if (qr.isDark(y, x)) r += '<rect x="' + ((x + m) * cell) + '" y="' + ((y + m) * cell) + '" width="' + cell + '" height="' + cell + '"/>';
    }
    el.innerHTML = '<svg xmlns="http://www.w3.org/2000/svg" width="' + sz + '" height="' + sz +
      '" viewBox="0 0 ' + sz + ' ' + sz + '" role="img" aria-label="two-factor QR code">' +
      '<rect width="' + sz + '" height="' + sz + '" fill="#fff"/><g fill="#000">' + r + '</g></svg>';
  });
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

// Add-user group picker: the same "pick none-or-many from a list" token widget
// the Groups page uses for members. newUserGroups holds the staged selection.
var newUserGroups = [];
function populateAddUserGroups() { renderNewUserGroups(); }
function renderNewUserGroups() {
  var toks = document.getElementById('new-group-tokens');
  var dl   = document.getElementById('new-group-input');
  if (!toks) return;
  toks.innerHTML = newUserGroups.length
    ? newUserGroups.map(function(g) {
        return '<span class="mg-token">' + escHtml(g) +
          '<button type="button" class="mg-token-x" title="Remove ' + escHtml(g) + '" onclick="removeNewUserGroup(\'' + escHtml(g) + '\')">&times;</button></span>';
      }).join('')
    : '<span class="mg-tokens-empty">No groups selected (optional).</span>';
  // SM305: the picker is a <select> now, so it carries a placeholder option and
  // its options are the groups NOT already staged - the same filter as before,
  // rendered into the control the rest of the manager uses.
  if (dl) {
    var avail = Object.keys(allGroups).sort().filter(function(g) { return newUserGroups.indexOf(g) === -1; });
    dl.innerHTML = '<option value="">add a group&hellip;</option>'
      + avail.map(function(g) { return '<option value="' + escHtml(g) + '">' + escHtml(g) + '</option>'; }).join('');
  }
}
function addNewUserGroup(g) { if (g && allGroups[g] && newUserGroups.indexOf(g) === -1) { newUserGroups.push(g); renderNewUserGroups(); } }
function removeNewUserGroup(g) { newUserGroups = newUserGroups.filter(function(x) { return x !== g; }); renderNewUserGroups(); }
function addNewUserGroupFromInput() {
  var inp = document.getElementById('new-group-input');
  var g = (inp && inp.value || '').trim();
  if (!g) return;
  if (!allGroups[g]) { showStatus('No such group: ' + g, true); return; }
  addNewUserGroup(g);
  if (inp) inp.value = '';
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
  // Flush a PENDING group selection: picking a group in the input and clicking
  // "Add user" without Enter/the picker's Add left the choice unstaged, so the
  // account was silently created with no groups (field report 2026-07-13). A
  // valid pending name is staged now; an unresolved one blocks the create
  // rather than being silently dropped.
  var ginp = document.getElementById('new-group-input');
  var pending = (ginp && ginp.value || '').trim();
  if (pending) {
    if (!allGroups[pending]) { showStatus('No such group: ' + pending + ' - fix or clear the group box.', true); return; }
    addNewUserGroup(pending);
    ginp.value = '';
  }
  var gl = newUserGroups.slice();
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
      // Follow-up steps must not fail silently: a refused call is thrown so
      // the catch below reports it (it also lands in the audit trail).
      var step = function(r, what) {
        return function() {
          return apiCall(r).then(function(d2) {
            if (!d2.ok) throw new Error(what + ': ' + d2.error);
          });
        };
      };
      var chain = Promise.resolve();
      gl.forEach(function(g) { chain = chain.then(step({ action: 'group-add', username: username, group: g }, 'group "' + g + '"')); });
      if (type === 'ai') {
        // backend account: no interactive login - the card then leads with
        // Generate setup link / onboarding brief. Capabilities (WebDAV etc.)
        // come from its groups; there is nothing per-account to grant.
        chain = chain.then(step({ action: 'settings-set', username: username, key: 'ui', value: 'off' }, 'interactive login off'));
      }
      chain.then(function() {
        var where = parent ? (' under "' + parent + '"') : '';
        showStatus(type === 'ai'
          ? ('AI account "' + username + '" added' + where + ' - open its card to Generate a setup link or onboarding brief.')
          : ('User "' + username + '" added' + where + ' - use Generate setup link in its card so they set their own password.'));
        document.getElementById('new-username').value = '';
        newUserGroups = []; renderNewUserGroups();
        loadUsers();
      }).catch(function(e) {
        showStatus('User "' + username + '" added, but a follow-up step failed - ' + e.message, true);
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
