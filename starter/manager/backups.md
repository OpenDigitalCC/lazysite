---
title: Backups
auth: manager
search: false
---

<div id="status" class="mg-status"></div>

<p class="mg-muted">
Backups are whole-site snapshots for disaster recovery &mdash; the full-system
kind includes configuration and secrets. Day-to-day <b>content versioning</b>
(per-file history, diff and restore) lives in the <b>Content history</b> plugin.
</p>

<div class="mg-card">
<div class="mg-card-header"><span class="mg-card-title">Content backups</span>
<button class="mg-btn mg-btn-sm" onclick="loadBackups()">Refresh</button></div>
<div class="mg-card-body">
<p class="mg-muted">
Snapshots of the site <b>content</b> (everything except the <code>lazysite/</code>
infrastructure), stored under <code>lazysite/backups/</code> and never served. A
<b>pre-install</b> snapshot is taken automatically the first time lazysite is
installed over an existing site. <b>Restore</b> writes a snapshot's files back over
the site (files created since are left in place), takes a <b>prerestore</b> safety
snapshot first, and clears the affected page caches.
</p>
<div style="margin-bottom:12px;">
<button class="mg-btn mg-btn-primary" onclick="createBackup(this)">Create content backup</button>
</div>
<div class="mg-file-list" id="content-list">
<div class="mg-file-item"><span class="mg-file-name">Loading&hellip;</span></div>
</div>
</div>
</div>

<div class="mg-card">
<div class="mg-card-header"><span class="mg-card-title">Full-system backups</span></div>
<div class="mg-card-body">
<p class="mg-muted">
A <b>complete</b> snapshot &mdash; content <i>plus</i> configuration, accounts and
secrets, themes and layouts &mdash; for disaster recovery and for <b>migrating a
site to another domain</b> (build on a temporary domain, then move content, config
and accounts to the final one). Because it carries the auth secrets and its restore
overwrites accounts and config, <b>restore is a system-user operation from the
shell</b>, not a button here:
</p>
<pre class="mg-code" style="white-space:pre-wrap;">install.pl --restore-full &lt;file&gt; --docroot &lt;path&gt; --domain &lt;new-domain&gt;</pre>
<p class="mg-muted">Download one to keep off-site. Anyone who can download a full
backup effectively holds the site's secrets &mdash; treat it accordingly.</p>
<div style="margin-bottom:12px;">
<button class="mg-btn mg-btn-primary" onclick="createFullBackup(this)">Create full-system backup</button>
</div>
<div class="mg-file-list" id="full-list">
<div class="mg-file-item"><span class="mg-file-name">Loading&hellip;</span></div>
</div>
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
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function fmtSize(b) {
  if (b < 1024) return b + ' B';
  if (b < 1048576) return (b / 1024).toFixed(1) + ' KB';
  return (b / 1048576).toFixed(1) + ' MB';
}

function fmtDate(epoch) {
  if (!epoch) return '';
  return new Date(epoch * 1000).toISOString().replace('T', ' ').replace(/:\d\d\..*/, '') + ' UTC';
}

function loadBackups() {
  fetch(API + '?action=backup-list', { credentials: 'same-origin' })
    .then(function(r) { return r.json(); })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error, true); return; }
      var all = d.backups || [];
      renderBackups(all.filter(function(b) { return b.scope !== 'full'; }), 'content-list', true);
      renderBackups(all.filter(function(b) { return b.scope === 'full'; }), 'full-list', false);
    })
    .catch(function(e) { showStatus('Failed to load backups: ' + e.message, true); });
}

// restorable = content (in-app restore button); full backups download only.
function renderBackups(list, elId, restorable) {
  var el = document.getElementById(elId);
  if (!el) return;
  if (!list.length) {
    el.innerHTML = '<div class="mg-file-item"><span class="mg-file-name mg-empty">No backups yet</span></div>';
    return;
  }
  var html = '';
  for (var i = 0; i < list.length; i++) {
    var b = list[i];
    var badge = b.kind === 'preinstall' ? 'mg-badge-success' : 'mg-badge-muted';
    html += '<div class="mg-file-item">';
    html += '<span class="mg-file-name" style="font-family:var(--mg-mono);font-size:0.8rem;">' + escHtml(b.name) + '</span>';
    html += '<span class="mg-badge ' + badge + '">' + escHtml(b.kind) + '</span>';
    html += '<span class="mg-file-meta">' + fmtSize(b.size) + ' &middot; ' + fmtDate(b.mtime) + '</span>';
    html += '<a class="mg-btn mg-btn-sm" href="' + API + '?action=backup-download&name=' + encodeURIComponent(b.name) + '">&#11015; Download</a>';
    if (restorable) {
      html += '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="restoreBackup(\'' + escHtml(b.name) + '\', this)">Restore</button>';
    } else {
      html += '<span class="mg-file-meta">restore via CLI</span>';
    }
    html += '</div>';
  }
  el.innerHTML = html;
}

function restoreBackup(name, btn) {
  var msg = 'Restore "' + name + '"?\n\nIts files are written back over the site '
          + '(newer files stay). A prerestore safety snapshot is taken first.';
  var go = function(ok) {
    if (!ok) return;
    if (btn) btn.disabled = true;
    showStatus('Restoring ' + name + '...');
    fetch(API + '?action=backup-restore&name=' + encodeURIComponent(name),
          { method: 'POST', credentials: 'same-origin' })
      .then(function(r) { return r.json(); })
      .then(function(d) {
        if (btn) btn.disabled = false;
        if (!d.ok) { showStatus(d.error, true); return; }
        showStatus('Restored ' + d.restored + ' (safety snapshot: ' + d.safety
                 + ', ' + d.cache_cleared + ' cached page(s) cleared).');
        loadBackups();
      })
      .catch(function(e) { if (btn) btn.disabled = false; showStatus('Error: ' + e.message, true); });
  };
  if (typeof mgConfirm === 'function') { mgConfirm(msg, { danger: true, ok: 'Restore' }).then(go); }
  else { go(window.confirm(msg)); }
}

function createBackup(btn) { _create(btn, '', 'Backup created: '); }

function createFullBackup(btn) {
  var msg = 'Create a full-system backup?\n\nIt includes configuration, accounts '
          + 'and secrets. Keep the downloaded file secure.';
  var go = function(ok) { if (ok) _create(btn, '&scope=full', 'Full-system backup created: '); };
  if (typeof mgConfirm === 'function') { mgConfirm(msg, { ok: 'Create' }).then(go); }
  else { go(window.confirm(msg)); }
}

function _create(btn, extra, okMsg) {
  if (btn) btn.disabled = true;
  showStatus('Creating backup...');
  fetch(API + '?action=backup-create' + extra, { method: 'POST', credentials: 'same-origin' })
    .then(function(r) { return r.json(); })
    .then(function(d) {
      if (btn) btn.disabled = false;
      if (!d.ok) { showStatus(d.error, true); return; }
      showStatus(okMsg + d.name);
      loadBackups();
    })
    .catch(function(e) { if (btn) btn.disabled = false; showStatus('Error: ' + e.message, true); });
}

loadBackups();
</script>
