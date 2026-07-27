---
title: Sessions
auth: manager
search: false
---

<div id="status" class="mg-status"></div>

<div class="mg-card">
<div class="mg-card-header"><span class="mg-card-title">Active sessions</span></div>
<div class="mg-card-body">
<p class="mg-card-subtitle" style="margin:0 0 0.5rem">
Everyone signed in right now (sessions expire 24&nbsp;hours after sign-in).
<strong>Sign out</strong> ends one session; <strong>Sign out everywhere</strong>
ends all of a user's sessions. The user can sign straight back in.
</p>
<div id="session-list"><div class="mg-empty" style="padding:0.75rem;">Loading...</div></div>
</div>
</div>

<div class="mg-card">
<div class="mg-card-header"><span class="mg-card-title">Active keys</span></div>
<div class="mg-card-body">
<p class="mg-card-subtitle" style="margin:0 0 0.5rem">
Access keys let AI agents and publishing tools reach this site without a browser
&mdash; on the API, the MCP connector, or WebDAV. Each account below holds a live
key. <strong>Revoke key</strong> stops it working on the next request; the
account is left intact and can be issued a fresh key later from its card on the
<a href="/manager/users">Users</a> page.
</p>
<div id="key-list"><div class="mg-empty" style="padding:0.75rem;">Loading...</div></div>
</div>
</div>

<div class="mg-card">
<div class="mg-card-header"><span class="mg-card-title">Log out everyone</span></div>
<div class="mg-card-body">
<p class="mg-card-subtitle" style="margin:0 0 0.5rem">
The nuclear option: rotating the signing secret invalidates every cookie in
circulation, including your own, and everyone must sign in again. Use this if
a credential may have leaked.
</p>
<button class="mg-btn mg-btn-danger" onclick="rotateAuthSecret()">Log out all users</button>
</div>
</div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';

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

function loadSessions() {
  fetch(API + '?action=sessions-list')
    .then(function(r) { return r.json(); })
    .then(renderSessions)
    .catch(function(e) {
      var box = document.getElementById('session-list');
      if (box) box.innerHTML = '<div class="mg-empty" style="padding:0.75rem;">Error: ' + escHtml(e.message) + '</div>';
    });
}

function renderSessions(d) {
  var box = document.getElementById('session-list');
  if (!box) return;
  if (!d.ok) {
    box.innerHTML = '<div class="mg-empty" style="padding:0.75rem;">' + escHtml(d.error || 'Failed to load sessions.') + '</div>';
    return;
  }
  var rows = d.sessions || [];
  if (!rows.length) {
    box.innerHTML = '<div class="mg-empty" style="padding:0.75rem;">No active sessions.' +
      ' Sessions started before this lazysite version cannot be listed, but' +
      ' <em>Log out everyone</em> below still ends them.</div>';
    return;
  }
  var h = '<div style="overflow-x:auto"><table class="audit-table"><thead><tr>' +
    '<th>User</th><th>Signed in</th><th>From IP</th><th>Device</th><th></th>' +
    '</tr></thead><tbody>';
  rows.forEach(function(s) {
    var when  = s.issued ? new Date(s.issued * 1000).toLocaleString() : '';
    var badge = s.current ? ' <span class="mg-tag mg-tag-on">this session</span>' : '';
    h += '<tr>' +
      '<td><a href="/manager/users?user=' + encodeURIComponent(s.user) + '">' + escHtml(s.user) + '</a>' + badge + '</td>' +
      '<td>' + escHtml(when) + '</td>' +
      '<td>' + escHtml(s.ip || '') + '</td>' +
      '<td class="mg-muted" style="max-width:20rem;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" title="' +
        escHtml(s.ua || '') + '">' + escHtml(s.ua || '') + '</td>' +
      '<td style="white-space:nowrap">' +
      '<button class="mg-btn mg-btn-sm" onclick="revokeSession(\'' + escHtml(s.sid) + '\',\'' +
        escHtml(s.user) + '\',' + (s.current ? 'true' : 'false') + ')">Sign out</button> ' +
      '<button class="mg-btn mg-btn-sm" onclick="revokeUser(\'' + escHtml(s.user) + '\')">Sign out everywhere</button>' +
      '</td></tr>';
  });
  h += '</tbody></table></div>';
  box.innerHTML = h;
}

function revokeSession(sid, user, current) {
  var msg = current
    ? 'Sign out your OWN current session? You will be signed out immediately and must sign in again.'
    : 'Sign out this session of "' + user + '"? Their cookie stops working immediately; the account is untouched and they can sign in again.';
  mgConfirm(msg, { danger: true, ok: 'Sign out' }).then(function(__ok) {
    if (!__ok) return;
    fetch(API + '?action=session-revoke', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ sid: sid })
    })
      .then(function(r) { return r.json(); })
      .then(function(d) {
        if (!d.ok) { showStatus(d.error || 'Sign-out failed', true); return; }
        if (current) { setTimeout(function() { location.href = '/login'; }, 800); return; }
        showStatus('Session signed out.');
        loadSessions();
      })
      .catch(function(e) { showStatus('Error: ' + e.message, true); });
  });
}

function revokeUser(user) {
  mgConfirm('Sign "' + user + '" out everywhere? Every session of theirs ends immediately, including any started before session listing existed. The account is untouched; they can sign in again.',
    { danger: true, ok: 'Sign out everywhere' }).then(function(__ok) {
    if (!__ok) return;
    fetch(API + '?action=user-revoke', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: user })
    })
      .then(function(r) { return r.json(); })
      .then(function(d) {
        if (!d.ok) { showStatus(d.error || 'Sign-out failed', true); return; }
        showStatus('"' + user + '" signed out everywhere.');
        loadSessions();
      })
      .catch(function(e) { showStatus('Error: ' + e.message, true); });
  });
}

function rotateAuthSecret() {
  mgConfirm('This will sign every user (including you) out immediately. Every cookie currently in circulation will stop working. Proceed?', { danger: true, ok: 'Sign everyone out' }).then(function(__ok) {
    if (!__ok) return;
    fetch(API + '?action=rotate-auth-secret', { method: 'POST' })
      .then(function(r) { return r.json(); })
      .then(function(d) {
        if (!d.ok) { showStatus(d.error || 'Rotation failed', true); return; }
        if (typeof mgShowWarning === 'function') mgShowWarning(d.message || 'All sessions invalidated.', false);
        setTimeout(function() { location.href = '/login'; }, 1200);
      })
      .catch(function(e) { showStatus('Error: ' + e.message, true); });
  });
}

// --- SM145: active access keys (AI / API / WebDAV credentials) ---
function loadKeys() {
  fetch(API + '?action=keys-list')
    .then(function(r) { return r.json(); })
    .then(renderKeys)
    .catch(function(e) {
      var box = document.getElementById('key-list');
      if (box) box.innerHTML = '<div class="mg-empty" style="padding:0.75rem;">Error: ' + escHtml(e.message) + '</div>';
    });
}

function renderKeys(d) {
  var box = document.getElementById('key-list');
  if (!box) return;
  if (!d.ok) {
    box.innerHTML = '<div class="mg-empty" style="padding:0.75rem;">' + escHtml(d.error || 'Failed to load keys.') + '</div>';
    return;
  }
  var rows = d.keys || [];
  if (!rows.length) {
    box.innerHTML = '<div class="mg-empty" style="padding:0.75rem;">No active keys. AI / publishing accounts get a key from the <strong>Connect</strong> or <strong>Generate credential</strong> action on their Users-page card.</div>';
    return;
  }
  var h = '<div style="overflow-x:auto"><table class="audit-table"><thead><tr>' +
    '<th>Account</th><th>Key for</th><th>Issued</th><th>Status</th><th>Lifetime</th><th></th>' +
    '</tr></thead><tbody>';
  rows.forEach(function(k) {
    var chans = (k.channels || []).map(function(c) {
      return '<span class="mg-tag mg-tag-auto">' + escHtml(c) + '</span>';
    }).join(' ');
    var when = k.issued_at ? new Date(k.issued_at * 1000).toLocaleString() : '<span class="mg-muted">unknown</span>';
    // Status. "in use" means the key has been used at least once SINCE issue -
    // a historical fact, not "live right now". For an EXPIRED token that use is
    // in the past, so showing a green "in use" beside "token expired" (and
    // "renews on use" in the Lifetime column) reads as a contradiction. When the
    // token has lapsed, lead with that and say when it was last used instead of
    // claiming it is in use. SM212: a renew-on-use token lapses only after a full
    // token_ttl of INACTIVITY (the slide never resurrects an expired token).
    var now = Date.now() / 1000;
    var tokenExpired = k.token_expires_at && k.token_expires_at < now;
    var status;
    if (tokenExpired) {
      status = '<span class="mg-tag mg-tag-off">token expired</span>';
      if (k.used_at) status += ' <span class="mg-muted" style="font-size:0.85em">last used '
        + escHtml(new Date(k.used_at * 1000).toLocaleDateString()) + '</span>';
    } else {
      status = k.in_use
        ? '<span class="mg-tag mg-tag-on">in use</span>'
        : '<span class="mg-tag mg-tag-auto">not used yet</span>';
      if (k.token_expires_at) status += ' <span class="mg-tag mg-tag-auto">expires '
        + escHtml(new Date(k.token_expires_at * 1000).toLocaleDateString()) + '</span>';
    }
    if (k.disabled) status += ' <span class="mg-tag mg-tag-off">account disabled</span>';
    if (k.expires_at && k.expires_at < now) status += ' <span class="mg-tag mg-tag-off">account expired</span>';
    // SM212: token lifetime. Default (24h) is a hard window from issue; a longer
    // TTL (max 30d) also RENEWS ON USE, so an actively-used key never lapses.
    var cur = k.token_ttl ? String(k.token_ttl) : '';
    var known = { '': 1, '604800': 1, '2592000': 1 };
    var ttlSel = '<select class="mg-inp" style="width:auto;padding:2px 4px" ' +
      'onchange="setTokenTtl(\'' + escHtml(k.user) + '\', this.value)">' +
      '<option value=""' + (!cur ? ' selected' : '') + '>24h (default)</option>' +
      '<option value="7d"' + (cur === '604800' ? ' selected' : '') + '>7 days</option>' +
      '<option value="30d"' + (cur === '2592000' ? ' selected' : '') + '>30 days</option>' +
      (cur && !known[cur]
        ? '<option value="' + cur + 's" selected>' + Math.round(cur / 86400) + ' days (custom)</option>'
        : '') +
      '</select>';
    var slides = k.token_ttl
      ? (tokenExpired
          ? '<div class="mg-muted" style="font-size:0.8em" title="This key renews its lifetime on each use, but it went unused for longer than that lifetime, so it has lapsed. Rotate the key to issue a fresh token.">lapsed after inactivity</div>'
          : '<div class="mg-muted" style="font-size:0.8em" title="An in-use token has its expiry renewed on each use, so it never lapses while the key is active. Revoke to end it.">renews on use</div>')
      : '';
    h += '<tr>' +
      '<td><a href="/manager/users?user=' + encodeURIComponent(k.user) + '">' + escHtml(k.user) + '</a></td>' +
      '<td>' + chans + '</td>' +
      '<td>' + when + '</td>' +
      '<td>' + status + '</td>' +
      '<td style="white-space:nowrap">' + ttlSel + slides + '</td>' +
      '<td style="white-space:nowrap">' +
      '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="revokeKey(\'' + escHtml(k.user) + '\')">Revoke key</button>' +
      '</td></tr>';
  });
  h += '</tbody></table></div>';
  box.innerHTML = h;
}

// SM212: set an account's machine-token lifetime (token_ttl). Empty = 24h
// default (hard window); a longer value also enables sliding renewal. Takes
// effect on the NEXT exchange/rotate and (for the sliding part) on next use.
function setTokenTtl(user, value) {
  // settings-set is a 'users' SUB-action, not a top-level API action: route it
  // through action=users (as the Users page does). Calling it as a top-level
  // action is rejected by the dispatcher ("Unknown action: settings-set").
  fetch(API + '?action=users', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ action: 'settings-set', username: user, key: 'token_ttl', value: value })
  })
    .then(function(r) { return r.json(); })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error || 'Could not set the token lifetime', true); loadKeys(); return; }
      showStatus(value
        ? 'Token lifetime for "' + user + '" set (renews on use). Applies on the next credential issue/rotate.'
        : 'Token lifetime for "' + user + '" reset to the 24h default.');
      loadKeys();
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}

function revokeKey(user) {
  mgConfirm('Revoke the access key for "' + user + '"? Its API / connector / WebDAV credential stops working on the next request. The account is untouched and can be issued a new key from its Users-page card.',
    { danger: true, ok: 'Revoke key' }).then(function(__ok) {
    if (!__ok) return;
    fetch(API + '?action=key-revoke', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: user })
    })
      .then(function(r) { return r.json(); })
      .then(function(d) {
        if (!d.ok) { showStatus(d.error || 'Revoke failed', true); return; }
        showStatus('Key for "' + user + '" revoked.');
        loadKeys();
      })
      .catch(function(e) { showStatus('Error: ' + e.message, true); });
  });
}

loadSessions();
loadKeys();
</script>
