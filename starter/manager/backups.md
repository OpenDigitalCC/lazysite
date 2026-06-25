---
title: Backups
auth: manager
search: false
---

<div id="status" class="mg-status"></div>

<p class="mg-domain-note">
Tarball snapshots of the site content (everything except the <code>lazysite/</code>
infrastructure), stored under <code>lazysite/backups/</code> and never served. A
<b>pre-install</b> snapshot is taken automatically the first time lazysite is
installed over an existing site, so a migration is always recoverable. Take a
<b>manual</b> snapshot before any risky change, and download one to keep off-site.
</p>

<div style="display:flex;gap:8px;margin-bottom:12px;align-items:center;">
<button class="mg-btn" onclick="loadBackups()">Refresh</button>
<button class="mg-btn mg-btn-primary" onclick="createBackup(this)">Create backup now</button>
</div>

<div class="mg-file-list" id="backup-list">
<div class="mg-file-item"><span class="mg-file-name">Loading...</span></div>
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
      renderBackups(d.backups || []);
    })
    .catch(function(e) { showStatus('Failed to load backups: ' + e.message, true); });
}

function renderBackups(list) {
  var el = document.getElementById('backup-list');
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
    html += '</div>';
  }
  el.innerHTML = html;
}

function createBackup(btn) {
  if (btn) btn.disabled = true;
  showStatus('Creating backup...');
  fetch(API + '?action=backup-create', { method: 'POST', credentials: 'same-origin' })
    .then(function(r) { return r.json(); })
    .then(function(d) {
      if (btn) btn.disabled = false;
      if (!d.ok) { showStatus(d.error, true); return; }
      showStatus('Backup created: ' + d.name);
      loadBackups();
    })
    .catch(function(e) { if (btn) btn.disabled = false; showStatus('Error: ' + e.message, true); });
}

loadBackups();
</script>
