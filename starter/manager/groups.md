---
title: Groups
auth: manager
search: false
---

<div id="status" class="mg-status"></div>

<div class="mg-domain-note">
A <b>group</b> (<code>@name</code>) is a role: its <b>capabilities</b> (content,
themes, analytics, &hellip;) and <b>manager</b> status are assigned here, and every
member inherits the <b>union</b> of their groups' permissions. Add a user to a
group below or from the <a href="/manager/users">Users</a> page. A group flagged
<b>Manager group</b> grants full Manager-UI access to its members.
</div>

<div class="mg-card">
<div class="mg-card-header"><span class="mg-card-title">Groups</span></div>
<div id="groups-info" class="mg-acc-list">Loading...</div>
<details class="mg-add-card" style="margin:0.5rem;">
<summary>+ Add group</summary>
<div class="mg-card-body mg-new-group-row">
<input type="text" id="new-group-name" placeholder="new group name">
<button class="mg-btn mg-btn-primary" onclick="createGroup()">Add group</button>
</div>
</details>
</div>
<datalist id="all-users-list"></datalist>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';
var allGroups = {};   // {group: {label, manager, caps:{}, members:[]}}
var allUsers  = [];   // [username]

// The capability bools a group can carry (must match @CAP_KEYS in the users tool).
// Channels = WHERE you may operate; Actions = WHAT you may do. You need both.
var CHANNELS = [
  ['ui', 'Manager UI'],
  ['webdav', 'WebDAV transport'],
  ['api', 'Control API'],
  ['mcp', 'MCP connector']
];
var ACTIONS = [
  ['manage_content', 'Content (pages)'],
  ['manage_nav', 'Navigation'],
  ['manage_forms', 'Forms'],
  ['manage_themes', 'Themes'],
  ['manage_layouts', 'Layouts'],
  ['manage_config', 'Site config (+ plugins)'],
  ['manage_users', 'Users & groups'],
  ['analytics', 'Analytics (stats + audit)'],
  ['create_sub_users', 'Create sub-users'],
  ['delegate_sub_user_creation', 'Delegate sub-users']
];
var CAPS = CHANNELS.concat(ACTIONS);   // for counting

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
  var gp = apiCall({ action: 'group-settings-get' })
    .then(function(d) { return (d.ok && d.groups) ? d.groups : {}; })
    .catch(function() { return {}; });
  var up = apiCall({ action: 'list' })
    .then(function(d) { return (d.ok && d.users) ? d.users : []; })
    .catch(function() { return []; });
  Promise.all([gp, up]).then(function(res) {
    allGroups = res[0] || {};
    allUsers  = res[1] || [];
    var dl = document.getElementById('all-users-list');
    if (dl) dl.innerHTML = allUsers.map(function(u){ return '<option value="' + escHtml(u) + '">'; }).join('');
    renderGroups();
  }).catch(function(e) { showStatus('Failed to load groups: ' + e.message, true); });
}

// One accordion per group: capability toggles + manager switch, then a
// member-centric roster (who's in, type-to-add, remove) - not an all-users list.
function renderGroups() {
  var el = document.getElementById('groups-info');
  var keys = Object.keys(allGroups).sort();
  if (!keys.length) { el.innerHTML = '<div class="mg-empty" style="padding:0.75rem;">No groups defined.</div>'; return; }
  el.innerHTML = keys.map(function(g) {
    var info = allGroups[g] || {};
    var members = Array.isArray(info.members) ? info.members : [];
    var caps = info.caps || {};
    var ge = escHtml(g);
    var nOn = CAPS.filter(function(c){ return caps[c[0]]; }).length;
    var h = '<details class="mg-acc"><summary><span class="mg-acc-name">' + ge + '</span>' +
            '<span class="mg-acc-tags">' + (info.manager ? '<span class="mg-badge mg-badge-success">manager</span> ' : '') +
            nOn + ' capabilit' + (nOn === 1 ? 'y' : 'ies') + ' &middot; ' +
            members.length + ' member' + (members.length === 1 ? '' : 's') + '</span></summary>';
    h += '<div class="mg-acc-body">';
    h += '<div class="mg-line"><label style="min-width:5.5rem">Description</label>'
       + '<input type="text" class="mg-inp" style="flex:1" value="' + escHtml(info.description || '') + '" '
       + 'onchange="setDescription(\'' + ge + '\', this.value)" placeholder="what this role is for"></div>';

    var row = function(c) {
      return '<label class="mg-chk"><input type="checkbox"' + (caps[c[0]] ? ' checked' : '') +
        ' onchange="toggleSetting(\'' + ge + '\',\'' + c[0] + '\',this)"> ' + escHtml(c[1]) + '</label>';
    };
    h += '<div class="mg-sec">Channels <span style="font-weight:400;color:#888">— where members may operate</span></div>';
    h += '<div class="mg-checks">' + CHANNELS.map(row).join('') + '</div>';
    h += '<div class="mg-sec">Actions <span style="font-weight:400;color:#888">— what they may do</span></div>';
    h += '<div class="mg-checks">' + ACTIONS.map(row).join('') + '</div>';
    h += '<div class="mg-sec">Manager (transitional)</div><div class="mg-checks">';
    h += '<label class="mg-chk"><input type="checkbox"' + (info.manager ? ' checked' : '') +
         ' onchange="toggleSetting(\'' + ge + '\',\'manager\',this)"> <b>Manager group</b> '
         + '<span style="color:#888">(full Manager-UI access; being replaced by explicit capabilities)</span></label>';
    h += '</div>';

    h += '<div class="mg-sec">Members</div>';
    if (!members.length) {
      h += '<div class="mg-empty" style="padding:0.3rem 0;">No members yet.</div>';
    } else {
      h += '<div class="mg-checks">' + members.map(function(m) {
        return '<span class="mg-chip">' + escHtml(m) +
          ' <a href="#" onclick="removeMember(\'' + escHtml(m) + '\',\'' + ge + '\');return false;" title="Remove">&times;</a></span>';
      }).join('') + '</div>';
    }
    h += '<div class="mg-line"><input list="all-users-list" id="add-' + ge + '" class="mg-inp" placeholder="add a user&hellip;" style="max-width:14rem">' +
         ' <button class="mg-btn mg-btn-sm mg-btn-primary" onclick="addMember(\'' + ge + '\')">Add</button>' +
         '<span style="flex:1;"></span>' +
         '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="deleteGroup(\'' + ge + '\')">Delete group</button></div>';

    h += '</div></details>';
    return h;
  }).join('');
}

function setDescription(group, value) {
  apiCall({ action: 'group-settings-set', group: group, key: 'description', value: value })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error || 'Failed.', true); return; }
      if (allGroups[group]) allGroups[group].description = value;
      showStatus('Description saved.');
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

function toggleSetting(group, key, el) {
  var on = el.checked;
  apiCall({ action: 'group-settings-set', group: group, key: key, value: on ? 'on' : 'off' })
    .then(function(d) {
      if (!d.ok) { el.checked = !on; showStatus(d.error || 'Failed.', true); return; }
      if (allGroups[group]) {
        if (key === 'manager') { allGroups[group].manager = on; }
        else { allGroups[group].caps = allGroups[group].caps || {}; allGroups[group].caps[key] = on; }
      }
      showStatus(group + ': ' + key + ' ' + (on ? 'on' : 'off') + '.');
      renderGroups();
    })
    .catch(function(e) { el.checked = !on; showStatus('Error: ' + e.message, true); });
}

function addMember(group) {
  var inp = document.getElementById('add-' + group);
  var user = (inp && inp.value || '').trim();
  if (!user) { showStatus('Type a username to add.', true); return; }
  apiCall({ action: 'group-add', username: user, group: group })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error || 'Failed.', true); return; }
      showStatus('Added ' + user + ' to ' + group + '.');
      loadGroups();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

function removeMember(user, group) {
  apiCall({ action: 'group-remove', username: user, group: group })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error || 'Failed.', true); return; }
      showStatus('Removed ' + user + ' from ' + group + '.');
      loadGroups();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

function createGroup() {
  var ni = document.getElementById('new-group-name');
  var group = (ni.value || '').trim();
  if (!group) { showStatus('Group name required.', true); return; }
  apiCall({ action: 'group-create', group: group })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error, true); return; }
      showStatus('Group "' + group + '" created.');
      ni.value = '';
      loadGroups();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

function deleteGroup(group) {
  mgConfirm('Delete group "' + group + '"? Members lose the permissions it grants.',
    { danger: true, ok: 'Delete' }).then(function(__ok) {
    if (!__ok) return;
    apiCall({ action: 'group-delete', group: group })
      .then(function(d) {
        if (!d.ok) { showStatus(d.error || 'Failed.', true); return; }
        showStatus('Group "' + group + '" deleted.');
        loadGroups();
      })
      .catch(function(e) { showStatus('Error: ' + e.message, true); });
  });
}

loadGroups();
</script>
