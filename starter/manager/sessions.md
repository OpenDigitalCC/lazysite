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
Sessions are signed cookies, not server-side records, so there is no per-session
list yet (planned). What you <em>can</em> do now is invalidate them all at once by
rotating the signing secret - every cookie in circulation, including your own,
stops working and everyone must sign in again. Use this if a credential may have
leaked.
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
</script>
