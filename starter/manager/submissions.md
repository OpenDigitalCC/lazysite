---
title: Submissions
auth: manager
search: false
---

<div id="status" class="mg-status"></div>

<!-- SM957: WHAT VISITORS SENT, ONE CLICK FROM THE MENU. The release manager:
     "submissions are found by navigating to extension config. they should be
     easier to find." This page is the menu's first entry: every form, what each
     has kept, and the rows newest first with the quarantine filter. A single
     submission - what a notice links to - is /manager/submission, and each row
     here opens it. Reading this page marks no notice read (SM938 D3: reading is
     said, not inferred); the menu's count moves when a notice is followed. -->
<div class="mg-card">
  <div class="mg-card-header">
    <span class="mg-card-title">Forms</span>
    <span class="mg-card-subtitle">every form on this site, and what each has kept</span>
  </div>
  <div class="mg-card-body">
    <div class="mg-list" id="subs-forms"><div class="mg-empty">Loading...</div></div>
  </div>
</div>

<div class="mg-card">
  <div class="mg-card-header"><span class="mg-card-title" id="subs-title">Submissions</span></div>
  <div class="mg-card-body">
    <div id="subs-body"><p class="mg-muted">Loading...</p></div>
  </div>
</div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';

// --- SM182/SM187: the submissions viewer, a page of its own since SM957 -----
// The raw .jsonl store lives in the reserved lazysite/ tree, so it can't be
// opened in the file editor; this page shows it as a table. A handled row can
// be deleted by its stable _id (server rewrites the store).
//
// SM957: THIS WAS A MODAL ON THE EXTENSION CONFIG PAGE, opened from the form
// handler's row - the task an operator does most days, three clicks into an
// extension's configuration. It MOVED here rather than being copied: there is
// one viewer, and the old address (plugin-config?submissions=<store>) is a
// redirect to this page. t/unit/manager/180 and 201 drive these functions, and
// 202 holds that plugin-config.md keeps no second copy.
//
// SM793: EVERY VALUE ARRIVES AS TEXT. The table is built from DOM nodes and
// textContent, and each button's action is a closure rather than an attribute,
// so a stored value never passes through HTML at all - there is no escape to
// forget, and no quoting of an attribute to get wrong. The server returns the
// submission as it was sent, which is what the control API and MCP read too.

function subsNode(tag, cls, text) {
  var n = document.createElement(tag);
  if (cls) n.className = cls;
  if (text != null) n.textContent = String(text);
  return n;
}
function subsMessage(text) { return subsNode('p', 'mg-muted', text); }

// SM957: a form, as a row: its name, what it has kept, a way to show it, and
// the Handlers page for that form. Handlers left the menu (the ruling's M5) and
// is reached from each form - this link, and the Extensions page.
function subsFormRow(name, meta, show) {
  var row = subsNode('div', 'mg-row');
  row.appendChild(subsNode('span', 'mg-row-name', name));
  row.appendChild(subsNode('span', 'mg-row-meta', meta));
  var act = subsNode('span', 'mg-row-actions');
  var b = subsNode('button', 'mg-btn mg-btn-sm', 'Show');
  b.type = 'button';
  b.setAttribute('data-impact', 'inert');
  b.addEventListener('click', show);
  act.appendChild(b);
  var h = subsNode('a', 'mg-btn mg-btn-sm', 'Handlers');
  h.href = '/manager/handlers?form=' + encodeURIComponent(name);
  act.appendChild(h);
  row.appendChild(act);
  return row;
}

function setSubsForms(node) {
  var el = document.getElementById('subs-forms');
  if (el) { el.textContent = ''; el.appendChild(node); }
}

// Every form on the site, from form-list - names and counts, never content. The
// one shown first is the one the address names (?form=), else the first form
// that has kept anything.
function loadForms(want) {
  fetch(API + '?action=form-list')
    .then(function(r) { return r.json(); })
    .then(function(d) {
      if (!d.ok) {
        setSubsForms(subsMessage(d.error || 'Could not list the forms.'));
        setSubsBody(subsMessage('Nothing to show.'), 'Submissions');
        return;
      }
      var forms = d.forms || [];
      if (!forms.length) {
        setSubsForms(subsMessage('No forms yet. A page gets a form with a :::form block and a "form:" name in its front matter.'));
        setSubsBody(subsMessage('Nothing has been submitted.'), 'Submissions');
        return;
      }
      var frag = document.createDocumentFragment();
      var first = null;
      forms.forEach(function(f) {
        var n = f.row_count || 0;
        frag.appendChild(subsFormRow(f.name, n ? n + ' submission' + (n === 1 ? '' : 's') : 'none kept',
          function() { showSubmissionTable('', f.name); }));
        if (want && f.name === want) first = f.name;
      });
      if (!first) forms.some(function(f) { if (f.row_count) { first = f.name; return true; } return false; });
      setSubsForms(frag);
      if (first) showSubmissionTable('', first);
      else setSubsBody(subsMessage('No form has kept a submission yet.'), 'Submissions');
    })
    .catch(function() { setSubsForms(subsMessage('Could not list the forms.')); });
}

// One store directory's forms: ?store=<dir>, which the Handlers page links for a
// file handler with its own path, and which the old ?submissions= address on
// the Extension Config page now redirects to.
function loadStore(dirPath) {
  fetch(API + '?action=list&path=' + encodeURIComponent(dirPath))
    .then(function(r) { return r.json(); })
    .then(function(data) {
      var files = (data.ok && data.entries ? data.entries : []).filter(function(f) {
        return f.type === 'file' && /\.jsonl$/.test(f.name || '');
      });
      if (!files.length) {
        setSubsForms(subsMessage('No submissions in ' + dirPath + ' yet.'));
        setSubsBody(subsMessage('Nothing has been submitted.'), 'Submissions');
        return;
      }
      var frag = document.createDocumentFragment();
      files.forEach(function(f) {
        var name = (f.name || '').replace(/\.jsonl$/, '');
        frag.appendChild(subsFormRow(name, 'kept in ' + dirPath, function() { showSubmissionTable(f.path, name); }));
      });
      setSubsForms(frag);
      showSubmissionTable(files[0].path, (files[0].name || '').replace(/\.jsonl$/, ''));
    })
    .catch(function() { setSubsForms(subsMessage('Could not list submissions.')); });
}

// SM216: a quarantine filter, kept per-open so a reload keeps the view.
var subsFilter  = 'all';   // 'all' | 'quarantined'
var subsCurrent = null;
var subsLoaded  = null;    // SM187: last-loaded {file,form,cols,rows} for CSV/bulk
function setSubsFilter(f) { subsFilter = f; if (subsCurrent) showSubmissionTable(subsCurrent.file, subsCurrent.form); }

function showSubmissionTable(filePath, formName) {
  subsCurrent = { file: filePath, form: formName };
  setSubsBody(subsMessage('Loading ' + formName + '\u2026'), 'Submissions: ' + formName);
  // SM957: by store path when the caller has one, else by form name. The server
  // resolves a form's store as MCP does and answers with the file it read, and
  // that is what every row action below then names.
  var q = filePath ? 'file=' + encodeURIComponent(filePath) : 'form=' + encodeURIComponent(formName);
  fetch(API + '?action=form-submissions&' + q)
    .then(function(r) { return r.json(); })
    .then(function(d) {
      if (!d.ok) { setSubsBody(subsMessage(d.error || 'Could not read submissions'), 'Submissions'); return; }
      if (!filePath && d.file) { filePath = d.file; subsCurrent.file = filePath; }
      // SM216: _quarantined / _spam_reason are status meta, not form fields - drive
      // the row marking, not a data column.
      // SM858: _approved_* record the account a row became - status, not data.
      var META = { _quarantined: 1, _spam_reason: 1, _approved_account: 1, _approved_by: 1, _approved_at: 1 };
      // SM858: the field the form names as an account's address; set only when
      // the form declares account_email:, and only then is Approve offered.
      var acctField = d.account_email || '';
      var cols = (d.columns || []).filter(function(c) { return !META[c]; });
      // SM957: NEWEST FIRST. The store is append-only, so its last line is the
      // newest; the server returns file order and the reader wants the reverse.
      var rows = (d.rows || []).slice().reverse();
      if (!rows.length || !cols.length) {
        setSubsBody(subsMessage('No submissions in ' + formName + ' yet.'), 'Submissions: ' + formName);
        return;
      }
      var qcount = rows.filter(function(r) { return r._quarantined; }).length;
      var view = (subsFilter === 'quarantined') ? rows.filter(function(r) { return r._quarantined; }) : rows;
      subsLoaded = { file: filePath, form: formName, cols: cols, rows: rows };   // SM187

      var frag = document.createDocumentFragment();

      // SM187: a toolbar - quarantine filter (if any), CSV export and bulk delete
      // of the checked rows. SM847: toolbar buttons are the standard size.
      var bar = subsNode('div', 'mg-toolbar');
      var button = function(label, cls, onclick, disabled) {
        var b = subsNode('button', 'mg-btn' + (cls ? ' ' + cls : ''), label);
        b.type = 'button';
        b.disabled = !!disabled;
        b.addEventListener('click', onclick);
        return b;
      };
      if (qcount) {
        var qn = subsNode('span');
        qn.appendChild(subsNode('strong', null, qcount));
        qn.appendChild(document.createTextNode(' quarantined (suspected spam, kept out of notifications).'));
        bar.appendChild(qn);
        bar.appendChild(button('All', null, function() { setSubsFilter('all'); }, subsFilter === 'all'));
        bar.appendChild(button('Quarantine only', null, function() { setSubsFilter('quarantined'); }, subsFilter === 'quarantined'));
      }
      bar.appendChild(button('Download CSV', null, downloadSubmissionsCsv));
      bar.appendChild(button('Delete selected', 'mg-btn-danger', bulkDeleteSubmissions));
      frag.appendChild(bar);

      var wrap  = subsNode('div', 'mg-table-wrap');
      var table = subsNode('table', 'mg-table mg-submissions-table');
      var head  = document.createElement('tr');
      var th0   = document.createElement('th');
      var all   = document.createElement('input');
      all.type = 'checkbox'; all.title = 'Select all';
      all.addEventListener('click', function() { subsToggleAll(all); });
      th0.appendChild(all);
      head.appendChild(th0);
      head.appendChild(subsNode('th', null, 'Status'));
      cols.forEach(function(c) { head.appendChild(subsNode('th', null, c)); });
      head.appendChild(subsNode('th'));
      var thead = document.createElement('thead');
      thead.appendChild(head);
      table.appendChild(thead);

      var tbody = document.createElement('tbody');
      view.forEach(function(row) {
        var tr = document.createElement('tr');
        var cbCell = document.createElement('td');
        var cb = document.createElement('input');
        cb.type = 'checkbox'; cb.className = 'mg-sub-cb'; cb.value = String(row._id);
        cbCell.appendChild(cb);
        tr.appendChild(cbCell);
        var st = document.createElement('td');
        if (row._quarantined) {
          var tag = subsNode('span', 'mg-tag mg-tag-off', 'quarantined');
          tag.title = String(row._spam_reason || '');
          st.appendChild(tag);
          // SM954: the reason is SHOWN, not only a tooltip - a hover title is
          // invisible on a touch screen and easy to miss on any other.
          if (row._spam_reason) st.appendChild(subsNode('span', 'mg-sub-reason mg-muted', ' ' + row._spam_reason));
        }
        if (row._approved_account) {
          var ap = subsNode('span', 'mg-tag mg-tag-on', 'account: ' + row._approved_account);
          ap.title = 'approved' + (row._approved_by ? ' by ' + row._approved_by : '')
                   + (row._approved_at ? ' at ' + row._approved_at : '');
          st.appendChild(ap);
        }
        tr.appendChild(st);
        cols.forEach(function(c) { tr.appendChild(subsNode('td', null, row[c] == null ? '' : row[c])); });
        var act = subsNode('td', 'mg-cell-actions');
        // SM957: the row's own page - the one a submission notice links to.
        var open = subsNode('a', 'mg-btn mg-btn-sm', 'Open');
        open.href = '/manager/submission?file=' + encodeURIComponent(filePath) + '&id=' + encodeURIComponent(String(row._id));
        // Following it reads that row's notice, as following the notice does;
        // the bell owns the read state (window.mgNoticeFollowed, layout.tt).
        open.addEventListener('click', function() {
          if (typeof window !== 'undefined' && window.mgNoticeFollowed) window.mgNoticeFollowed(filePath, row._id);
        });
        act.appendChild(open);
        if (row._quarantined) {
          act.appendChild(button('Confirm', 'mg-btn-sm', function() { confirmSubmissionRow(filePath, row._id, formName); }));
        }
        // SM858: Approve creates an account from this row. Offered only on a
        // form that declares account_email:, on a row not yet approved and not
        // quarantined - the server refuses those too.
        if (acctField && !row._approved_account && !row._quarantined) {
          act.appendChild(button('Approve', 'mg-btn-sm mg-btn-primary', function() {
            approveSubmissionRow(filePath, row._id, formName, row[acctField]);
          }));
        }
        act.appendChild(button('Delete', 'mg-btn-sm mg-btn-danger', function() { deleteSubmissionRow(filePath, row._id, formName); }));
        tr.appendChild(act);
        tbody.appendChild(tr);
      });
      table.appendChild(tbody);
      wrap.appendChild(table);
      frag.appendChild(wrap);

      var note = 'Showing ' + d.shown + ' of ' + d.total + ' submission' + (d.total === 1 ? '' : 's');
      if (d.truncated) note += ' (most recent ' + d.shown + ')';
      if (d.malformed) note += '; ' + d.malformed + ' unreadable line' + (d.malformed === 1 ? '' : 's') + ' skipped';
      frag.appendChild(subsMessage(note));
      setSubsBody(frag, 'Submissions: ' + formName);
    })
    .catch(function() { setSubsBody(subsMessage('Could not read submissions.'), 'Submissions'); });
}

// SM216: confirm a quarantined row as legitimate (clears the flag; the message
// stays in the store, just no longer flagged). Reloads the table in place.
function confirmSubmissionRow(filePath, rowId, formName) {
  fetch(API + '?action=form-submission-confirm', {
    method: 'POST', credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ file: filePath, id: rowId })
  }).then(function(r) { return r.json(); }).then(function(d) {
    if (!d.ok) { showStatus(d.error || 'Confirm failed', true); return; }
    showStatus('Submission confirmed - moved out of quarantine.');
    showSubmissionTable(filePath, formName);
  }).catch(function(e) { showStatus('Confirm error: ' + e.message, true); });
}

// SM858: approve an account from a submission. The server reads the address
// from the stored row - `address` is only for the question asked here - and
// derives the username from it; every refusal comes back in its own words.
function approveSubmissionRow(filePath, rowId, formName, address) {
  var go = function(ok) {
    if (!ok) return;
    fetch(API + '?action=form-submission-approve', {
      method: 'POST', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ file: filePath, id: rowId })
    }).then(function(r) { return r.json(); }).then(function(d) {
      if (!d.ok) { showStatus(d.error || 'Approve failed', true); return; }
      var msg = 'Account "' + d.user + '" created for ' + d.email
              + ((d.group && d.group.length) ? ', in ' + d.group.join(', ') : ', in no group')
              // SM963: a flagged group it could not be placed in is said, with why.
              + ((d.unplaced && d.unplaced.length) ? '. It could NOT be placed in '
                  + d.unplaced.map(function(u) { return u.group + ' (' + u.error + ')'; }).join('; ')
                  + ' - place it on the Groups page' : '')
              + '. They can fetch their own set-password link from the Forgot password page'
              + ' with that address, or you can send them this one: ' + (d.url || d.path || '');
      if (typeof mgConfirm === 'function') { mgConfirm(msg, { ok: 'Done' }); } else { showStatus(msg); }
      showSubmissionTable(filePath, formName);
    }).catch(function(e) { showStatus('Approve error: ' + e.message, true); });
  };
  var msg = 'Create an account for ' + (address == null ? '' : address) + ' from this "'
          + formName + '" submission? The username is taken from the address.';
  if (typeof mgConfirm === 'function') { mgConfirm(msg, { ok: 'Approve' }).then(go); }
  else { go(window.confirm(msg)); }
}

function deleteSubmissionRow(filePath, rowId, formName) {
  var go = function(ok) {
    if (!ok) return;
    fetch(API + '?action=form-submission-delete', {
      method: 'POST', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ file: filePath, id: rowId })
    }).then(function(r) { return r.json(); }).then(function(d) {
      if (!d.ok) { showStatus(d.error || 'Delete failed', true); return; }
      showSubmissionTable(filePath, formName);   // reload the table in place
    }).catch(function(e) { showStatus('Delete error: ' + e.message, true); });
  };
  var msg = 'Delete this submission? It is permanently removed from "' + formName + '".';
  if (typeof mgConfirm === 'function') { mgConfirm(msg, { danger: true, ok: 'Delete' }).then(go); }
  else { go(window.confirm(msg)); }
}

// SM187: select-all toggle for the row checkboxes.
function subsToggleAll(master) {
  var boxes = document.querySelectorAll('.mg-sub-cb');
  for (var i = 0; i < boxes.length; i++) { boxes[i].checked = master.checked; }
}

// SM187: delete every checked row in one atomic server-side rewrite.
function bulkDeleteSubmissions() {
  if (!subsLoaded) return;
  var ids = [];
  var boxes = document.querySelectorAll('.mg-sub-cb');
  for (var i = 0; i < boxes.length; i++) { if (boxes[i].checked) ids.push(boxes[i].value); }
  if (!ids.length) { showStatus('No rows selected.', true); return; }
  var filePath = subsLoaded.file, formName = subsLoaded.form;
  var go = function(ok) {
    if (!ok) return;
    fetch(API + '?action=form-submissions-delete-bulk', {
      method: 'POST', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ file: filePath, ids: ids })
    }).then(function(r) { return r.json(); }).then(function(d) {
      if (!d.ok) { showStatus(d.error || 'Bulk delete failed', true); return; }
      showStatus(d.deleted + ' submission' + (d.deleted === 1 ? '' : 's') + ' deleted.');
      showSubmissionTable(filePath, formName);   // reload in place
    }).catch(function(e) { showStatus('Bulk delete error: ' + e.message, true); });
  };
  var msg = 'Delete ' + ids.length + ' selected submission' + (ids.length === 1 ? '' : 's')
          + '? They are permanently removed from "' + formName + '".';
  if (typeof mgConfirm === 'function') { mgConfirm(msg, { danger: true, ok: 'Delete' }).then(go); }
  else { go(window.confirm(msg)); }
}

// SM187: download the loaded store as a CSV, built client-side from the rows
// already in hand (no new server surface). Columns are the visible fields plus
// the quarantine status/reason; every cell is RFC-4180 quoted.
function downloadSubmissionsCsv() {
  if (!subsLoaded || !subsLoaded.rows.length) { showStatus('Nothing to export.', true); return; }
  var cols = subsLoaded.cols.concat(['quarantined', 'spam_reason']);
  var q = function(v) { return '"' + String(v == null ? '' : v).replace(/"/g, '""') + '"'; };
  var lines = [cols.map(q).join(',')];
  subsLoaded.rows.forEach(function(row) {
    lines.push(cols.map(function(c) {
      if (c === 'quarantined') return q(row._quarantined ? 'yes' : '');
      if (c === 'spam_reason') return q(row._spam_reason || '');
      return q(row[c]);
    }).join(','));
  });
  var blob = new Blob([lines.join('\r\n') + '\r\n'], { type: 'text/csv;charset=utf-8' });
  var url = URL.createObjectURL(blob);
  var a = document.createElement('a');
  a.href = url;
  a.download = (subsLoaded.form || 'submissions').replace(/[^A-Za-z0-9_-]/g, '_') + '-submissions.csv';
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  setTimeout(function() { URL.revokeObjectURL(url); }, 1000);
}

// SM793: a NODE, never a string of HTML - see the note above the viewer.
function setSubsBody(node, title) {
  var b = document.getElementById('subs-body');
  var t = document.getElementById('subs-title');
  if (t && title) t.textContent = title;
  if (b) { b.textContent = ''; b.appendChild(node); }
}

// What the address asks for: ?store=<dir> (validated as the old viewer did -
// a /-bounded path with no ..), else every form, opening ?form=<name> if given.
// `search` is a parameter so a test can drive it without a browser.
function subsBoot(search) {
  var q = new URLSearchParams(search || '');
  var store = q.get('store') || '';
  if (store) {
    if (/^\/[A-Za-z0-9_\/.-]*\/$/.test(store) && !/\.\./.test(store)) { loadStore(store); return 'store'; }
    showStatus('That store address is not one this page reads, so every form is shown instead.', true);
  }
  loadForms(q.get('form') || '');
  return 'forms';
}

subsBoot(window.location.search);
</script>
