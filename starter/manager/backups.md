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
<div class="mg-card-header"><span class="mg-card-title">Site packages</span>
<button class="mg-btn mg-btn-sm" onclick="loadBackups()">Refresh</button></div>
<div class="mg-card-body">
<p class="mg-muted">
A <b>site package</b> is one domain's site &mdash; its content, nav, the referenced
theme/layout and presentation settings &mdash; and <b>nothing else</b>: no plugins,
no instance settings, <b>no secrets</b>. That is what makes it safe to hand to a
client's own instance (an agency demo &rarr; client hand-off). Create one from
<b>Domains &rarr; Export site</b>; the package appears here to download, apply or
delete. To move between instances, download it, then <b>Upload</b> it on the target
and <b>Apply</b> it to a domain there.
</p>
<div style="margin-bottom:12px;">
<button class="mg-btn mg-btn-primary" onclick="exportPrimarySite(this)">Export this site</button>
<label class="mg-btn mg-btn-primary" style="cursor:pointer;">
&#11014; Upload a package
<input type="file" accept=".tar.gz,application/gzip" style="display:none;" onchange="uploadPackage(this)">
</label>
</div>
<div class="mg-file-list" id="package-list">
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
      // Three distinct kinds: content snapshots (in-app restore), site packages
      // (SM183: apply to a domain), and full-system backups (CLI restore only).
      renderBackups(all.filter(function(b) { return b.scope === 'content'; }), 'content-list', true);
      renderPackages(all.filter(function(b) { return b.scope === 'site'; }));
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

// --- SM183: site packages (create is on the Domains page; here: list, upload,
// apply, delete). The global CSRF wrapper (manager layout M-1) adds the token to
// every POST, so these follow the same fetch pattern as the content backups. ---

// The source host is encoded in the package name: lazysite-site-<host>-<UTCstamp>.
function pkgHost(name) {
  var m = /^lazysite-site-(.+)-\d{8}T\d{6}Z\.tar\.gz$/.exec(name || '');
  return m ? m[1] : '';
}

function renderPackages(list) {
  var el = document.getElementById('package-list');
  if (!el) return;
  if (!list.length) {
    el.innerHTML = '<div class="mg-file-item"><span class="mg-file-name mg-empty">No site packages yet &mdash; create one from Domains &rarr; Export site.</span></div>';
    return;
  }
  var html = '';
  for (var i = 0; i < list.length; i++) {
    var b = list[i];
    var host = pkgHost(b.name);
    var uploaded = host === 'uploaded';
    var id = 'pkg-' + i;
    html += '<div class="mg-file-item" style="flex-wrap:wrap;">';
    html += '<span class="mg-file-name" style="font-family:var(--mg-mono);font-size:0.8rem;">' + escHtml(b.name) + '</span>';
    html += '<span class="mg-badge ' + (uploaded ? 'mg-badge-muted' : 'mg-badge-success') + '">' + (uploaded ? 'uploaded' : escHtml(host || 'site')) + '</span>';
    html += '<span class="mg-file-meta">' + fmtSize(b.size) + ' &middot; ' + fmtDate(b.mtime) + '</span>';
    html += '<a class="mg-btn mg-btn-sm" href="' + API + '?action=backup-download&name=' + encodeURIComponent(b.name) + '">&#11015; Download</a>';
    html += '<button class="mg-btn mg-btn-sm" onclick="showApply(\'' + escHtml(b.name) + '\', \'' + id + '\')">Apply&hellip;</button>';
    html += '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="deletePackage(\'' + escHtml(b.name) + '\', this)">Delete</button>';
    html += '<div class="mg-apply-panel" id="' + id + '" style="display:none;width:100%;margin-top:8px;"></div>';
    html += '</div>';
  }
  el.innerHTML = html;
}

// SM185: export the DEFAULT/primary site as a self-contained package, without
// needing the domains feature. Gated server-side on manage_content.
function exportPrimarySite(btn) {
  if (btn) btn.disabled = true;
  showStatus('Packaging this site…');
  fetch(API + '?action=site-export-primary', { method: 'POST', credentials: 'same-origin' })
    .then(function(r) { return r.json(); })
    .then(function(d) {
      if (btn) btn.disabled = false;
      if (!d.ok) { showStatus(d.error || 'Export failed', true); return; }
      showStatus('Exported this site → ' + d.name + '. Download or apply it below.');
      loadBackups();
    })
    .catch(function(e) { if (btn) btn.disabled = false; showStatus('Export error: ' + e.message, true); });
}

function uploadPackage(input) {
  if (!input.files || !input.files.length) return;
  var file = input.files[0];
  var fd = new FormData();
  fd.append('file', file, file.name);
  showStatus('Uploading ' + file.name + '…');
  // No explicit Content-Type: the browser sets the multipart boundary; the CSRF
  // wrapper still adds X-CSRF-Token.
  fetch(API + '?action=site-backup-upload', { method: 'POST', credentials: 'same-origin', body: fd })
    .then(function(r) { return r.json(); })
    .then(function(d) {
      input.value = '';
      if (!d.ok) { showStatus(d.error || 'Upload failed', true); return; }
      showStatus('Uploaded ' + d.name + '. Apply it to a domain below.');
      loadBackups();
    })
    .catch(function(e) { input.value = ''; showStatus('Upload error: ' + e.message, true); });
}

function showApply(name, panelId) {
  var panel = document.getElementById(panelId);
  if (!panel) return;
  if (panel.style.display !== 'none') { panel.style.display = 'none'; return; }
  panel.style.display = 'block';
  panel.innerHTML = '<span class="mg-muted">Loading&hellip;</span>';
  Promise.all([
    fetch(API + '?action=site-backup-inspect&name=' + encodeURIComponent(name), { credentials: 'same-origin' }).then(function(r) { return r.json(); }),
    fetch(API + '?action=domains-list', { credentials: 'same-origin' }).then(function(r) { return r.json(); })
  ]).then(function(res) {
    var info = res[0], dl = res[1];
    if (!info.ok) { panel.innerHTML = '<span class="mg-warn">' + escHtml(info.error || 'Cannot read package') + '</span>'; return; }
    var m = info.manifest || {};
    var doms = (dl.ok && dl.domains) ? dl.domains : [];
    var opts = '<option value="">(default) &mdash; primary site</option>';
    for (var i = 0; i < doms.length; i++) {
      if (!doms[i].content_root) continue;   // only domains with their own content root
      opts += '<option value="' + escHtml(doms[i].host) + '">' + escHtml(doms[i].host) + '</option>';
    }
    var selId = panelId + '-target', clnId = panelId + '-clean';
    var html = '';
    html += '<div style="font-size:0.85rem;margin-bottom:8px;"><b>Package</b>: source '
          + escHtml(m.source_host || '(default)') + ' &middot; ' + (info.content_files || 0)
          + ' file(s) &middot; theme ' + escHtml(m.theme || '(none)') + ' &middot; layout '
          + escHtml(m.layout || '(none)') + ' &middot; nav '
          + (info.has_nav ? 'override' : escHtml(m.nav || 'base-inherited')) + '.</div>';
    html += '<div style="margin-bottom:6px;"><label>Apply to: <select id="' + selId + '">' + opts + '</select></label></div>';
    html += '<div style="margin-bottom:6px;"><label><input type="checkbox" id="' + clnId + '"> Remove existing content under the target first (clean)</label></div>';
    html += '<div class="mg-muted" style="font-size:0.8rem;margin-bottom:8px;">Apply overwrites the target domain\'s content and rewrites its presentation (site_url / site_name / theme / layout / nav) to the package\'s. A safety snapshot is taken first and the change is recorded in content history. DNS/TLS for the target stay the operator\'s job.</div>';
    html += '<button class="mg-btn mg-btn-primary mg-btn-sm" onclick="doApply(\'' + escHtml(name) + '\', \'' + selId + '\', \'' + clnId + '\', this)">Apply package</button> ';
    html += '<button class="mg-btn mg-btn-sm" onclick="document.getElementById(\'' + panelId + '\').style.display=\'none\';">Cancel</button>';
    panel.innerHTML = html;
  }).catch(function(e) { panel.innerHTML = '<span class="mg-warn">Error: ' + escHtml(e.message) + '</span>'; });
}

function doApply(name, selId, clnId, btn) {
  var sel = document.getElementById(selId), cln = document.getElementById(clnId);
  var host = sel ? sel.value : '';
  var clean = cln ? cln.checked : false;
  var where = host ? ('"' + host + '"') : 'the primary site';
  var msg = 'Apply "' + name + '" to ' + where + '?'
          + (clean ? '\n\nCLEAN is on: existing content under the target is removed first.' : '')
          + '\n\nA safety snapshot is taken and the change is recorded in content history.';
  var go = function(ok) {
    if (!ok) return;
    if (btn) btn.disabled = true;
    showStatus('Applying ' + name + '…');
    fetch(API + '?action=site-backup-apply', {
      method: 'POST', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: name, host: host, clean: clean })
    }).then(function(r) { return r.json(); }).then(function(d) {
      if (btn) btn.disabled = false;
      if (!d.ok) { showStatus(d.error || 'Apply failed', true); return; }
      showStatus('Applied ' + name + (host ? ' to ' + host : ' to the primary site') + '.');
      loadBackups();
    }).catch(function(e) { if (btn) btn.disabled = false; showStatus('Apply error: ' + e.message, true); });
  };
  if (typeof mgConfirm === 'function') { mgConfirm(msg, { danger: clean, ok: 'Apply' }).then(go); }
  else { go(window.confirm(msg)); }
}

function deletePackage(name, btn) {
  var msg = 'Delete the site package "' + name + '"?\n\nThis removes the portable copy only; live sites are unaffected.';
  var go = function(ok) {
    if (!ok) return;
    if (btn) btn.disabled = true;
    fetch(API + '?action=site-backup-delete', {
      method: 'POST', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: name })
    }).then(function(r) { return r.json(); }).then(function(d) {
      if (btn) btn.disabled = false;
      if (!d.ok) { showStatus(d.error || 'Delete failed', true); return; }
      showStatus('Deleted ' + name + '.');
      loadBackups();
    }).catch(function(e) { if (btn) btn.disabled = false; showStatus('Delete error: ' + e.message, true); });
  };
  if (typeof mgConfirm === 'function') { mgConfirm(msg, { danger: true, ok: 'Delete' }).then(go); }
  else { go(window.confirm(msg)); }
}

loadBackups();
</script>
