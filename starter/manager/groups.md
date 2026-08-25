---
title: Groups
auth: manager
search: false
---

<div id="status" class="mg-status"></div>

<div class="mg-domain-note">
A <b>group</b> (<code>@name</code>) is a role: its <b>capabilities</b> (content,
themes, analytics, &hellip;) are assigned here, and every member inherits the
<b>union</b> of their groups' permissions. Add a user to a group below or from
the <a href="/manager/users">Users</a> page. Access to this Manager UI is the
<b>Manager UI</b> channel capability; full user administration is the
<b>Users &amp; groups</b> action.
</div>

<div class="mg-card">
<div class="mg-card-header"><span class="mg-card-title">Groups</span></div>
<div id="groups-info" class="mg-acc-list">Loading...</div>
</div>

<div class="mg-card">
<div class="mg-card-header"><span class="mg-card-title">Add group</span></div>
<div class="mg-card-body mg-new-group-row">
<input type="text" id="new-group-name" placeholder="new group name">
<button class="mg-btn mg-btn-primary" onclick="createGroup()">Add group</button>
</div>
</div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';
var allGroups = {};   // {group: {label, manager, assignable, caps:{}, members:[]}}
var allUsers  = [];   // [username]
var channelServices = {};   // SM180: {channel: 0|1} - is each channel's SITE service enabled

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
  ['manage_data', 'Data tables'],
  ['manage_briefs', 'Authoring briefs (write)'],
  ['housekeeping', 'Housekeeping — destroy what a copy survives'],
  ['purge', 'Purge — destroy what no copy survives'],
  ['manage_domains', 'Domains & site packages'],
  ['manage_config', 'Site config (+ plugins)'],
  ['manage_users', 'Users & groups'],
  ['analytics', 'Analytics (visitor stats)'],
  ['audit', 'Audit trail'],
  ['notifications', 'Notifications (bell)'],
  ['feedback', 'Agent feedback (MCP submit_feedback)'],
  ['read_submissions', 'Read form submissions (agent, API/MCP)'],
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
  // SM180: which channel services are enabled site-wide, so a granted channel
  // whose service is OFF can be flagged dormant. Top-level action (not a users
  // sub-action), fetched alongside; a failure just yields no hints.
  var cs = fetch(API + '?action=channel-services').then(function(r) { return r.json(); })
    .then(function(d) { return (d.ok && d.services) ? d.services : {}; })
    .catch(function() { return {}; });
  // SM103: recent-change markers - a change to a group's settings/capabilities
  // audits under the group name (a membership change audits as user@group and
  // shows on that user's row instead), so a dot by the group name catches it.
  var rc = fetch(API + '?action=recent-changes').then(function(r) { return r.json(); })
    .then(function(d) { return (d.ok && d.changes) ? d.changes : {}; })
    .catch(function() { return {}; });
  Promise.all([gp, up, cs, rc]).then(function(res) {
    allGroups = res[0] || {};
    allUsers  = res[1] || [];
    channelServices = res[2] || {};
    recentChanges = res[3] || {};
    // SM305: feed the shared picker. Groups are named plainly here (a nested
    // group is a member like any other), so renderGroups passes groupPrefix: ''.
    if (window.mgSetPrincipals) mgSetPrincipals(allUsers, Object.keys(allGroups));
    renderGroups();
  }).catch(function(e) { showStatus('Failed to load groups: ' + e.message, true); });
}

// SM103: recent-change marker - a small dot next to a group changed within the
// recent-changes window (default 24h), with a who/when/what tooltip.
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

// One accordion per group: channel + action capability toggles, then a
// member-centric roster (who's in, type-to-add, remove) - not an all-users list.
// The summary line for one group (name, manager badge, capability + member
// counts) - re-rendered in place on an edit, so a change never reloads the list.
function groupSummaryInner(g) {
  var info = allGroups[g] || {};
  var members = Array.isArray(info.members) ? info.members : [];
  var caps = info.caps || {};
  var ge = escHtml(g);
  var nOn = CAPS.filter(function(c) { return caps[c[0]]; }).length;
  // SM198: a group that grants capabilities but has NO members is inert - it
  // applies to no one (caps resolve only through membership). Flag it so the
  // create-group-then-forget-members trap is visible without opening the group.
  var inert = (nOn > 0 && members.length === 0)
    ? ' <span class="mg-badge mg-badge-muted" title="This group grants capabilities but has no members, so it applies to no one. Add a member to put its access into effect.">no members</span>'
    : '';
  // SM576: a backend group exists to aggregate capabilities and other groups -
  // it is not something to give a person. Said on the summary line so the
  // distinction is visible without opening the card, which is where an operator
  // picks a group to put somebody in.
  var backend = (info.assignable === false)
    ? ' <span class="mg-badge mg-badge-muted" title="A backend group: it aggregates capabilities and other groups. People are not added to it - they are added to a role that is nested inside it.">backend</span>'
    : '';
  return '<span class="mg-acc-name">' + ge + '</span>' + recentDot(g) +
    (info.manager ? ' <span class="mg-badge mg-badge-success">manager</span>' : '') +
    backend + inert +
    '<span class="mg-acc-spacer"></span>' +
    '<span class="mg-acc-tags">' +
    nOn + ' capabilit' + (nOn === 1 ? 'y' : 'ies') + ' &middot; ' +
    members.length + ' member' + (members.length === 1 ? '' : 's') + '</span>';
}
// SM496: the new-capabilities decision banner for one manager group.
function capLabel(cap) {
  for (var i = 0; i < CAPS.length; i++) if (CAPS[i][0] === cap) return CAPS[i][1];
  return cap;
}
function pendingBannerHtml(g) {
  var info = allGroups[g] || {};
  var pending = Array.isArray(info.pending) ? info.pending : [];
  if (!pending.length) return '';
  var ge = escHtml(g);
  var rows = pending.map(function(cap) {
    var ce = escHtml(cap);
    return '<div style="display:flex;align-items:center;gap:8px;margin:3px 0;">' +
      '<span style="flex:1;">' + escHtml(capLabel(cap)) + ' <code style="color:#888;">' + ce + '</code></span>' +
      '<button class="mg-btn mg-btn-sm mg-btn-primary" onclick="capDecide(\'' + ge + '\',\'' + ce + '\',true)">Grant</button>' +
      '<button class="mg-btn mg-btn-sm" onclick="capDecide(\'' + ge + '\',\'' + ce + '\',false)">Dismiss</button>' +
      '</div>';
  }).join('');
  return '<div class="mg-cap-dormant" style="margin:0.25rem 0 0.5rem;padding:8px 10px;">' +
    '&#9888; This release has ' + pending.length + ' capabilit' + (pending.length === 1 ? 'y' : 'ies') +
    ' this group has never decided on. Grant it, or dismiss it to record the "no" - ' +
    'either way the warning stops; a dismissed capability can be granted later from the grid below.' +
    rows + '</div>';
}
function capDecide(g, cap, on) {
  apiCall({ action: 'group-settings-set', group: g, key: cap, value: on ? 'on' : 'off' })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error || 'Decision failed', true); return; }
      var info = allGroups[g] || {};
      if (info.caps) info.caps[cap] = !!on;
      info.pending = (info.pending || []).filter(function(c) { return c !== cap; });
      var box = document.getElementById('gpend-' + escHtml(g));
      if (box) box.innerHTML = pendingBannerHtml(g);
      // The grid checkbox and summary refresh in place - the page's idiom is
      // that an edit never reloads the list. The tick appears on next open of
      // the card, which renderGroups draws from allGroups (already updated).
      refreshGroupSummary(g);
      showStatus((on ? 'Granted ' : 'Dismissed ') + capLabel(cap) + ' for @' + g);
    })
    .catch(function(e) { showStatus('Decision failed: ' + e.message, true); });
}
function refreshGroupSummary(g) {
  var s = document.getElementById('gsum-' + escHtml(g));
  if (s) s.innerHTML = groupSummaryInner(g);
}

// SM198: inline warning HTML for an inert group (grants capabilities but has no
// members, so it applies to no one), or '' when the group is fine. Recomputed in
// place on add/remove-member so it appears/clears without a full reload.
function inertWarnHtml(g) {
  var info = allGroups[g] || {};
  var members = Array.isArray(info.members) ? info.members : [];
  var caps = info.caps || {};
  var nOn = CAPS.filter(function(c) { return caps[c[0]]; }).length;
  if (!(nOn > 0 && members.length === 0)) return '';
  return '<div class="mg-cap-dormant" style="margin:0.25rem 0 0.4rem;">&#9888; '
    + 'This group grants ' + nOn + ' capabilit' + (nOn === 1 ? 'y' : 'ies')
    + ' but has no members, so it applies to no one. Add a member below to put its access into effect.</div>';
}
function refreshGroupInert(g) {
  var iw = document.getElementById('ginert-' + escHtml(g));
  if (iw) iw.innerHTML = inertWarnHtml(g);
}

function renderGroups() {
  var el = document.getElementById('groups-info');
  var keys = Object.keys(allGroups).sort();
  if (!keys.length) { el.innerHTML = '<div class="mg-empty" style="padding:0.75rem;">No groups defined.</div>'; return; }
  el.innerHTML = keys.map(function(g) {
    var info = allGroups[g] || {};
    var members = Array.isArray(info.members) ? info.members : [];
    var caps = info.caps || {};
    var ge = escHtml(g);
    var h = '<details class="mg-acc" data-group="' + ge + '"><summary class="mg-acc-line" id="gsum-' + ge + '">' +
            groupSummaryInner(g) + '</summary>';
    h += '<div class="mg-acc-body">';
    h += '<div class="mg-line"><label style="min-width:5.5rem">Description</label>'
       + '<input type="text" class="mg-inp" style="flex:1" value="' + escHtml(info.description || '') + '" '
       + 'onchange="setDescription(\'' + ge + '\', this.value)" placeholder="what this role is for"></div>';
    // SM576 part 3: the role/backend decision, offered where the group is
    // described rather than buried with the capability grid - it is a statement
    // about what the group IS, not about what it grants.
    h += '<div class="mg-line"><label style="min-width:5.5rem">Kind</label>'
       + '<label class="mg-chk"><input type="checkbox"' + (info.assignable === false ? '' : ' checked')
       + ' onchange="setAssignable(\'' + ge + '\', this.checked)"> Assignable to people'
       + ' <span style="font-weight:400;color:#888">— unticked, it is a backend group that only aggregates capabilities and other groups</span>'
       + '</label></div>';

    var row = function(c, isChannel) {
      // SM180: a channel that IS granted but whose SITE service is switched off
      // is dormant - it does nothing until an admin enables the service. Flag it
      // so the grant is not silently inert.
      var warn = '';
      if (isChannel && caps[c[0]] && channelServices[c[0]] === 0) {
        warn = ' <span class="mg-cap-dormant" title="Granted, but the ' + escHtml(c[1])
          + ' service is switched OFF site-wide — a site admin must enable it in '
          + 'Settings → Services for this grant to take effect.">&#9888;</span>';
      }
      return '<label class="mg-chk"><input type="checkbox"' + (caps[c[0]] ? ' checked' : '') +
        ' onchange="toggleSetting(\'' + ge + '\',\'' + c[0] + '\',this)"> ' + escHtml(c[1]) + warn + '</label>';
    };
    // SM496: capabilities this release has that this manager group has never
    // decided on - server-derived (info.pending). The decision is offered at
    // the TOP of the card, where the work starts, and both buttons write
    // through the same group-settings-set path as every toggle below, so the
    // SM195 ceiling and the audit trail apply unchanged. Dismiss records an
    // explicit "no" (the capability stops warning everywhere); the grid below
    // shows it unticked and it can be granted later like anything else.
    h += '<div id="gpend-' + ge + '">' + pendingBannerHtml(g) + '</div>';
    h += '<div class="mg-sec">Channels <span style="font-weight:400;color:#888">— where members may operate</span></div>';
    h += '<div class="mg-checks">' + CHANNELS.map(function(c) { return row(c, true); }).join('') + '</div>';
    h += '<div class="mg-sec">Actions <span style="font-weight:400;color:#888">— what they may do</span></div>';
    h += '<div class="mg-checks">' + ACTIONS.map(function(c) { return row(c, false); }).join('') + '</div>';

    // SM165: domain access lives on the DOMAIN (each domain names the groups
    // allowed to manage it, on the Domains page), so the group editor no longer
    // shows it here.

    // SM198: capabilities apply only through membership, so a group with caps
    // but no members does nothing. Warn inline, right where the fix is (Members).
    // Always-present container so add/remove-member can refresh it in place.
    h += '<div class="mg-sec">Members</div>';
    // SM576: name the alternative where the operator is about to be refused,
    // not after. A backend group takes GROUPS; a person goes in a role.
    if (info.assignable === false) {
      h += '<div class="mg-cap-dormant" style="margin:0.25rem 0 0.4rem;">&#9888; '
         + 'This is a backend group, so people are not added to it directly. '
         + 'Add a ROLE below (an assignable group) and everyone in that role inherits what this group carries.</div>';
    }
    h += '<div id="ginert-' + ge + '">' + inertWarnHtml(g) + '</div>';
    h += '<div class="mg-tokens" id="gm-' + ge + '">' + memberPillsHtml(members, ge) + '</div>';
    // SM305: a real <select>, not a datalist. The datalist suggested known names
    // and still accepted anything typed over it, so a typo created a membership
    // referring to nobody. A group cannot contain itself, so it is excluded from
    // its own list.
    //
    // No onchange here, deliberately: selecting a name POSTS on this page, and a
    // select fires change while a keyboard user arrows through the options. The
    // Add button stays as the commit, so choosing a name and committing it are
    // separate acts - which is also what the Files picker does, where the
    // equivalent onchange only adds a chip and nothing is written until Save.
    h += '<div class="mg-tokens-pick">' +
         mgPrincipalSelect({ id: 'add-' + ge, groupPrefix: '', exclude: g,
                             placeholder: 'add a user or group…',
                             style: 'max-width:14rem' }) +
         ' <button class="mg-btn mg-btn-sm mg-btn-primary" onclick="addMember(\'' + ge + '\')">Add</button>' +
         '<span style="flex:1;"></span>' +
         '<span id="gd-' + ge + '">' + deleteControlHtml(members, ge) + '</span>' +
         '</div>';

    h += '</div></details>';
    return h;
  }).join('');
}

function setAssignable(group, on) {
  apiCall({ action: 'group-settings-set', group: group, key: 'assignable', value: on ? 'on' : 'off' })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error || 'Failed.', true); return; }
      if (allGroups[group]) allGroups[group].assignable = !!on;
      refreshGroupSummary(group);
      renderGroups();
      showStatus(on ? '@' + group + ' can be given to people.' : '@' + group + ' is now a backend group.');
    })
    .catch(function(e) { showStatus('Failed: ' + e.message, true); });
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

// SM155: save a group's domain binding (dav_scope / home_domain). The server
// normalises + validates; an invalid value is reported and the field reverts.
function setGroupBinding(group, key, value) {
  apiCall({ action: 'group-settings-set', group: group, key: key, value: value })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error || 'Failed.', true); loadGroups(); return; }
      if (allGroups[group]) allGroups[group][key] = value;
      showStatus(group + ': ' + key + (value ? ' set' : ' cleared') + '.');
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
      // Update just this group's summary counts / manager badge in place - no
      // list reload (the checkbox already reflects the new state).
      refreshGroupSummary(group);
      refreshGroupInert(group);   // SM198: caps changed -> inert status may change
    })
    .catch(function(e) { el.checked = !on; showStatus('Error: ' + e.message, true); });
}

// Members render as removable pills (the shared "pick none-or-many" style).
function memberPillsHtml(members, ge) {
  if (!members.length) return '<span class="mg-tokens-empty">No members yet.</span>';
  return members.map(function(m) {
    // SM121: a member may itself be a GROUP (compound groups) - link and tag it
    // as such so a nested group is not mistaken for a user.
    var isGroup = Object.prototype.hasOwnProperty.call(allGroups, m);
    var href = isGroup ? '/manager/groups' : '/manager/users?user=' + encodeURIComponent(m);
    var tag = isGroup ? ' <span class="mg-muted" title="a nested group — its members inherit this group’s access">(group)</span>' : '';
    return '<span class="mg-token"><a href="' + href + '">' + escHtml(m) + '</a>' + tag +
      '<button type="button" class="mg-token-x" title="Remove ' + escHtml(m) + '" onclick="removeMember(\'' + escHtml(m) + '\',\'' + ge + '\')">&times;</button></span>';
  }).join('');
}
// Delete only when empty - removing a group with members strips their permissions.
function deleteControlHtml(members, ge) {
  return members.length
    ? '<span class="mg-muted" title="Remove all members before deleting this group">Remove members to delete</span>'
    : '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="deleteGroup(\'' + ge + '\')">Delete group</button>';
}
// Re-render just one group's members + delete control in place (no full reload).
function refreshGroupMembers(group) {
  var members = (allGroups[group] && allGroups[group].members) || [];
  var gm = document.getElementById('gm-' + group);
  var gd = document.getElementById('gd-' + group);
  if (gm) gm.innerHTML = memberPillsHtml(members, group);
  if (gd) gd.innerHTML = deleteControlHtml(members, group);
  refreshGroupInert(group);   // SM198: membership changed -> inert status may change
}

function addMember(group) {
  var inp = document.getElementById('add-' + group);
  var name = (inp && inp.value || '').trim();
  if (!name) { showStatus('Choose a user or group to add.', true); return; }
  // SM121: adding a known GROUP nests it (its members inherit this group's
  // access); anything else is added as a user.
  var isGroup = Object.prototype.hasOwnProperty.call(allGroups, name) && name !== group;
  var body = isGroup
    ? { action: 'group-nest', sub: name, parent: group }
    : { action: 'group-add', username: name, group: group };
  apiCall(body)
    .then(function(d) {
      if (!d.ok) { showStatus(d.error || 'Failed.', true); return; }
      // Update the local cache and re-render just this group's members in place.
      var m = allGroups[group].members = allGroups[group].members || [];
      if (m.indexOf(name) === -1) m.push(name);
      if (inp) inp.value = '';
      refreshGroupMembers(group); refreshGroupSummary(group);
      showStatus((isGroup ? 'Nested group ' + name + ' in ' : 'Added ' + name + ' to ') + group + '.');
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

function removeMember(user, group) {
  apiCall({ action: 'group-remove', username: user, group: group })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error || 'Failed.', true); return; }
      var m = allGroups[group].members = allGroups[group].members || [];
      var i = m.indexOf(user); if (i !== -1) m.splice(i, 1);
      refreshGroupMembers(group); refreshGroupSummary(group);
      showStatus('Removed ' + user + ' from ' + group + '.');
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
