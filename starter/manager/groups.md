---
title: Groups
auth: manager
search: false
---

<div id="status" class="mg-status"></div>

<div class="mg-note mg-note-info">
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
var CAP_GRANTS = {};        // SM427: {capability: plain sentence}, served
var channelServices = {};   // SM180: {channel: 0|1} - is each channel's SITE service enabled
// SM675: {capability: {plugin, name, enabled}} - which capabilities a PLUGIN
// owns, and whether it is on. A capability whose plugin is off grants nothing,
// and the grid used to offer it as an ordinary checkbox.
var capabilityPlugin = {};

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
  ['write_data', 'Data rows (named tables only)'],
  ['manage_briefs', 'Authoring briefs (write)'],
  ['housekeeping', 'Housekeeping'],
  ['purge', 'Purge'],
  ['manage_domains', 'Domains & site packages'],
  ['manage_config', 'Site config (+ plugins)'],
  // SM633: the five switches that decide whether the remote surfaces answer
  // at all. Beside site config in the grid because that is where an operator
  // looks for them, and a separate row because they are a separate grant.
  ['manage_services', 'Services (WebDAV/MCP/OAuth switches)'],
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
  // SM427: the same call already carries the channel->setting map (SM277) so
  // this page need not restate it; the grant SENTENCES ride with it for the
  // same reason - they are the part that must be right, and a copy here would
  // drift from the one in Capabilities.pm the moment either changed.
  var cs = fetch(API + '?action=channel-services').then(function(r) { return r.json(); })
    .then(function(d) {
      if (d.ok && d.grants) CAP_GRANTS = d.grants;
      if (d.ok && d.capability_plugin) capabilityPlugin = d.capability_plugin;
      return (d.ok && d.services) ? d.services : {};
    })
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
    ? ' <span class="mg-tag mg-tag mg-tag-off" title="This group grants capabilities but has no members, so it applies to no one. Add a member to put its access into effect.">no members</span>'
    : '';
  // SM576: a backend group exists to aggregate capabilities and other groups -
  // it is not something to give a person. Said on the summary line so the
  // distinction is visible without opening the card, which is where an operator
  // picks a group to put somebody in.
  // SM636: an ICON for BOTH states, not a badge for one.
  //
  // SM576 marked the backend groups and left the assignable ones bare, so the
  // list read as "some groups are special" rather than "every group is one of
  // two kinds". With SM631 seeding ten backend bundles beside nine roles, the
  // absence of a mark stopped meaning anything - a bare row could be a role or
  // a group listed before the flag existed.
  //
  // A person for "you can give this to somebody", a box for "this only holds
  // things". The word stays beside the icon: an icon alone is a guess for
  // anyone meeting the page for the first time, and this is the distinction
  // that decides whether an operator can act on the row at all.
  var backend = (info.assignable === false)
    ? ' <span class="mg-tag mg-tag mg-tag-off" title="A backend group: it aggregates capabilities and other groups. People are not added to it - they are added to a role that is nested inside it.">&#128230; backend</span>'
    : ' <span class="mg-tag mg-tag mg-tag-off" title="A role: this is the kind of group you give to a person. Assign it from an account\'s card on the Users page.">&#128100; role</span>';
  // SM608: shipped with the engine, or made here? The two carry different risk
  // on rename and delete - a shipped group is something the engine expects to
  // find, an operator's own is not - and the list gave no way to tell. A
  // TOOLTIP rather than a column, as the operator asked: it is a fact you want
  // when you are about to change something, not one you read every time.
  var origin = info.seeded
    ? ' <span class="mg-tag mg-tag mg-tag-off" title="Shipped with the engine. Renaming or deleting it may break something lazysite expects to find.">system</span>'
    : ' <span class="mg-tag mg-tag mg-tag-off" title="Created on this instance. Renaming or deleting it affects only what was built here.">yours</span>';

  // SM642: DISPLAY NAME (group name). Every seeded group already carries a
  // `label` and the page has always shown the bare name instead, so an operator
  // read `cap-content` where the store said "Capability: content". The group
  // NAME is never hidden - it is what every other surface, the CLI and the
  // audit trail use, and the person reading this list is administering access.
  // SM665: the group NAME moves into the tooltip rather than sitting in
  // brackets beside the label. SM642 put it in brackets so an operator could
  // see what every other surface calls the group; in a list of groups that is
  // the same word twice on every row. The requirement from SM617 is that the
  // technical name stay discoverable, not that it stay visible.
  var lbl  = info.label && info.label !== g ? info.label : '';
  var name = lbl
    ? '<span title="' + escHtml('Group "' + g + '"') + '">' + escHtml(lbl) + '</span>'
    : ge;

  return '<span class="mg-acc-name">' + name + '</span>' + recentDot(g) +
    (info.manager ? ' <span class="mg-tag mg-tag mg-tag-on">manager</span>' : '') +
    backend + origin + inert +
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
    // SM642: the label was readable, displayed and unsettable - group-settings-set
    // has accepted it since SM195, and nothing in the UI offered it. So an
    // operator saw a display name they could not change, and a group they made
    // themselves showed its bare name for ever.
    h += '<div class="mg-line"><label style="min-width:5.5rem">Display name</label>'
       + '<input type="text" class="mg-inp" style="flex:1" value="'
       + escHtml( info.label && info.label !== g ? info.label : '' ) + '" '
       + 'onchange="setLabel(\'' + ge + '\', this.value)" '
       + 'placeholder="' + ge + '"></div>';
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

    // SM673 follow-up: where an approved registration lands.
    //
    // Offered beside Kind because it is the same sort of statement - what the
    // group IS, not what it grants - and offered HERE rather than as a setting
    // in a config file because the operator deciding it needs to see the
    // capability grid immediately below, which is what the group hands over.
    //
    // Only on a group people can be put in. Flagging a backend group would
    // place accounts in something the picker will not offer, so the two would
    // disagree about who is in it.
    if (info.assignable !== false) {
      h += '<div class="mg-line"><label style="min-width:5.5rem">Registration</label>'
         + '<label class="mg-chk"><input type="checkbox"' + (info.registration ? ' checked' : '')
         + ' onchange="setRegistration(\'' + ge + '\', this.checked)">'
         + ' Add anonymous user registrations to this group'
         + ' <span style="font-weight:400;color:#888">— an approved request joins every group ticked here,'
         + ' and holds whatever they grant. Nothing ticked means an approved account joins nothing.</span>'
         + '</label></div>';
    }

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
      // SM675: the same statement about a different switch. A capability owned
      // by a plugin does nothing while that plugin is off - manage_data grants
      // no table access, manage_briefs no brief action.
      //
      // MARKED, NOT HIDDEN. Hiding the row would hide a grant that is still
      // recorded in the store: a group already holding it keeps holding it when
      // the plugin goes off, and the operator could then neither see, audit nor
      // revoke it. SM439, SM615 and SM668 all closed exactly that shape - there
      // must be no hidden case where access is active or potentially active.
      // Hiding would also make the grid's contents depend on plugin state, so
      // two instances with identical groups would show different rows.
      var owner = capabilityPlugin[c[0]];
      if (!isChannel && caps[c[0]] && owner && owner.enabled === false) {
        warn += ' <span class="mg-cap-dormant" title="Granted, but the '
          + escHtml(owner.name || owner.plugin) + ' plugin is switched OFF — this '
          + 'grant does nothing until a site admin enables it on the Plugin '
          + 'Config page.">&#9888;</span>';
      }
      // SM617: the TECHNICAL NAME on hover. The grid shows human labels, which
      // is right for choosing a grant - and every other surface names the same
      // capability in code: whoami and describe_capabilities answer
      // `manage_content`, the docs and the capability map use it, a partner
      // reports being refused by it, and a filing cites it. An operator
      // reading any of those had to map the label back by inference.
      //
      // On the label rather than the input, so hovering the row works. The
      // dormant-channel warning keeps its own title, which is more specific
      // and correctly wins on that icon.
      // SM427: WHAT THIS ACTUALLY HANDS OVER, in a sentence, on the row where
      // the decision is made.
      //
      // SM421 ruled that permission is the control - where a capability is
      // granted, every surface delivers it in full - which makes the GRANT the
      // decision point. That only works if the person granting knows what they
      // are granting, and the grid gave them a two-word label.
      //
      // FACTS, NOT WARNINGS, per the filing: "manage_forms lets this group
      // choose where a form's submissions are delivered, including to an
      // address or URL you have not pre-defined" is something an operator can
      // weigh. "Warning: dangerous!" is not, and it teaches people to click
      // past. The sentences live in Capabilities.pm beside the title, so this
      // page, describe_capabilities and the generated map say the same words.
      var grants = (CAP_GRANTS && CAP_GRANTS[c[0]]) || '';
      // An INFO AFFORDANCE, not a question mark in the sentence. This shipped
      // as a bare `?` against a class with no CSS, so every capability in the
      // grid read as "Manage forms ?" - the text asking a question rather than
      // a control offering an answer. The release manager's instruction was
      // exactly this: say the label, and put the detail behind an info button
      // or a tooltip.
      var info = grants
        ? ' <span class="mg-cap-what" tabindex="0" role="img"'
          + ' aria-label="What this grants: ' + escHtml(grants) + '"'
          + ' title="' + escHtml(grants) + '">i</span>'
        : '';

      // The technical name stays on the LABEL (SM617) and the sentence gets its
      // own marker: one hover answers "what is this called elsewhere", the
      // other "what does it do", and merging them would make a tooltip nobody
      // reads to the end.
      return '<label class="mg-chk" title="' + escHtml(c[0]) + '"><input type="checkbox"' + (caps[c[0]] ? ' checked' : '') +
        ' onchange="toggleSetting(\'' + ge + '\',\'' + c[0] + '\',this)"> ' + escHtml(c[1]) + warn + info + '</label>';
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
      // SM616: the warning spoke only about the FUTURE, and was displayed
      // directly above whoever is already in the group. "People are not added
      // to it directly", over a list of people, reads as "these should not be
      // here" or "these are not really members" - and neither is true. The
      // flag is enforced at group-add ONLY, deliberately: a rule that
      // retroactively revoked access would be a far more dangerous thing than
      // a labelling change, so anyone assigned before the group was marked
      // backend keeps it and everything it grants.
      //
      // The operator who asked assumed those members were invisible and that
      // removing one meant re-enabling the flag, removing, and disabling
      // again. None of that is so - removal is not gated at all - but nothing
      // on this page said it.
      var peopleIn = (members || []).filter(function(m) {
        return !Object.prototype.hasOwnProperty.call(allGroups, m);
      });
      h += '<div class="mg-cap-dormant" style="margin:0.25rem 0 0.4rem;">&#9888; '
         + 'This is a backend group, so people are not added to it from now on. '
         + 'Add a ROLE below (an assignable group) and everyone in that role inherits what this group carries.'
         + (peopleIn.length
             ? ' <strong>The ' + peopleIn.length + ' ' + (peopleIn.length === 1 ? 'person' : 'people')
               + ' already here keep it</strong>, and everything it grants &mdash; marking a group backend never '
               + 'takes access away. Remove any of them with the &times; on their name; you do not need to '
               + 'change this setting to do it.'
             : '')
         + '</div>';
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
         resetControlHtml(g, ge) +
         '</div>';

    h += '</div></details>';
    return h;
  }).join('');
}

// SM673 follow-up: the flag that decides where an approved registration lands.
// The server refuses it on a group whose capabilities this operator could not
// confer - ticking a box must not be a way around the ceiling that granting
// them one at a time obeys - so a refusal here is reported, not swallowed.
function setRegistration(group, on) {
  apiCall({ action: 'group-settings-set', group: group,
            key: 'registration', value: on ? 'on' : 'off' })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error || 'Could not set it.', true); loadGroups(); return; }
      showStatus(on
        ? '"' + group + '" will take new registrations.'
        : '"' + group + '" no longer takes new registrations.');
      loadGroups();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
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

// SM642: display only. It changes nothing about what the group grants or who
// is in it - the group NAME remains the identity on every other surface.
function setLabel(group, value) {
  apiCall({ action: 'group-settings-set', group: group, key: 'label', value: value })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error || 'Failed.', true); return; }
      if (allGroups[group]) allGroups[group].label = value;
      var sum = document.getElementById('gsum-' + group);
      if (sum) sum.innerHTML = groupSummaryInner(group);
      showStatus('Display name saved.');
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
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
// SM667: put a SEEDED group back to what it shipped with, from its own row.
//
// reset-groups restores every seeded group at once, from a shell. An operator
// looking at one drifted row needs neither: not a shell they may not have, and
// not nine groups reset to fix one.
//
// OFFERED ONLY ON A SEEDED GROUP. A group made here has no shipped default to
// return to, and offering the control would imply there was one.
function resetControlHtml(g, ge) {
  var info = allGroups[g] || {};
  if (!info.seeded) return '';
  return ' <button class="mg-btn mg-btn-sm" onclick="resetGroup(\'' + ge + '\')"'
    + ' title="Restore this group\'s capabilities, grant authority and nesting to'
    + ' what shipped with the engine. Members are kept.">Restore defaults</button>';
}

// THE DIFF IS THE CONFIRMATION, not a generic warning. An operator shown
// "Reset this group?" will not press it and will go and ask; one shown that the
// only change is `housekeeping` going off will press it. So the dry run runs
// first and its answer IS the question.
//
// Written in this page's own idiom - apiCall, showStatus, loadGroups, and
// mgConfirm as a PROMISE. The first version used fetch, mgShowWarning, loadAll
// and a callback: it passed a JS syntax check and would have thrown
// ReferenceError on the first click, because three of those four do not exist
// here.
function resetGroup(group) {
  apiCall({ action: 'group-reset', group: group })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error || 'Could not read the defaults.', true); return; }
      var on    = d.capabilities_on  || [];
      var off   = d.capabilities_off || [];
      var other = d.settings || [];
      if (!on.length && !off.length && !other.length) {
        showStatus('"' + group + '" already matches its shipped defaults.');
        return;
      }
      var lines = [];
      if (on.length)  lines.push('Turn ON: '  + on.map(capLabel).join(', '));
      if (off.length) lines.push('Turn OFF: ' + off.map(capLabel).join(', '));
      other.forEach(function(o) { lines.push(o.key + ': "' + o.from + '" to "' + o.to + '"'); });
      lines.push(d.members_kept + ' member' + (d.members_kept === 1 ? '' : 's') + ' kept.');
      return mgConfirm('Restore "' + group + '" to its shipped defaults?\n\n' + lines.join('\n'),
        { ok: 'Restore' }).then(function(okd) {
        if (!okd) return;
        return apiCall({ action: 'group-reset', group: group, apply: 1 })
          .then(function(a) {
            if (!a.ok) { showStatus(a.error || 'Reset refused.', true); return; }
            showStatus('"' + group + '" restored to its shipped defaults.');
            loadGroups();
          });
      });
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
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
