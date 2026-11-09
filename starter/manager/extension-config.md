---
title: Extensions - configure
auth: manager
search: false
---

<!-- SM957: ONE MENU ENTRY, "Extensions", for two pages that were two entries:
     this one enables and disables, /manager/extension-config configures what is
     enabled. Both addresses work and both light the same entry; each links to
     the other. Handlers left the menu by ruling and is reached from here and
     from each form on the Submissions page. -->
<div class="mg-toolbar">
  <a class="mg-btn mg-btn-sm" href="/manager/extensions">Enable or disable</a>
  <a class="mg-btn mg-btn-sm" href="/manager/handlers">Handlers</a>
</div>

<div id="extension-list">Loading...</div>

<!-- SM922: the link audit's static report card is GONE. It was filled by fetching
     /manager/audit-report - a page the extension wrote into the docroot, which is why
     the audit could scan its own last report and why the result could not be
     re-run from where it was being read. The findings come back in the action's
     own result now and open in a modal with a Refresh. -->

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';

function esc(s) { return (s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;'); }
function val(id) { var el = document.getElementById(id); return el ? el.value : ''; }

// SM118 pattern (field report): every explicit-save surface on this page - the
// per-extension config forms - flags unsaved changes via the shared mgDirtyGuard
// (manager layout). Each surface gets its own key so saving or cancelling one
// never un-flags another. SM842: the handler and form-target forms moved to
// the Handlers page, which carries its own.
function markExtensionDirty(id)   { mgDirtyGuard.set('extension-' + id, 'dirty-' + id); }
function clearExtensionDirty(id)  { mgDirtyGuard.clear('extension-' + id); }

// SM664: the all-files history overview, moved here from the Files page.
//
// It is a report ABOUT the repository, not a file operation, and on the Files
// page seeing it required the Files app - full read and write over content -
// for somebody who only needed to know what changed. SM461 argued that and was
// declined in August; the release manager reversed it on 2026-08-28. The
// control-API action now accepts manage_content OR manage_config, so the
// audience of THIS page can read it.
//
// The per-file History panel stays on Files. That one IS a file operation and
// belongs beside the file.
var HIST_OVERVIEW = { rows: [], sort: 'latest', dir: -1 };

// Ported with the overview: this page had neither helper, and moving the code
// without them would have thrown at render time.
function histEsc(s) { return esc(s); }
function histTime(mtime) {
  if (!mtime) return '';
  var d = new Date(mtime * 1000);
  function p(n) { return (n < 10 ? '0' : '') + n; }
  return d.getFullYear() + '-' + p(d.getMonth() + 1) + '-' + p(d.getDate())
       + ' ' + p(d.getHours()) + ':' + p(d.getMinutes());
}

function openHistoryOverview() {
  var body = mgExtensionModal('Content history - all files');
  body.innerHTML = '<p class="mg-muted">Loading&hellip;</p>';
  // SM461: mgJson, not r.json(). Any non-JSON body - a 500, a die, a proxy
  // timeout page - used to become "JSON.parse: unexpected character at line 1
  // column 1", which reads as the HISTORY being corrupt while the data was
  // always fine. Carried across with the code, because the fault it guards
  // against is a property of the fetch, not of the page it sat on.
  fetch(API + '?action=git-history-summary')
    .then(function(r) { return (window.mgJson ? window.mgJson(r) : r.json()); })
    .then(function(d) {
      var b = document.getElementById('extension-modal-body');
      if (!b) return;
      if (!d.ok) { b.innerHTML = '<p class="mg-muted">' + histEsc(d.error || 'No history available') + '</p>'; return; }
      if (!d.enabled) { b.innerHTML = '<p class="mg-muted">Content history is not enabled.</p>'; return; }
      HIST_OVERVIEW.rows = d.files || [];
      HIST_OVERVIEW.summary = d.summary || { files: 0, revisions: 0 };
      renderHistoryOverview();
    })
    .catch(function(e) {
      var b = document.getElementById('extension-modal-body');
      if (b) b.innerHTML = '<p class="mg-muted">The history overview could not be '
        + 'loaded: ' + histEsc(e.message) + '</p>';
    });
}

function sortHistoryOverview(col) {
  if (HIST_OVERVIEW.sort === col) { HIST_OVERVIEW.dir = -HIST_OVERVIEW.dir; }
  else { HIST_OVERVIEW.sort = col; HIST_OVERVIEW.dir = (col === 'path') ? 1 : -1; }
  renderHistoryOverview();
}

function renderHistoryOverview() {
  var body = document.getElementById('extension-modal-body');
  if (!body) return;
  var rows = HIST_OVERVIEW.rows.slice();
  var col = HIST_OVERVIEW.sort, dir = HIST_OVERVIEW.dir;
  rows.sort(function(a, b) {
    if (col === 'path' || col === 'last_author') {
      var as = String(a[col] || ''), bs = String(b[col] || '');
      return as < bs ? -dir : as > bs ? dir : 0;
    }
    return ((a[col] || 0) - (b[col] || 0)) * dir;
  });
  var s = HIST_OVERVIEW.summary || { files: 0, revisions: 0 };
  if (!rows.length) {
    body.innerHTML = '<p class="mg-muted">No files under content history yet.</p>';
    return;
  }
  var html = '<p class="mg-muted">' + s.files + ' file' + (s.files === 1 ? '' : 's')
           + ' under history, ' + s.revisions + ' revision' + (s.revisions === 1 ? '' : 's') + ' in total.</p>'
           + '<table class="mg-table"><thead><tr>'
           + '<th class="mg-sortable" onclick="sortHistoryOverview(\'path\')">Path</th>'
           + '<th class="mg-sortable" onclick="sortHistoryOverview(\'revisions\')">Revisions</th>'
           + '<th class="mg-sortable" onclick="sortHistoryOverview(\'first\')">First</th>'
           + '<th class="mg-sortable" onclick="sortHistoryOverview(\'latest\')">Latest</th>'
           + '<th class="mg-sortable" onclick="sortHistoryOverview(\'last_author\')">Last author</th>'
           + '</tr></thead><tbody>';
  for (var i = 0; i < rows.length; i++) {
    var r = rows[i];
    html += '<tr>'
          + '<td>' + histEsc(r.path) + '</td>'
          + '<td>' + histEsc(String(r.revisions)) + '</td>'
          + '<td>' + histEsc(histTime(r.first)) + '</td>'
          + '<td>' + histEsc(histTime(r.latest)) + '</td>'
          + '<td>' + histEsc(r.last_author || '') + '</td>'
          + '</tr>';
  }
  html += '</tbody></table>';
  body.innerHTML = html;
}

// SM640: the extension config modal. ONE shell, opened by any extension that has been
// converted to the mechanism, and it fetches its own data and owns its own
// reload - which is the whole point: a change to one extension no longer re-renders
// every other extension's configuration.
//
// Deliberately a SECOND shell rather than a generalisation of openSubsModal
// (SM182/SM187) for now. That one carries a form selector in its header and is
// driven by the submissions viewer's own state; merging them is a refactor with
// no behaviour to show for it, and this page is being converted one extension at a
// time (SM640's own rule) rather than rewritten.
function mgExtensionModal(title) {
  mgExtensionModalClose(true);
  var ov = document.createElement('div');
  ov.id = 'extension-modal';
  ov.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,0.5);z-index:1000;display:flex;align-items:center;justify-content:center;';
  ov.innerHTML =
      '<div style="background:var(--mg-bg,#fff);color:var(--mg-text,inherit);width:92%;max-width:760px;max-height:86vh;border-radius:8px;display:flex;flex-direction:column;overflow:hidden;">'
    + '<div style="display:flex;align-items:center;gap:8px;padding:10px 14px;border-bottom:1px solid var(--mg-border,#ddd);">'
    + '<strong id="extension-modal-title" style="flex:1"></strong>'
    + '<button type="button" class="mg-sheet-close" onclick="mgExtensionModalClose()" aria-label="Close">&times;</button></div>'
    + '<div id="extension-modal-body" style="flex:1;overflow:auto;padding:12px 14px;"></div></div>';
  // Clicking the backdrop closes, and goes through the same unsaved-changes
  // question as the button - an accidental click outside must not be a quieter
  // way to lose an edit than pressing Close.
  ov.addEventListener('click', function(e) { if (e.target === ov) mgExtensionModalClose(); });
  document.body.appendChild(ov);
  document.getElementById('extension-modal-title').textContent = title || 'Configuration';
  return document.getElementById('extension-modal-body');
}

// force: skip the unsaved-changes question (used when re-opening, and after a
// successful save has already cleared the flag).
function mgExtensionModalClose(force) {
  var ov = document.getElementById('extension-modal');
  if (!ov) return;
  var id = ov.getAttribute('data-extension') || '';
  if (!force && id && mgDirtyGuard && mgDirtyGuard.isDirty('extension-' + id)) {
    if (!confirm('This configuration has unsaved changes. Close and lose them?')) return;
  }
  if (id) clearExtensionDirty(id);
  if (ov.parentNode) ov.parentNode.removeChild(ov);
}

function loadExtensions() {
  document.getElementById('extension-list').textContent = 'Scanning...';
  // SM1369 X6, H-8 (ruling 194, C-38): the caller's capabilities, from whoami, so a
  // card links an extension's page only for one who may open it. The listing
  // itself is cached and knows no caller. A whoami that fails links none.
  var caps = fetch(API + '?action=whoami')
    .then(function(r) { return r.json(); })
    .then(function(d) { window._callerCaps = (d && d.ok && d.capabilities) || {}; })
    .catch(function() { window._callerCaps = {}; });
  Promise.all([fetch(API + '?action=extension-list').then(function(r) { return r.json(); }), caps])
    .then(function(both) {
      var data = both[0];
      if (!data.ok) {
        document.getElementById('extension-list').textContent = data.error || 'Failed to load extensions';
        return;
      }
      window._extensions = data.extensions || [];
      renderExtensions(data.extensions || []);
    });
}

function renderExtensions(extensions) {
  var enabled = (extensions || []).filter(function(p) { return p._enabled; });

  if (!enabled.length) {
    document.getElementById('extension-list').innerHTML =
      '<p class="mg-empty">No extensions enabled. Visit <a href="/manager/config">Configuration</a> to enable extensions.</p>';
    return;
  }

  var html = '';
  enabled.forEach(function(p) { html += renderExtensionCard(p); });
  document.getElementById('extension-list').innerHTML = html;
}

// SM842 linked a file handler's store here as ?submissions=<store directory>,
// and SM938 D5's single-submission page did the same. SM957: the viewer is
// the Submissions page now, so that address is a REDIRECT to it, carrying the
// store unchanged - the page validates it, as this did. `loc` is a parameter
// so a test can drive it without a browser.
function redirectLegacySubmissions(loc) {
  var m = /[?&]submissions=([^&]+)/.exec(loc.search);
  if (!m) return false;
  loc.replace('/manager/submissions?store=' + m[1]);
  return true;
}

// SM640: a LINE per enabled extension - name, state, and a way in - rather than
// every extension's whole configuration rendered inline one after another. The
// page no longer grows with the number of extensions installed.
//
// What stays on the row: the extension's own actions, and the containers for the
// things that are NOT its config form - child configs (the forms extension renders
// its handler list into one), an action's choice prompt, and the status line.
// Those keep their identity and their position, so nothing that moves DOM nodes
// around - the add-handler wizard does - finds its container inside a modal
// that has since been destroyed.
function renderExtensionCard(extension) {
  var hasConfig = !!(extension.config_schema && extension.config_schema.length);
  // A CARD IS NOT A ROW. Carrying both meant the card inherited the row grid,
  // so its stacked contents - title, description, the action group and the
  // full-width panels below them - were laid out as columns of a line.
  var html = '<div class="mg-extension-card" id="extension-' + esc(extension.id) + '">';
  html += '<div class="mg-extension-title">' + esc(extension.name) + '</div>';
  html += '<div class="mg-extension-desc">' + esc(extension.description) + '</div>';
  // The group opens unconditionally, because Configure and the per-extension
  // buttons below belong to it even when the extension declares no actions of its
  // own. Opening it only for declared actions is what left those buttons
  // outside the group, each on its own baseline.
  html += '<div class="mg-wizard-actions">';
  if (extension.actions && extension.actions.length) {
    extension.actions.forEach(function(a, ai) {
      // Lifecycle actions an extension drives from its enable/disable toggle
      // (on_enable / on_disable) are marked hidden - they are not buttons here,
      // so e.g. content history never shows "Enable" while already enabled.
      if (a.hidden) { return; }
      if (a.link) {
        html += '<a href="' + a.link + '">' + esc(a.label) + '</a>';
      } else if (a.needs) {
        // Gated action (e.g. git-sync "Test connection" needs a remote_url):
        // refuse until the required config key is set, so the button is never a
        // dead end on an unconfigured extension.
        html += '<button class="mg-btn mg-btn-sm" onclick="runActionGated(\'' + esc(extension.id) + '\',' + ai + ',\'' + esc(a.needs) + '\')">' + esc(a.label) + '</button>';
      } else {
        html += '<button class="mg-btn mg-btn-sm" onclick="(function(){var p=window._extensions.find(function(x){return x.id===\'' + extension.id + '\'});runAction(p,p.actions[' + ai + '])})()">' + esc(a.label) + '</button>';
      }
    });
  }
  if (hasConfig) {
    // mg-btn-sm, like every other button in this row. Configure was full size
    // beside small action buttons, so one extension's controls came in two
    // weights and the odd one out read as more important than the rest.
    html += '<button class="mg-btn mg-btn-sm" onclick="loadConfig(window._extensions.find(function(x){return x.id===\'' + extension.id + '\'}))">Configure</button>';
  }
  // SM664: content history's way in is a VIEW, not a config form - it declares
  // an empty config_schema, so without this its row would offer nothing at all.
  // SM842: the form handler's configuration is the Handlers page; its row
  // keeps the two things that are about what ARRIVED rather than where it goes.
  if (extension.id === 'form-handler') {
    html += '<a class="mg-btn mg-btn-sm" href="/manager/handlers">Handlers</a>';
    html += '<a class="mg-btn mg-btn-sm" href="/manager/submissions">Submissions</a>';
  }
  if (extension.id === 'content-history') {
    html += '<button class="mg-btn mg-btn-sm" onclick="openHistoryOverview()" title="All files under content history, with per-file revision statistics">History overview</button>';
  }
  // SM703: the blocked-address profile belongs to the extension that does the
  // blocking. It sat on Visitor Statistics, which reads as a reporting filter -
  // and a block is not a reporting filter: lazysite-auth.pl answers a blocked
  // address 403 and exits before anything is served. Putting an access control
  // on a statistics page invites an operator to read it as "hidden from the
  // numbers" rather than "refused the site".
  if (extension.id === 'bad-url-blocker') {
    html += '<button class="mg-btn mg-btn-sm" onclick="toggleBlocked(this)" '
         +  'aria-controls="blocked-body" aria-expanded="false">Blocked addresses</button>';
  }
  // SM1369 X6, H-8 (ruling 188): AN EXTENSION'S OWN MANAGER PAGES. A panel is a
  // manager page the extension ships (hooks.panels), served at
  // /manager/<id>-<name> to a holder of the capability it declares, and linked
  // here from its card - nothing of it runs on this page.
  extensionPanels(extension).forEach(function (p) {
    html += '<a class="mg-btn mg-btn-sm" href="' + esc(p.href) + '">' + esc(p.label) + '</a>';
  });
  // Every button this extension offers is now in ONE group, so they share a
  // baseline and wrap together. Panels open BELOW it, full width.
  html += '</div>';
  if (extension.id === 'bad-url-blocker') {
    html += '<div class="mg-card-body mg-expand-body" id="blocked-body" style="display:none">Loading&hellip;</div>';
  }
  // SM085: an action result may ask for a choice (needs_choice) - the
  // conflict list + choice buttons render here.
  html += '<div id="choice-' + esc(extension.id) + '" style="display:none"></div>';
  // SM927: a staged action's report - one line per step, and the message a
  // delivery test actually sent. Separate from the choice box, which is a
  // question, and from the status line, which holds one sentence.
  //
  // The `hidden` ATTRIBUTE, not an inline display:none like its neighbour above.
  // t/lint/108 keeps a ratcheting ceiling of inline styles per page and is right
  // that a new one is debt; the attribute needs no rule in three stylesheets to
  // work. (That lint counts the text, so this comment may not spell the thing it
  // is avoiding.)
  html += '<div id="report-' + esc(extension.id) + '" hidden></div>';
  html += '<div class="mg-status" id="status-' + esc(extension.id) + '"></div>';
  html += '</div>';
  return html;
}

// --- Generic extension config ---

// SM639/SM640: the configuration opens in the modal and fetches its own values
// on click, so opening one extension's config neither renders nor re-reads any
// other extension's.
function loadConfig(extension) {
  var body = mgExtensionModal(extension.name);
  document.getElementById('extension-modal').setAttribute('data-extension', extension.id);
  body.textContent = 'Loading...';
  fetch(API + '?action=extension-read&extension=' + encodeURIComponent(extension.id), {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ script: extension._script })
  })
  .then(function(r) { return window.mgJson ? window.mgJson(r) : r.json(); })
  .then(function(data) {
    // The modal may have been closed while the request was in flight; writing
    // into a detached node would silently do nothing, so check it is still ours.
    var b = document.getElementById('extension-modal-body');
    if (!b) return;
    if (!data.ok) { b.textContent = data.error || 'Could not read this extension\'s configuration'; return; }
    b.innerHTML = renderForm(extension, data.values || {});
    applyShowWhen(b);
  })
  .catch(function(e) {
    var b = document.getElementById('extension-modal-body');
    if (b) b.textContent = 'Error: ' + e.message;
  });
}

function renderForm(extension, values) {
  var html = '<form onsubmit="saveConfig(event,\'' + extension.id + '\',\'' + esc(extension._script) + '\')"'
           + ' oninput="markExtensionDirty(\'' + extension.id + '\')" onchange="markExtensionDirty(\'' + extension.id + '\')">';
  (extension.config_schema||[]).forEach(function(f) {
    var v = values[f.key] !== undefined ? values[f.key] : (f.default || '');
    var sw = f.show_when;
    var da = sw ? ' data-show-key="'+sw.key+'" data-show-val="'+sw.value.join(',')+'"' : '';
    html += '<div class="mg-field mg-config-field"'+da+'>';
    // SM1085: a field's `note` is its explanation, and this page never drew it -
    // every extension's descriptor carried notes nobody could read, so a label
    // like "Extra operation packs" stood alone. It shows as the same info mark
    // the Extensions page uses: hover or focus it for the text (SM1104: drawn from
    // data-note by the stylesheet; a title showed on hover only).
    html += '<label>' + esc(f.label)
      + (f.note ? ' <span class="mg-info" tabindex="0" role="img" aria-label="' + esc(f.note)
        + '" data-note="' + esc(f.note) + '">&#9432;</span>' : '')
      + '</label>';
    if (f.type === 'records') {
      html += renderRecords(f, Array.isArray(v) ? v : []);
    } else if (f.type === 'select') {
      html += '<select name="'+f.key+'" onchange="applyShowWhen(this.form)">';
      (f.options||[]).forEach(function(o) { html += '<option'+(v===o?' selected':'')+'>'+o+'</option>'; });
      html += '</select>';
    } else if (f.type === 'boolean') {
      html += '<input type="checkbox" name="'+f.key+'"'+(v==='true'||v==='1'?' checked':'')+' onchange="applyShowWhen(this.form)">';
    } else if (f.type === 'textarea') {
      html += '<textarea name="'+f.key+'" rows="4">'+esc(v)+'</textarea>';
    } else if (f.type === 'password') {
      // autocomplete=new-password: stop the browser pair-autofilling these extension
      // credential fields with the operator's own saved site login.
      html += '<input type="password" name="'+f.key+'" placeholder="leave blank to keep" autocomplete="new-password">';
    } else if (f.type === 'readonly') {
      html += '<span class="mg-readonly-value">'+esc(v)+'</span>';
    } else {
      var t = f.type==='email'?'email':f.type==='number'?'number':'text';
      html += '<input type="'+t+'" name="'+f.key+'" value="'+esc(v)+'"'+(f.required?' required':'')+' autocomplete="off">';
    }
    html += '</div>';
  });
  html += '<div class="mg-field"><label></label><button type="submit" class="mg-btn mg-btn-primary">Save</button>'
       +  ' <span id="dirty-' + extension.id + '" class="mg-note mg-note-info" style="display:none">&#9679; Unsaved changes &mdash; click Save</span></div></form>';
  return html;
}

// SM1351 (ruling 214): A REPEATING SECTION (config_schema type `records`) - one
// block per record with its fields, a `pairs` field as rows of two, a `secret`
// field as set or not set (its value is never sent here). The inputs carry no
// name, so the form's own loop leaves them alone; saveConfig gathers each
// section as a list of records.
var mgRecordSpec = {};
function renderRecords(f, recs) {
  mgRecordSpec[f.key] = f;
  var h = '<div class="ext-records" data-records="' + esc(f.key) + '">';
  recs.forEach(function(r) { h += recordBlock(f, r); });
  h += '</div><button type="button" class="mg-btn mg-btn-sm" data-impact="edit" onclick="addRecord(this,\'' + esc(f.key) + '\')">Add '
    + esc((f.record_label || 'record').toLowerCase()) + '</button>';
  return h;
}
function noteMark(s) {
  return s.note ? ' <span class="mg-info" tabindex="0" role="img" aria-label="' + esc(s.note)
    + '" data-note="' + esc(s.note) + '">&#9432;</span>' : '';
}
function pairRow(s, a, b) {
  return '<div class="ext-pair"><input type="text" placeholder="' + esc(s.from_label || 'From') + '" value="' + esc(a)
    + '" autocomplete="off"> = <input type="text" placeholder="' + esc(s.to_label || 'To') + '" value="' + esc(b)
    + '" autocomplete="off"></div>';
}
function pairsOf(line) {
  return String(line || '').split(',').map(function(e) {
    var i = e.indexOf('=');
    return i < 0 ? null : [e.slice(0, i).trim(), e.slice(i + 1).trim()];
  }).filter(function(p) { return p && (p[0] || p[1]); });
}
function recordBlock(f, r) {
  r = r || {};
  var h = '<fieldset class="ext-record" data-record-of="' + esc(f.key) + '"><legend>' + esc(f.record_label || 'Record')
    + ' <input type="text" data-rf="name" value="' + esc(r.name || '') + '"' + (r.name ? ' readonly' : '')
    + ' placeholder="name" size="16" autocomplete="off"> <button type="button" class="mg-btn mg-btn-sm"'
    + ' data-impact="edit" onclick="removeRecord(this)">Remove</button></legend>';
  (f.fields || []).forEach(function(s) {
    h += '<div class="mg-field"><label>' + esc(s.label) + noteMark(s) + '</label>';
    if (s.type === 'secret') {
      var st = r[s.key + '_set'];
      h += '<input type="password" data-rf="' + esc(s.key) + '" autocomplete="new-password" placeholder="'
        + (st === 1 || st === true ? 'set - leave blank to keep' : st === 'unreadable' ? 'cannot be read - set it again' : 'not set')
        + '">';
    } else if (s.type === 'pairs') {
      h += '<div data-rf-pairs="' + esc(s.key) + '">';
      pairsOf(r[s.key]).forEach(function(p) { h += pairRow(s, p[0], p[1]); });
      h += pairRow(s, '', '') + '</div><button type="button" class="mg-btn mg-btn-sm" data-impact="edit"'
        + ' onclick="addPairRow(this,\'' + esc(f.key) + '\',\'' + esc(s.key) + '\')">Add a row</button>';
    } else {
      h += '<input type="text" data-rf="' + esc(s.key) + '" value="' + esc(r[s.key] || '') + '"'
        + (s.required ? ' required' : '') + ' autocomplete="off">';
    }
    h += '</div>';
  });
  return h + '</fieldset>';
}
function recordsDirty(el) {
  var form = el.closest('form');
  if (form) form.dispatchEvent(new Event('change', { bubbles: true }));
}
function addRecord(btn, key) {
  var box = btn.previousElementSibling;
  box.insertAdjacentHTML('beforeend', recordBlock(mgRecordSpec[key], {}));
  recordsDirty(btn);
}
function removeRecord(btn) {
  var form = btn.closest('form');
  btn.closest('fieldset').remove();
  if (form) recordsDirty(form);
}
function addPairRow(btn, key, field) {
  var spec = (mgRecordSpec[key].fields || []).filter(function(s) { return s.key === field; })[0] || {};
  btn.previousElementSibling.insertAdjacentHTML('beforeend', pairRow(spec, '', ''));
  recordsDirty(btn);
}
function gatherRecords(form, values) {
  var boxes = form.querySelectorAll('[data-records]');
  for (var i = 0; i < boxes.length; i++) {
    var list = [];
    var sets = boxes[i].querySelectorAll('fieldset[data-record-of]');
    for (var j = 0; j < sets.length; j++) {
      var r = {};
      sets[j].querySelectorAll('[data-rf]').forEach(function(inp) {
        var k = inp.getAttribute('data-rf');
        if (inp.type === 'password') { if (inp.value) r[k] = inp.value; }
        else r[k] = inp.value;
      });
      sets[j].querySelectorAll('[data-rf-pairs]').forEach(function(pd) {
        var rows = [];
        pd.querySelectorAll('.ext-pair').forEach(function(row) {
          var ins = row.querySelectorAll('input');
          if (ins[0].value || ins[1].value) rows.push([ins[0].value, ins[1].value]);
        });
        r[pd.getAttribute('data-rf-pairs')] = rows;
      });
      list.push(r);
    }
    values[boxes[i].getAttribute('data-records')] = list;
  }
}

function applyShowWhen(container) {
  if (!container) return;
  var fields = container.querySelectorAll('[data-show-key]');
  for (var i = 0; i < fields.length; i++) {
    var f = fields[i];
    var key = f.dataset.showKey;
    var vals = f.dataset.showVal.split(',');
    var ctrl = document.getElementById(key)
      || (container.querySelector ? container.querySelector('[name="' + key + '"]') : null);
    if (!ctrl) { f.style.display = 'none'; continue; }
    var cur = ctrl.type === 'checkbox' ? (ctrl.checked ? 'true' : 'false') : ctrl.value;
    var show = vals.indexOf(cur) !== -1;
    f.style.display = show ? (f.classList.contains('mg-field') ? 'flex' : 'block') : 'none';
  }
}

function saveConfig(e, extensionId, script) {
  e.preventDefault();
  var form = e.target;
  var status = document.getElementById('status-' + extensionId);
  var values = {};
  var inputs = form.elements;
  for (var i = 0; i < inputs.length; i++) {
    var el = inputs[i];
    if (!el.name) continue;
    if (el.type === 'checkbox') { values[el.name] = el.checked ? 'true' : 'false'; }
    else if (el.type === 'password') { if (el.value) values[el.name] = el.value; }
    else { values[el.name] = el.value; }
  }
  gatherRecords(form, values);    // SM1351: each repeating section, as its records
  if (status) status.textContent = 'Saving...';
  fetch(API + '?action=extension-save&extension=' + encodeURIComponent(extensionId), {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ script: script, values: values })
  })
  .then(function(r) { return r.json(); })
  .then(function(data) {
    if (data.ok) {
      mgClearWarning();
      clearExtensionDirty(extensionId);
      // SM639: the page no longer reloads. The saved extension closes its modal and
      // the list re-reads itself, so a change to one extension costs one request
      // and leaves every other extension's state - and the operator's scroll
      // position - alone. The dirty flag is cleared BEFORE the close so the
      // unsaved-changes question does not fire on a successful save.
      mgExtensionModalClose(true);
      if (status) status.textContent = 'Saved';
      loadExtensions();
    } else {
      mgShowWarning(data.error || 'Save failed', true);
      if (status) status.textContent = '';
    }
  })
  .catch(function(e) {
    mgShowWarning('Error: ' + e.message, true);
    if (status) status.textContent = '';
  });
}

// Run an action only once its required config key is set; otherwise point the
// operator at the config first (no test-against-nothing).
function runActionGated(extensionId, ai, needs) {
  var p = window._extensions.find(function(x) { return x.id === extensionId; });
  if (!p) return;
  fetch(API + '?action=extension-read&extension=' + encodeURIComponent(extensionId), {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ script: p._script })
  })
    .then(function(r) { return r.json(); })
    .then(function(d) {
      var v = (d.ok && d.values && d.values[needs] != null) ? String(d.values[needs]).trim() : '';
      var st = document.getElementById('status-' + extensionId);
      if (!v) {
        if (st) { st.textContent = 'Set "' + needs + '" and Save first, then test.'; st.className = 'mg-status mg-status-error'; }
        return;
      }
      runAction(p, p.actions[ai]);
    });
}

function runAction(extension, action, params) {
  if (action.confirm) { mgConfirm(action.confirm).then(function(__ok){ if (__ok) runAction_go(extension, action, params); }); return; }
  runAction_go(extension, action, params);
}
function runAction_go(extension, action, params) {
  var status = document.getElementById('status-' + extension.id);
  status.textContent = 'Running...';
  clearActionChoice(extension.id);
  fetch(API + '?action=extension-action&extension=' + encodeURIComponent(extension.id), {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ script: extension._script, action_id: action.id, params: params || {} })
  })
  .then(function(r) { return r.json(); })
  .then(function(data) {
    // SM927: BEFORE the ok/not-ok split, because a staged action's steps matter
    // MOST when it failed - "authenticated, then the room refused" and "nothing
    // answered at all" send an operator to different settings, and a bare failure
    // sends them back through every field.
    renderActionReport(extension.id, data);
    if (!data.ok) {
      mgShowWarning(data.error || 'Action failed', true);
      status.textContent = '';
      return;
    }
    mgClearWarning();
    // SM085: the action needs a decision (e.g. git-sync's "changed in both
    // places") - render the report and the declared choice buttons; the
    // chosen id is re-posted as params.choice.
    if (data.needs_choice && action.choices && action.choices.length) {
      status.textContent = '';
      renderActionChoice(extension, action, data);
      return;
    }
    // A diagnostic action (e.g. SMTP validate) returns a human message - show it.
    var msg = data.message || 'Done.';
    if (data.pages && data.pages.length) {
      msg += ' Pages: ' + data.pages.slice(0, 20).join(', ')
           + (data.pages.length > 20 ? ', …' : '');
    }
    status.textContent = msg;
    if (data.message) mgShowWarning(msg, false);

    // SM922: Link Audit - the findings arrive IN this result, so they open in a
    // modal that can re-run the audit. They used to be a URL fetched into a static
    // card, which is the same root as the audit scanning its own report.
    if (extension.id === 'audit' && action.id === 'run' && data.report) {
      renderAuditReport(extension, action, data.report);
    }
    else if (action.on_complete === 'open_url' && data[action.result_key]) {
      window.open(data[action.result_key], '_blank');
    }
    // THE RESULT STAYS. It used to be wiped after five seconds, which is
    // right for "Done." and wrong for everything that reports something: the
    // Briefs Status button said "Running...", then briefly gave its answer,
    // then left an empty line - so the button looked like it did nothing.
    //
    // Nothing needs tidying away: the line is replaced by "Running..." the
    // next time an action runs, and .mg-status:empty hides it when there is
    // nothing to say. An answer that removes itself while you are reading it
    // is worse than one that waits to be replaced.
  })
  .catch(function(e) {
    mgShowWarning('Error: ' + e.message, true);
    status.textContent = '';
  });
}

// SM927: the staged report. `steps` is one line per stage with a tick or a cross;
// `sent` is the body a delivery test handed to the server, shown VERBATIM - SM926
// put `${REQUEST_SCHEME}://${SERVER_NAME}` into every notification a site sent for
// an afternoon, and it became obvious the moment a human read the payload rather
// than a verdict about it. Monospace via mg-code-box, which is the furniture this
// manager already has for a value you are meant to read character by character.
function renderActionReport(extensionId, data) {
  var box = document.getElementById('report-' + extensionId);
  if (!box) return;
  var html = '';
  if (data && data.steps && data.steps.length) {
    html += '<div class="mg-code-box">';
    data.steps.forEach(function(s) {
      html += '<div>' + (s.ok ? '✓' : '✗') + ' ' + esc(s.step)
            + (s.unconfirmed ? ' (sent, not confirmed)' : '')
            + (s.detail ? ' - ' + esc(s.detail) : '') + '</div>';
    });
    html += '</div>';
  }
  if (data && data.sent) {
    html += '<div class="mg-extension-desc">The message as sent:</div>';
    html += '<div class="mg-code-box"><div>' + esc(data.sent) + '</div></div>';
  }
  box.innerHTML = html;
  box.hidden = !html;
}

// SM085: the needs_choice panel - the plain-language report, the list of
// items it concerns, one button per declared choice, and Cancel.
function renderActionChoice(extension, action, data) {
  var box = document.getElementById('choice-' + extension.id);
  if (!box) { mgShowWarning(data.message || 'A choice is needed.', false); return; }
  var html = '<div class="mg-extension-desc">' + esc(data.message || 'A choice is needed.') + '</div>';
  if (data.conflicts && data.conflicts.length) {
    html += '<ul>';
    data.conflicts.forEach(function(c) { html += '<li>' + esc(c) + '</li>'; });
    html += '</ul>';
  }
  html += '<div class="mg-wizard-actions">';
  (action.choices || []).forEach(function(c) {
    html += '<button class="mg-btn mg-btn-sm" onclick="chooseAction(\'' + esc(extension.id)
          + '\',\'' + esc(action.id) + '\',\'' + esc(c.id) + '\')">' + esc(c.label) + '</button>';
  });
  html += '<button class="mg-btn mg-btn-sm" onclick="clearActionChoice(\'' + esc(extension.id) + '\')">Cancel</button>';
  html += '</div>';
  box.innerHTML = html;
  box.style.display = 'block';
}

function chooseAction(extensionId, actionId, choiceId) {
  var p = (window._extensions || []).find(function(x) { return x.id === extensionId; });
  if (!p) return;
  var a = (p.actions || []).find(function(x) { return x.id === actionId; });
  if (!a) return;
  runAction_go(p, a, { choice: choiceId });
}

function clearActionChoice(extensionId) {
  var box = document.getElementById('choice-' + extensionId);
  if (box) { box.innerHTML = ''; box.style.display = 'none'; }
}

// SM922: THE REPORT IS DATA NOW, AND IT OPENS WHERE IT CAN BE RE-RUN.
//
// It used to be a page: the extension wrote /manager/audit-report.md into the docroot,
// this function fetched that URL, parsed the HTML and lifted its <main> into a
// static card. Three things followed from that one choice, and the ruling of
// 2026-09-30 treated them as one piece of work: the audit could scan its own last
// report (so the count moved between runs with no change to the site), there was no
// way to re-run it from where you were reading it, and a report sitting in the
// docroot is why the audit may not resolve as the operator - it would put the paths
// of pages a reader cannot see into something that reader can fetch.
//
// WITHHELD IS ITS OWN SECTION. A target that exists but is not visible to an
// anonymous visitor is not a broken link and is not confirmed either: the audit
// declined to judge it, and the panel says so rather than implying a verdict.
function renderAuditReport(extension, action, report) {
  var body = mgExtensionModal('Link Audit Report');
  if (!body) return;
  body.innerHTML = auditReportHtml(extension, report);
}

function auditReportHtml(extension, report) {
  var broken   = report.broken   || [];
  var withheld = report.withheld || [];
  var orphaned = report.orphaned || [];

  var h = '<div class="mg-stat-tiles">'
        + auditTile(broken.length,   'Broken link')
        + auditTile(withheld.length, 'Withheld target')
        + auditTile(orphaned.length, 'Orphaned page')
        + '</div>';
  h += '<p class="mg-muted">' + esc(report.generated_ymd || '') + ' &middot; '
     + esc(String(report.pages || 0)) + ' pages scanned</p>';
  h += '<div class="mg-wizard-actions">'
     + '<button class="mg-btn mg-btn-sm" onclick="rerunAudit(\'' + esc(extension.id) + '\')">'
     + 'Refresh</button></div>';

  if (!broken.length && !withheld.length && !orphaned.length) {
    h += '<p class="mg-empty">No broken links, withheld targets or orphaned pages.</p>';
    return h;
  }

  if (broken.length) {
    h += '<div class="mg-sec">Broken internal links</div>'
       + auditLinkTable(broken);
  }
  if (withheld.length) {
    h += '<div class="mg-sec">Withheld targets</div>'
       + '<p class="mg-muted">These pages exist but are not visible to an anonymous '
       + 'visitor, so the audit declined to judge the link. Not broken - and not '
       + 'confirmed as resolving either.</p>'
       + auditLinkTable(withheld);
  }
  if (orphaned.length) {
    h += '<div class="mg-sec">Orphaned pages</div>'
       + '<p class="mg-muted">Pages that exist but are not linked from any other '
       + 'page.</p><table class="mg-table"><thead><tr><th>Page</th><th></th></tr>'
       + '</thead><tbody>';
    orphaned.forEach(function(o) {
      var p = o.page || '';
      h += '<tr><td><a href="/' + esc(p) + '">/' + esc(p) + '</a></td>'
         + '<td>' + auditEditButton(p) + '</td></tr>';
    });
    h += '</tbody></table>';
  }
  return h;
}

function auditTile(n, label) {
  return '<div class="mg-stat-tile"><div class="mg-stat-value">' + esc(String(n))
       + '</div><div class="mg-stat-label">' + esc(label + (n === 1 ? '' : 's'))
       + '</div></div>';
}

function auditLinkTable(rows) {
  var h = '<table class="mg-table"><thead><tr><th>Page</th><th>Link</th><th></th>'
        + '</tr></thead><tbody>';
  rows.forEach(function(r) {
    var src = r.source || '';
    h += '<tr><td><a href="/' + esc(src) + '">/' + esc(src) + '</a></td>'
       + '<td><code>/' + esc(r.target || '') + '</code></td>'
       + '<td>' + auditEditButton(src) + '</td></tr>';
  });
  return h + '</tbody></table>';
}

// The editor link for a source page. The audit reports canonical paths, so the
// source file is that path plus .md unless it already names an extension.
function auditEditButton(page) {
  var md = String(page).replace(/^\//, '');
  if (!/\.\w+$/.test(md)) md += '.md';
  return '<a class="mg-btn mg-btn-sm" href="/manager/edit?path='
       + encodeURIComponent('/' + md) + '">Edit</a>';
}

// Refresh: the same action, run again, landing back in this modal. The confirm on
// the action is deliberately skipped here - the operator pressed Refresh on a panel
// that says what it is, and asking twice for the same thing trains people to click
// through dialogs.
function rerunAudit(extensionId) {
  var p = window._extensions.find(function(x) { return x.id === extensionId; });
  if (!p) return;
  var a = (p.actions || []).find(function(x) { return x.id === 'run'; });
  if (!a) return;
  var body = document.getElementById('extension-modal-body');
  if (body) body.textContent = 'Running the audit...';
  runAction_go(p, a);
}

// --- Blocked addresses (SM128, moved here by SM703) ---

function toggleBlocked(btn) {
  var el = document.getElementById('blocked-body');
  if (!el) return;
  var open = el.style.display !== 'none';
  el.style.display = open ? 'none' : '';
  btn.setAttribute('aria-expanded', open ? 'false' : 'true');
  if (!open) loadBlocked();
}

function loadBlocked() {
  var el = document.getElementById('blocked-body');
  if (!el) return;
  fetch(API + '?action=bad-url-blocks').then(function (r) { return r.json(); }).then(function (d) {
    if (!d || !d.ok) { el.innerHTML = '<p class="mg-muted">' + esc((d && d.error) || 'Unavailable.') + '</p>'; return; }
    var ips = Object.keys(d.blocks || {});
    // RULED 2026-10-11 "Always show the field": the operator blocks an address
    // by hand whether or not the list holds one already. It was drawn only
    // with a non-empty list, so a site with none offered no way to add the
    // first (TEST-PLAN-0154 R14); the empty list keeps its sentence.
    var h = '<div class="mg-line" style="margin:0 0 10px;">'
          + '<input class="mg-inp" id="block-add-ip" placeholder="203.0.113.4" '
          +   'style="max-width:14rem" onkeydown="if(event.key===\'Enter\')addBlock()">'
          + '<button class="mg-btn" onclick="addBlock()">Block this address</button>'
          + '</div>'
          + '<p class="mg-muted">A blocked address is refused the site &mdash; it receives 403 and is served nothing. '
          + 'Unblocking takes effect on its next request.</p>';
    if (!ips.length) { el.innerHTML = h + '<p class="mg-muted">No addresses are currently blocked.</p>'; return; }
    ips.sort(function (a, b) { return (d.blocks[b].since || 0) - (d.blocks[a].since || 0); });
    h += '<div class="mg-table-wrap"><table class="mg-table"><thead><tr>'
       + '<th>Address</th><th>Probes</th><th>Blocked since</th><th></th></tr></thead><tbody>';
    ips.forEach(function (ip) {
      var b = d.blocks[ip];
      var since = b.since ? new Date(b.since * 1000).toLocaleString() : '';
      h += '<tr><td><code>' + esc(ip) + '</code></td><td>' + esc(String(b.count))
         + '</td><td>' + esc(since) + '</td><td>'
         + '<button class="mg-btn mg-btn-sm" onclick="unblockIp(\'' + esc(ip).replace(/'/g, '') + '\')">Unblock</button>'
         + '</td></tr>';
    });
    el.innerHTML = h + '</tbody></table></div>';
  }).catch(function (e) { el.textContent = 'Error: ' + e.message; });
}

// SM704: block an address the operator names. The auto-blocker catches a
// probe once it trips a threshold; an operator watching one in the access log
// should not have to wait for that.
function addBlock() {
  var el = document.getElementById('block-add-ip');
  var ip = (el && el.value || '').replace(/^\s+|\s+$/g, '');
  if (!ip) return;
  fetch(API + '?action=bad-url-block&ip=' + encodeURIComponent(ip), {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}'
  })
    .then(function (r) { return r.json(); })
    .then(function (d) {
      if (!d || !d.ok) { showStatus((d && d.error) || 'Could not block', true); return; }
      showStatus(d.added ? 'Blocked ' + ip + '.' : ip + ' was already blocked.');
      el.value = '';
      loadBlocked();
    })
    .catch(function (e) { showStatus('Error: ' + e.message, true); });
}

function unblockIp(ip) {
  fetch(API + '?action=bad-url-unblock&ip=' + encodeURIComponent(ip), { method: 'POST' })
    .then(function (r) { return r.json(); })
    .then(function (d) {
      if (!d || !d.ok) { showStatus((d && d.error) || 'Unblock failed', true); return; }
      showStatus('Unblocked ' + ip + '.');
      loadBlocked();
    })
    .catch(function (e) { showStatus('Error: ' + e.message, true); });
}

// SM1369 X6, H-8: the manager pages an extension declares (owns.hooks.panels),
// as { href, label }: /manager/<id>-<name> for the page <name>.md, for a caller who
// holds the page's capability (window._callerCaps, from whoami; ruling 194). The
// page itself refuses anyone else (403).
function extensionPanels(extension) {
  var owns = extension && extension.owns, hooks = owns && owns.hooks;
  var list = hooks && Array.isArray(hooks.panels) ? hooks.panels : [];
  var held = window._callerCaps || {};
  return list.filter(function (p) {
    return p && typeof p.page === 'string' && /^[a-z][a-z0-9-]*\.md$/.test(p.page) && typeof p.label === 'string'
      && typeof p.cap === 'string' && !!held[p.cap];
  }).map(function (p) {
    return { href: '/manager/' + extension.id + '-' + p.page.replace(/\.md$/, ''), label: p.label };
  });
}

// SM957: THE SUBMISSIONS VIEWER IS ITS OWN PAGE NOW - /manager/submissions
// (starter/manager/submissions.md). It lived here, in a modal opened from the
// form handler's row and from ?submissions=<store>, which made the task an
// operator does most days three clicks into an extension's configuration. ONE
// copy: the code moved rather than being duplicated, and the old address
// redirects (redirectLegacySubmissions, above) so a bookmark or an old link
// still lands on the rows.

if (!redirectLegacySubmissions(window.location)) loadExtensions();
</script>
