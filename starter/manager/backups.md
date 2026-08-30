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
<div class="mg-list" id="content-list">
<div class="mg-row"><span class="mg-file-name">Loading&hellip;</span></div>
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
<div class="mg-list" id="package-list">
<div class="mg-row"><span class="mg-file-name">Loading&hellip;</span></div>
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
<div class="mg-list" id="full-list">
<div class="mg-row"><span class="mg-file-name">Loading&hellip;</span></div>
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
    el.innerHTML = '<div class="mg-row"><span class="mg-file-name mg-empty">No backups yet</span></div>';
    return;
  }
  var html = '';
  for (var i = 0; i < list.length; i++) {
    var b = list[i];
    var badge = b.kind === 'preinstall' ? 'mg-tag mg-tag-on' : 'mg-tag mg-tag-off';
    html += '<div class="mg-row">';
    html += '<span class="mg-file-name" style="font-family:var(--mg-mono);font-size:0.8rem;">' + escHtml(b.name) + '</span>';
    html += '<span class="mg-tag ' + badge + '">' + escHtml(b.kind) + '</span>';
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

// SM266 (3): undo the apply that just happened, by name, from where the
// operator is standing. Routes through the SAME restore the Backups list uses -
// no second restore path - so it inherits the pre-restore snapshot, the cache
// clear and the audit entry. The undo is therefore itself undoable.
function offerUndo(snapshot, host) {
  var bar = document.getElementById('undo-bar');
  if (!bar) {
    bar = document.createElement('div');
    bar.id = 'undo-bar';
    bar.className = 'mg-undo-bar';
    var app = document.getElementById('app') || document.body;
    app.insertBefore(bar, app.firstChild);
  }
  bar.innerHTML = 'Applied to ' + escHtml(host || 'the primary site') + '. '
    + 'Not what you meant? <button class="mg-btn mg-btn-sm" '
    + 'onclick="undoApply(\'' + escHtml(snapshot) + '\', this)">Undo &mdash; restore '
    + '<code>' + escHtml(snapshot) + '</code></button> '
    + '<button class="mg-btn mg-btn-sm" onclick="this.parentNode.remove()">Dismiss</button>';
}

function undoApply(snapshot, btn) {
  mgConfirm('Restore the pre-apply snapshot "' + snapshot + '"?\n\n'
    + 'This puts the site back as it was immediately before the apply. The restore '
    + 'takes its own snapshot first, so this is reversible too.',
    { danger: true, ok: 'Undo the apply' }).then(function(ok) {
    if (!ok) return;
    restoreBackup(snapshot, btn);
    var bar = document.getElementById('undo-bar');
    if (bar) bar.remove();
  });
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
    el.innerHTML = '<div class="mg-row"><span class="mg-file-name mg-empty">No site packages yet &mdash; create one from Domains &rarr; Export site.</span></div>';
    return;
  }
  var html = '';
  for (var i = 0; i < list.length; i++) {
    var b = list[i];
    var host = pkgHost(b.name);
    var uploaded = host === 'uploaded';
    var id = 'pkg-' + i;
    html += '<div class="mg-row" style="flex-wrap:wrap;">';
    html += '<span class="mg-file-name" style="font-family:var(--mg-mono);font-size:0.8rem;">' + escHtml(b.name) + '</span>';
    html += '<span class="mg-tag ' + (uploaded ? 'mg-tag mg-tag-off' : 'mg-tag mg-tag-on') + '">' + (uploaded ? 'uploaded' : escHtml(host || 'site')) + '</span>';
    html += '<span class="mg-file-meta">' + fmtSize(b.size) + ' &middot; ' + fmtDate(b.mtime) + '</span>';
    html += '<a class="mg-btn mg-btn-sm" href="' + API + '?action=backup-download&name=' + encodeURIComponent(b.name) + '">&#11015; Download</a>';
    html += '<button class="mg-btn mg-btn-sm" onclick="showApply(\'' + escHtml(b.name) + '\', \'' + id + '\')">Apply&hellip;</button>';
    html += '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="deletePackage(\'' + escHtml(b.name) + '\', this)">Delete</button>';
    html += '<div class="mg-expand" id="' + id + '" style="display:none;width:100%;margin-top:8px;"></div>';
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
  panel._pkg = name;
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
    // SM266: changing the target re-runs the dry run and the readiness check
    // against THAT target. Both are per-target answers, so neither can be
    // computed once when the panel opens.
    html += '<div style="margin-bottom:6px;"><label>Apply to: <select id="' + selId
          + '" onchange="refreshApplyPreview(\'' + panelId + '\')">' + opts + '</select></label></div>';
    html += '<div style="margin-bottom:6px;"><label><input type="checkbox" id="' + clnId + '"> Remove existing content under the target first (clean)</label></div>';
    // SM266 (1) dry run, (2) target readiness, (4) presentation-key override.
    html += '<div id="' + panelId + '-preview" class="mg-apply-preview"></div>';
    html += '<div class="mg-muted" style="font-size:0.8rem;margin-bottom:8px;">Apply overwrites the target domain\'s content and rewrites its presentation (site_url / site_name / theme / layout / nav) to the package\'s. A safety snapshot is taken first and the change is recorded in content history. DNS/TLS for the target stay the operator\'s job.</div>';
    html += '<button class="mg-btn mg-btn-primary mg-btn-sm" onclick="doApply(\'' + escHtml(name) + '\', \'' + selId + '\', \'' + clnId + '\', this)">Apply package</button> ';
    html += '<button class="mg-btn mg-btn-sm" onclick="document.getElementById(\'' + panelId + '\').style.display=\'none\';">Cancel</button>';
    panel.innerHTML = html;
    refreshApplyPreview(panelId);
  }).catch(function(e) { panel.innerHTML = '<span class="mg-warn">Error: ' + escHtml(e.message) + '</span>'; });
}

// SM266 (carved out of SM183): the difference between "I have read the
// manifest" and "I know what this will change".
//
// SM183 made apply SAFE - a snapshot on every surface, a named rollback point,
// a digest on the artefact. None of that lets a human see what an apply will do
// BEFORE agreeing to it, which is the question an operator actually has in
// front of a confirm button. Three answers, all for the selected target:
//
//   the dry run       how many files land, and how many of them overwrite
//   readiness         whether DNS/vhost/TLS are pointed at the target yet
//   the key override  which presentation keys change, with the option to keep
//
// All three are per-target. Re-run on every target change; blank for the
// primary site, where "which domain" is not a question.
function refreshApplyPreview(panelId) {
  var box = document.getElementById(panelId + '-preview');
  var sel = document.getElementById(panelId + '-target');
  var panel = document.getElementById(panelId);
  if (!box || !sel || !panel) return;
  var host = sel.value;
  var name = panel._pkg;
  if (!host) {
    box.innerHTML = '<div class="mg-muted" style="font-size:0.8rem;margin-bottom:8px;">'
      + 'Applying to the primary site. Select a domain to see what would change there.</div>';
    return;
  }
  box.innerHTML = '<span class="mg-muted">Checking the target&hellip;</span>';
  Promise.all([
    fetch(API + '?action=site-backup-inspect&name=' + encodeURIComponent(name)
          + '&host=' + encodeURIComponent(host), { credentials: 'same-origin' })
      .then(function(r) { return r.json(); }),
    fetch(API + '?action=domain-check&host=' + encodeURIComponent(host),
          { credentials: 'same-origin' }).then(function(r) { return r.json(); })
      .catch(function() { return { ok: false }; })
  ]).then(function(res) {
    var info = res[0], chk = res[1];
    if (!info.ok) {
      box.innerHTML = '<div class="mg-warn">' + escHtml(info.error || 'Cannot compare against that target') + '</div>';
      return;
    }
    var c = info.compare || {}, m = info.manifest || {}, h = '';

    // 1. The dry run. Overwrites are the number that matters, so it leads and
    // is emphasised when non-zero - "12 files, 9 of them overwriting what is
    // there" is a different decision from "12 new files".
    h += '<div class="mg-apply-block"><b>What this would do to ' + escHtml(host) + '</b><ul>';
    h += '<li>' + (c.added || 0) + ' new file' + ((c.added === 1) ? '' : 's') + '</li>';
    h += '<li>' + (c.overwritten
          ? '<b>' + c.overwritten + ' existing file' + ((c.overwritten === 1) ? '' : 's') + ' overwritten</b>'
          : 'nothing overwritten') + '</li>';
    if (m.layout) {
      h += '<li>layout <code>' + escHtml(m.layout) + '</code> &mdash; '
        + (c.layout_present ? 'already installed, left as it is' : 'would be installed') + '</li>';
    }
    if (m.theme) {
      h += '<li>theme <code>' + escHtml(m.theme) + '</code> &mdash; '
        + (c.theme_present ? 'already installed, left as it is' : 'would be installed') + '</li>';
    }
    h += '</ul></div>';

    // 2. Readiness. A target whose DNS or TLS is not pointed yet is a warning
    // BEFORE the apply rather than a discovery after it. Not a blocker: staging
    // content ahead of a DNS cutover is a legitimate thing to do deliberately.
    if (chk && chk.ok) {
      var probs = [];
      if (chk.dns && chk.dns.ok === false) probs.push('DNS does not resolve here');
      if (chk.tls && chk.tls.ok === false) probs.push('no valid TLS certificate');
      if (chk.vhost && chk.vhost.ok === false) probs.push('no vhost is serving it');
      h += probs.length
        ? '<div class="mg-note mg-note-warn">&#9888; ' + escHtml(host) + ': ' + escHtml(probs.join('; '))
          + '. The apply will still work &mdash; the content simply is not reachable yet.</div>'
        : '<div class="mg-apply-ok">&#10003; ' + escHtml(host) + ' is resolving and served.</div>';
    }

    // 3. The presentation keys, with the option to keep the target's own. Ticked
    // means "keep mine"; unticked (the default) is the existing behaviour, so
    // an operator who ignores this control gets exactly what they got before.
    var pres = [['theme', m.theme], ['layout', m.layout], ['nav', m.nav]];
    var rows = '';
    for (var i = 0; i < pres.length; i++) {
      if (!pres[i][1]) continue;
      rows += '<label class="mg-apply-keep"><input type="checkbox" class="' + panelId + '-keep" '
        + 'value="' + escHtml(pres[i][0]) + '"> keep this site\'s <b>' + escHtml(pres[i][0])
        + '</b> (the package would set it to <code>' + escHtml(pres[i][1]) + '</code>)</label>';
    }
    if (rows) {
      h += '<div class="mg-apply-block"><b>Presentation</b><div class="mg-muted" '
        + 'style="font-size:0.8rem">Tick anything you want left alone. Untouched, the '
        + 'package\'s values are applied, as before.</div>' + rows + '</div>';
    }
    box.innerHTML = h;
  }).catch(function(e) {
    box.innerHTML = '<div class="mg-warn">Error: ' + escHtml(e.message) + '</div>';
  });
}

function doApply(name, selId, clnId, btn) {
  var sel = document.getElementById(selId), cln = document.getElementById(clnId);
  var host = sel ? sel.value : '';
  var clean = cln ? cln.checked : false;
  // SM266 (4): the presentation keys the operator ticked to keep.
  var panelId = selId.replace(/-target$/, '');
  var keep = [];
  var boxes = document.querySelectorAll('.' + panelId + '-keep');
  for (var i = 0; i < boxes.length; i++) if (boxes[i].checked) keep.push(boxes[i].value);
  var where = host ? ('"' + host + '"') : 'the primary site';
  var msg = 'Apply "' + name + '" to ' + where + '?'
          + (clean ? '\n\nCLEAN is on: existing content under the target is removed first.' : '')
          + (keep.length ? '\n\nKeeping this site\'s own ' + keep.join(', ') + '.' : '')
          + '\n\nA safety snapshot is taken and the change is recorded in content history.';
  var go = function(ok) {
    if (!ok) return;
    if (btn) btn.disabled = true;
    showStatus('Applying ' + name + '…');
    fetch(API + '?action=site-backup-apply', {
      method: 'POST', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ name: name, host: host, clean: clean, keep_presentation: keep })
    }).then(function(r) { return r.json(); }).then(function(d) {
      if (btn) btn.disabled = false;
      if (!d.ok) { showStatus(d.error || 'Apply failed', true); return; }
      showStatus('Applied ' + name + (host ? ' to ' + host : ' to the primary site') + '.');
      // SM266 (3): the undo. The snapshot name comes back in the result and used
      // to appear only in the audit trail, so undoing meant finding the right
      // row on the Backups list and knowing it was the one. Offered here, at the
      // moment the operator can still tell whether the apply was what they meant.
      // Safe to offer because restoring is itself snapshotted.
      if (d.safety) offerUndo(d.safety, host);
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
