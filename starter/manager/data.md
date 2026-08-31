---
title: Data tables
auth: manager
search: false
---


<div id="status" class="mg-status"></div>

<p style="font-size:0.85em;color:var(--mg-text-muted);margin:0 0 12px;">Tables this site declares and holds &mdash; a product list, an events calendar, a directory. A table is <strong>closed until it is published</strong>: until its descriptor says <code>public: true</code>, an anonymous visitor sees nothing, not even that it exists. What you see here is what the store holds, whoever may read it.</p>

<div style="display:flex;gap:8px;margin-bottom:12px;align-items:center;">
<button class="mg-btn" onclick="loadTables()">Refresh</button>
<button class="mg-btn" onclick="declareTable()">Declare a table&hellip;</button>
<span id="table-count" style="font-size:0.85em;color:var(--mg-text-muted);"></span>
</div>

<p style="font-size:0.85em;color:var(--mg-text-muted);margin:0 0 12px;"><strong>JSON</strong> is the exact copy &mdash; types survive, and it is the one that goes back in. <strong>CSV</strong> is for a spreadsheet: it has no types, cannot tell an unset value from an empty one, and cells that a spreadsheet would run as formulas are prefixed with an apostrophe to make them safe, which changes those values.</p>

<div class="mg-list" id="table-list">
<div class="mg-row"><span class="mg-file-name">Loading...</span></div>
</div>

<!-- SM680: the rows panel is a MODAL, not a block below the listing.
     A watched user pressed Rows and did not see it happen: the panel opened
     underneath what they were looking at, off-screen on a page with several
     tables or a short window. The control worked exactly as built and the
     person did not know it had.

     It is the same objection SM640 answered on the Plugin Config page. A
     table's rows are a DIFFERENT SUBJECT from the list of tables, not more
     detail about one entry in it - and the panel has its own pager, its own
     filter and its own editor, which is an application nested inside a
     listing. -->
<div id="rows-panel" class="mg-sheet" style="display:none;">
 <div class="mg-sheet-panel">
  <div class="mg-sheet-head">
   <span id="rows-title"></span>
   <span class="mg-sheet-sub" id="rows-note"></span>
   <button class="mg-sheet-close" onclick="closeRows()" title="Close" aria-label="Close">&times;</button>
  </div>
  <div class="mg-sheet-body">
  <div style="margin:0 0 10px;display:flex;gap:8px;align-items:center;flex-wrap:wrap;">
    <button class="mg-btn mg-btn-primary" id="row-add-btn" onclick="openEditor(null)">Add a row</button>
    <label class="mg-btn" style="cursor:pointer;">Import CSV&hellip;<input type="file" id="import-file" accept=".csv,text/csv" style="display:none;" onchange="planImport()"></label>
    <span id="rows-pager" style="display:none;margin-left:auto;">
      <button class="mg-btn" id="rows-prev" onclick="pageRows(-1)">&larr; Prev</button>
      <button class="mg-btn" id="rows-next" onclick="pageRows(1)">Next &rarr;</button>
    </span>
  </div>

  <!-- DM-4: THE IMPORT IS STAGED. The file is sent once for a PLAN, which
       validates every row and writes nothing; the plan is shown with its
       counts; only then is the same file sent again with apply=1. A reject in
       any row refuses the whole file, naming the row as the spreadsheet
       numbers it, so an operator fixes one cell and re-uploads rather than
       discovering half a file landed. -->
  <div id="import-panel" class="mg-card" style="display:none;margin:0 0 12px;max-width:40rem;">
    <div class="mg-card-header"><span class="mg-card-title">Import</span></div>
    <div class="mg-card-body">
    <div id="import-plan" style="font-size:0.9em;"></div>
    <div id="import-error" class="mg-status"></div>
    <div style="display:flex;gap:8px;margin-top:10px;">
      <button class="mg-btn mg-btn-change mg-btn-primary" id="import-apply-btn" onclick="applyImport()" style="display:none;">Apply</button>
      <button class="mg-btn" onclick="cancelImport()">Cancel</button>
    </div>
    </div>
  </div>
  <div class="mg-table-wrap">
    <table class="mg-table" id="rows-table"><thead></thead><tbody></tbody></table>
  </div>
  </div>
 </div>
</div>

<!-- DM-5: THE DESCRIPTOR IS EDITED AS TEXT, on purpose. A descriptor is a
     thing an operator reads - their comments, their key order and their
     spacing are part of what they wrote, and a form that regenerated the file
     would throw all three away. The server validates it with the SAME loader
     the render path uses, so a refusal here is the refusal a page would get,
     named by field and rule. Saving never migrates: the plan below says what
     a migration WOULD do, and the operator decides. -->
<div id="descriptor-panel" class="mg-card" style="display:none;margin-top:18px;max-width:48rem;">
  <div class="mg-card-header"><span class="mg-card-title" id="descriptor-title"></span></div>
  <div class="mg-card-body">
  <!-- SM502 U-4: THE FORM IS A SECOND DOOR ONTO THE TEXT. The YAML stays
       authoritative (DM-5: it is a thing an operator reads); the form edits
       the same declaration without asking anyone to type YAML, and saving
       from it regenerates the text - comments do not survive that, and the
       tab says so. -->
  <div style="display:flex;gap:6px;margin:0 0 10px;">
    <button class="mg-btn" id="desc-tab-form" onclick="descTab('form')">Fields</button>
    <button class="mg-btn" id="desc-tab-yaml" onclick="descTab('yaml')">YAML</button>
  </div>
  <div id="descriptor-form" style="font-size:0.9em;"></div>
  <p id="descriptor-yaml-note" style="display:none;font-size:0.85em;color:var(--mg-text-muted);margin:0 0 6px;">The text as stored. Saving from the Fields tab regenerates it; comments and ordering are kept only when you save from here.</p>
  <textarea id="descriptor-text" class="mg-inp" rows="18" spellcheck="false" style="display:none;width:100%;font-family:monospace;font-size:0.9em;"></textarea>
  <div id="descriptor-error" class="mg-status" style="margin-top:8px;"></div>
  <div style="display:flex;gap:8px;margin-top:10px;flex-wrap:wrap;">
    <button class="mg-btn mg-btn-primary" onclick="saveDescriptor()">Save descriptor</button>
    <button class="mg-btn" onclick="planMigration()">What would migrating do?</button>
    <button class="mg-btn" onclick="closeDescriptor()">Cancel</button>
  </div>

  <!-- The plan. Three outcomes, and the panel says which: nothing to do;
       additive steps that migrate applies; or BLOCKED steps that need a
       rebuild - at which point SM487's data checks are shown, so "2 rows have
       no when" is read at the moment of deciding, not after confirming. -->
  <div id="plan-panel" style="display:none;margin-top:12px;border-top:1px solid #eee;padding-top:10px;">
    <div id="plan-body" style="font-size:0.9em;"></div>
    <div id="plan-error" class="mg-status"></div>
    <div style="display:flex;gap:8px;margin-top:10px;flex-wrap:wrap;">
      <button class="mg-btn mg-btn-change mg-btn-primary" id="plan-migrate-btn" onclick="runMigrate()" style="display:none;">Migrate</button>
      <button class="mg-btn mg-btn-danger" id="plan-rebuild-btn" onclick="runRebuild()" style="display:none;">Rebuild, losing the named columns</button>
    </div>
  </div>
  </div>
</div>

<!-- DM-3: THE EDITOR IS BUILT FROM THE DESCRIPTOR, NOT WRITTEN BY HAND. One
     input per declared field, its kind chosen by the field's type; enum is a
     select of the declared values, boolean a checkbox, textarea when the
     descriptor asks for one. The page never decides what is VALID - that is
     Value.pm's job on the server, and a refused value comes back naming the
     field so the form can point at it. Two validators for one store would
     disagree the first time one of them changed. -->
<div id="row-editor" class="mg-card" style="display:none;margin-top:14px;max-width:40rem;">
  <div class="mg-card-header"><span class="mg-card-title" id="editor-title"></span></div>
  <div class="mg-card-body">
  <div id="editor-fields"></div>
  <div id="editor-error" class="mg-status" style="margin-top:8px;"></div>
  <div style="display:flex;gap:8px;margin-top:12px;">
    <button class="mg-btn mg-btn-primary" onclick="saveRow()">Save</button>
    <button class="mg-btn" onclick="closeEditor()">Cancel</button>
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
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;')
    .replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

/* A VALUE THAT IS ABSENT AND A VALUE THAT IS EMPTY ARE DIFFERENT THINGS in the
   store, and they stay different here. Collapsing them would make "never
   recorded" and "recorded as nothing" look identical in the one place an
   operator goes to find out which. */
function cell(v) {
  if (v === null || v === undefined) {
    return '<span style="color:var(--mg-text-light);font-style:italic;">not set</span>';
  }
  if (v === '') {
    return '<span style="color:var(--mg-text-light);font-style:italic;">empty</span>';
  }
  if (v === true)  return 'yes';
  if (v === false) return 'no';
  return escHtml(v);
}

function loadTables() {
  showStatus('');
  fetch(API + '?action=data-tables')
    .then(function(r) { return r.json(); })
    .then(function(data) {
      var list = document.getElementById('table-list');
      if (!data.ok) {
        /* The plugin being disabled is the ordinary case, not a fault: it ships
           off and an operator turns it on. Say which it is rather than showing
           a bare error. */
        list.innerHTML = '<div class="mg-row"><span class="mg-file-name">'
          + escHtml(data.error || 'could not read the tables') + '</span></div>';
        document.getElementById('table-count').textContent = '';
        return;
      }
      var tables = data.tables || [];
      document.getElementById('table-count').textContent =
        tables.length === 1 ? '1 table' : tables.length + ' tables';

      if (!tables.length) {
        list.innerHTML = '<div class="mg-row"><span class="mg-file-name">'
          + 'No tables are declared yet. An agent or the API declares one with '
          + '<code>data-table-save</code>.</span></div>';
        return;
      }

      var html = '';
      for (var i = 0; i < tables.length; i++) {
        var t = tables[i];
        var name = t.table || t.name || '';
        var bits = [];
        if (t.title && t.title !== name) bits.push(escHtml(t.title));
        bits.push(t.public ? 'published' : 'not published');
        // SM679: how many rows. `row_count` is ABSENT rather than 0 when the
        // server could not count - a table awaiting migration, or one whose
        // query failed - so the test is `typeof`, not truthiness: `0` is a real
        // and useful answer and must not read as "unknown".
        if (typeof t.row_count === 'number') {
          bits.push(t.row_count + ' row' + (t.row_count === 1 ? '' : 's'));
        }
        if (t.pending_schema) bits.push('needs migrating');
        // SM678 remainder: say whether a rule governs this table, where the
        // operator is looking. "No rule" and "a rule nobody has opened" looked
        // identical until now, so learning which tables were governed meant
        // opening every one.
        bits.push(t.has_acl ? 'access rule set' : 'no access rule');
        var enc = encodeURIComponent(name);
        html += '<div class="mg-row">'
          + '<span class="mg-file-name"><code>' + escHtml(name) + '</code> '
          + '<span style="color:var(--mg-text-muted);font-size:0.85em;">' + bits.join(' &middot; ') + '</span></span>'
          // THE ROW HOLDS WHAT AN OPERATOR SCANS FOR; the expander holds what
          // they act on for one table. Rows and Fields are how you READ a
          // table and stay in the list; the exports take you out of it, and
          // the access rule is one table's business. Same division the Files
          // page makes - a row, and an expand card for the rest.
          + '<span><button class="mg-btn" onclick="loadRows(\'' + escHtml(name) + '\')">Rows</button> '
          + '<button class="mg-btn" onclick="openDescriptor(\'' + escHtml(name) + '\')">Fields</button> '
          + '<a href="#" class="mg-chev" onclick="toggleTableAcl(this,\'' + escHtml(name) + '\'); return false;" title="More for this table">&#9662;</a>'
          + '</span>'
          + '</div>'
          + '<div class="mg-expand" data-acl-for="' + escHtml(name) + '" style="display:none;">'
          +   '<div class="mg-expand-body">'
          /* Plain links, not fetch(): a download is a navigation, and letting
             the browser do it means the file lands where the operator expects
             instead of being assembled in memory. */
          +     '<div class="mg-perms-rights-label">Export</div>'
          +     '<div class="mg-perms-actions">'
          +       '<a class="mg-btn" href="' + API + '?action=data-export&amp;format=json&amp;table=' + enc + '">JSON</a> '
          +       '<a class="mg-btn" href="' + API + '?action=data-export&amp;format=csv&amp;table=' + enc + '">CSV</a>'
          +     '</div>'
          +     '<div class="mg-acl-body"></div>'
          +   '</div>'
          + '</div>';
      }
      list.innerHTML = html;
    })
    .catch(function(e) { showStatus('Could not load tables: ' + e, true); });
}

var PAGE = { size: 200, page: 0, total: 0 };

function pageRows(step) {
  var last = Math.max(0, Math.ceil(PAGE.total / PAGE.size) - 1);
  var p = Math.min(last, Math.max(0, PAGE.page + step));
  if (p !== PAGE.page) loadRows(CURRENT.table, p);
}

function loadRows(table, page) {
  showStatus('');
  /* SM502 U-1: the server has ALWAYS capped this read (200 by default), so a
     big table silently showed one page with nothing saying so. Page it
     honestly: ask for one page, show which slice this is of how many. */
  PAGE.page = page || 0;
  fetch(API + '?action=data-rows&table=' + encodeURIComponent(table)
        + '&limit=' + PAGE.size + '&offset=' + (PAGE.page * PAGE.size))
    .then(function(r) { return r.json(); })
    .then(function(data) {
      var panel = document.getElementById('rows-panel');
      var tbl   = document.getElementById('rows-table');
      // 'flex', not 'block': .mg-sheet centres its panel with flexbox, so
      // block layout puts the sheet in the top-left corner instead.
      panel.style.display = 'flex';
      // The page behind a sheet does not scroll - the same idiom domains.md
      // uses, so a sheet behaves the same way wherever it is opened.
      document.body.classList.add('mg-sheet-open');
      document.getElementById('rows-title').textContent = table;

      if (!data.ok) {
        document.getElementById('rows-note').textContent = data.error || 'could not read the rows';
        tbl.querySelector('thead').innerHTML = '';
        tbl.querySelector('tbody').innerHTML = '';
        return;
      }

      var rows = data.rows || [];
      CURRENT.table = table;
      CURRENT.rows  = rows;
      PAGE.total    = data.total || rows.length;

      /* The rows reply does not carry the descriptor; fetch it once per table
         so the editor and the column list are both driven by the same
         declaration. */
      return fetch(API + '?action=data-table&table=' + encodeURIComponent(table))
        .then(function(r) { return r.json(); })
        .then(function(desc) {
          CURRENT.desc = desc.ok ? desc : null;
          renderRows(rows, CURRENT.desc);
        });
    })
    .catch(function(e) { showStatus('Could not load rows: ' + e, true); });
}

var CURRENT = { table: null, rows: [], desc: null, editing: null };

function keyOf(row) {
  var k = CURRENT.desc ? CURRENT.desc.key : 'id';
  return row[k];
}

function renderRows(rows, desc) {
  var tbl = document.getElementById('rows-table');

  /* THE COLUMNS COME FROM THE DESCRIPTOR, not from the first row. A row that
     happens to have nothing in a column would otherwise hide that column from
     every row, which is the shape of bug that makes an operator think data
     has been lost. The key comes first because it identifies the row. */
  var cols = desc && desc.fields ? Object.keys(desc.fields).sort() : [];
  if (desc && desc.key && cols.indexOf(desc.key) < 0) cols.unshift(desc.key);
  else if (desc && desc.key) { cols.splice(cols.indexOf(desc.key), 1); cols.unshift(desc.key); }
  if (!cols.length && rows.length) cols = Object.keys(rows[0]).sort();

  var first = PAGE.page * PAGE.size + 1;
  document.getElementById('rows-note').textContent =
    PAGE.total <= rows.length
      ? (rows.length === 1 ? '1 row' : rows.length + ' rows')
      : 'rows ' + first + '\u2013' + (first + rows.length - 1) + ' of ' + PAGE.total;
  var pager = document.getElementById('rows-pager');
  pager.style.display = PAGE.total > PAGE.size ? '' : 'none';
  document.getElementById('rows-prev').disabled = PAGE.page === 0;
  document.getElementById('rows-next').disabled =
    (PAGE.page + 1) * PAGE.size >= PAGE.total;
  document.getElementById('row-add-btn').style.display = desc ? '' : 'none';

  var head = '<tr>';
  for (var c = 0; c < cols.length; c++) head += '<th>' + escHtml(cols[c]) + '</th>';
  head += '<th></th></tr>';
  tbl.querySelector('thead').innerHTML = head;

  var body = '';
  for (var i = 0; i < rows.length; i++) {
    body += '<tr>';
    for (var c2 = 0; c2 < cols.length; c2++) {
      body += '<td>' + cell(rows[i][cols[c2]]) + '</td>';
    }
    /* Indexed by POSITION, not by key in the markup: a key can contain any
       character, and putting it into an onclick attribute is exactly the
       place an apostrophe breaks a page. */
    body += '<td style="white-space:nowrap;">'
      + '<button class="mg-btn mg-btn-sm" onclick="openEditor(' + i + ')">Edit</button> '
      + '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="deleteRow(' + i + ')">Delete</button>'
      + '</td></tr>';
  }
  if (!rows.length) {
    body = '<tr><td colspan="' + (cols.length + 1) + '" style="color:var(--mg-text-muted);">'
         + 'This table holds no rows yet.</td></tr>';
  }
  tbl.querySelector('tbody').innerHTML = body;
}

/* ONE INPUT PER DECLARED FIELD, its kind chosen by the TYPE. */
function inputFor(name, spec, value) {
  var id   = 'f-' + name;
  var type = spec.type || 'text';
  var v    = (value === null || value === undefined) ? '' : String(value);
  var req  = spec.required ? ' <span style="color:var(--mg-danger);" title="required">*</span>' : '';
  var label = '<label for="' + id + '" style="display:block;font-size:0.85em;color:var(--mg-text-muted);margin:8px 0 2px;">'
            + escHtml(name) + req + ' <span style="color:var(--mg-text-light);">' + escHtml(type) + '</span></label>';

  if (type === 'enum') {
    var opts = '<option value="">—</option>';
    (spec.values || []).forEach(function(o) {
      opts += '<option value="' + escHtml(o) + '"' + (String(o) === v ? ' selected' : '') + '>' + escHtml(o) + '</option>';
    });
    return label + '<select class="mg-inp" id="' + id + '" data-field="' + escHtml(name) + '">' + opts + '</select>';
  }
  if (type === 'boolean') {
    var on = (value === true || value === 1 || v === '1' || v === 'true');
    return '<label style="display:block;margin:8px 0 2px;"><input type="checkbox" id="' + id + '" data-field="' + escHtml(name) + '" data-bool="1"' + (on ? ' checked' : '') + '> '
         + escHtml(name) + req + ' <span style="color:var(--mg-text-light);font-size:0.85em;">boolean</span></label>';
  }
  if (type === 'text' && spec.widget === 'textarea') {
    return label + '<textarea class="mg-inp" id="' + id + '" data-field="' + escHtml(name) + '" rows="4" style="width:100%;">' + escHtml(v) + '</textarea>';
  }
  var html = { integer: 'number', date: 'date', datetime: 'datetime-local' }[type] || 'text';
  /* decimal stays TEXT on purpose: a number input would hand the browser a
     float, and "10.50" becoming 10.5 on the way to the server is the exact
     bug the decimal type exists to prevent. */
  return label + '<input class="mg-inp" type="' + html + '" id="' + id + '" data-field="' + escHtml(name) + '" value="' + escHtml(v) + '" style="width:100%;">';
}

/* SM502 U-2: EDITORS ARE MODAL. The same overlay shape the submissions
   viewer uses. The panel's own markup is MOVED into the overlay and moved
   back on close, so every id and handler below stays exactly as it was.
   Click-outside and Escape are Cancel: they discard, like the button. */
var MODAL = {};
function showModal(panelId, cancelFn) {
  var panel = document.getElementById(panelId);
  if (!panel || MODAL[panelId]) return;
  var mark = document.createElement('span');
  mark.style.display = 'none';
  panel.parentNode.insertBefore(mark, panel);
  var ov = document.createElement('div');
  ov.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,0.5);z-index:1000;display:flex;align-items:center;justify-content:center;padding:16px;';
  // SM585: the CARD is the frame. .mg-card already carries the manager's
  // surface, border, radius and shadow, and .mg-card-header/.mg-card-body
  // carry the padding - so the box only sizes and scrolls. Painting a second
  // background and radius here stacked two surfaces and left the content
  // hard against the edge, which is what the operator saw.
  var box = document.createElement('div');
  box.style.cssText = 'width:92%;max-width:48rem;max-height:90vh;overflow:auto;';
  panel.style.display = 'block';
  panel.style.margin = '0';
  panel.style.maxWidth = 'none';
  box.appendChild(panel);
  ov.appendChild(box);
  ov.addEventListener('click', function(e) { if (e.target === ov) cancelFn(); });
  var onKey = function(e) { if (e.key === 'Escape') cancelFn(); };
  document.addEventListener('keydown', onKey);
  document.body.appendChild(ov);
  MODAL[panelId] = { ov: ov, mark: mark, onKey: onKey };
}
function hideModal(panelId) {
  var m = MODAL[panelId];
  var panel = document.getElementById(panelId);
  if (!m || !panel) return;
  panel.style.display = 'none';
  m.mark.parentNode.insertBefore(panel, m.mark);
  m.mark.parentNode.removeChild(m.mark);
  document.removeEventListener('keydown', m.onKey);
  if (m.ov.parentNode) m.ov.parentNode.removeChild(m.ov);
  delete MODAL[panelId];
}

function openEditor(index) {
  var desc = CURRENT.desc;
  if (!desc) return;
  var row = (index === null) ? null : CURRENT.rows[index];
  CURRENT.editing = row ? keyOf(row) : null;

  document.getElementById('editor-title').textContent =
    row ? 'Edit row ' + String(keyOf(row)) : 'New row in ' + CURRENT.table;

  var names = Object.keys(desc.fields).sort();
  var html = '';
  /* A NATURAL KEY IS EDITABLE ON INSERT AND FIXED ON UPDATE. It is the row's
     identity: changing it on an existing row is a delete-and-insert wearing
     the name of an edit, and the API treats the key as the address, not a
     value. An automatic id is never shown - the plugin owns it. */
  if (desc.key && !desc.auto_key && names.indexOf(desc.key) >= 0) {
    names.splice(names.indexOf(desc.key), 1);
    names.unshift(desc.key);
  }
  names.forEach(function(n) {
    var spec = desc.fields[n];
    var field = inputFor(n, spec, row ? row[n] : (spec['default'] !== undefined ? spec['default'] : null));
    if (row && n === desc.key) {
      field = field.replace('<input ', '<input readonly style="width:100%;background:var(--mg-surface-alt);" ');
    }
    html += field;
  });
  document.getElementById('editor-fields').innerHTML = html;
  setError('');
  showModal('row-editor', closeEditor);
  var first = document.querySelector('#editor-fields .mg-inp');
  if (first) first.focus();
}

function closeEditor() {
  hideModal('row-editor');
  CURRENT.editing = null;
}

function setError(msg, field) {
  var el = document.getElementById('editor-error');
  el.textContent = msg || '';
  el.className = msg ? 'mg-status mg-status-error' : 'mg-status';
  /* Clear any previous highlight, then point at the field the SERVER named.
     The page did not decide it was wrong, so it does not decide which one. */
  document.querySelectorAll('#editor-fields .mg-inp, #editor-fields input').forEach(function(i) {
    i.style.outline = '';
  });
  if (field) {
    var bad = document.getElementById('f-' + field);
    if (bad) { bad.style.outline = '2px solid #c33'; bad.focus(); }
  }
}

function collectRow() {
  /* EMPTY MEANS NOT SET, not empty string. The store keeps NULL and '' apart,
     and a form cannot express the difference - so a blank input is left out
     of the row entirely and the server applies the declared default, or
     refuses if the field is required. Sending '' for every untouched field
     would write empty strings over every default on every save. */
  var row = {};
  document.querySelectorAll('#editor-fields [data-field]').forEach(function(i) {
    var name = i.getAttribute('data-field');
    if (i.getAttribute('data-bool')) { row[name] = i.checked; return; }
    if (i.hasAttribute('readonly')) return;        /* the key on an update */
    if (i.value === '') return;
    row[name] = i.value;
  });
  return row;
}

function saveRow() {
  var table = CURRENT.table;
  var key   = CURRENT.editing;
  var qs    = '?action=data-row-save&table=' + encodeURIComponent(table)
            + (key !== null && key !== undefined ? '&key=' + encodeURIComponent(key) : '');
  setError('');
  fetch(API + qs, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ row: collectRow() })
  })
  .then(function(r) { return r.json(); })
  .then(function(d) {
    if (!d.ok) {
      /* The server names the field. Say exactly what it said - its message
         already explains the rule ("not a whole number", "above the declared
         maximum", "not one of its enum values"). Rewriting it here would be a
         second explanation that drifts from the first. */
      setError(d.error || 'The row was refused.', d.field);
      return;
    }
    closeEditor();
    showStatus(key !== null && key !== undefined ? 'Row updated.' : 'Row added.');
    loadRows(table);
  })
  .catch(function(e) { setError('Could not save: ' + e); });
}

/* --- DM-5: the descriptor and the migration plan ------------------------ */
var DESC = { table: null, lost: [] };

/* SM502 U-5: the one manager page about tables can declare one. The name is
   asked for up front (it keys the descriptor); the descriptor opens with a
   commented starter shape and saves through the same data-table-save the
   editor uses, so validation and the migrate plan behave exactly as for an
   existing table. */
function declareTable() {
  var name = prompt('Name of the new table (letters, digits, underscore):');
  if (name === null) return;
  name = name.replace(/^\s+|\s+$/g, '');
  if (!/^[a-z][a-z0-9_]*$/.test(name)) {
    showStatus('A table name is lowercase letters, digits and underscores, starting with a letter.', true);
    return;
  }
  DESC.table = name;
  DESC.lost  = [];
  document.getElementById('descriptor-title').textContent = 'Declare ' + name;
  document.getElementById('descriptor-error').textContent = '';
  document.getElementById('plan-panel').style.display = 'none';
  showModal('descriptor-panel', closeDescriptor);
  var starter = { title: name.charAt(0).toUpperCase() + name.slice(1), key: 'id',
                  fields: { id: { type: 'text' }, name: { type: 'text' } } };
  buildDescForm(starter);
  document.getElementById('descriptor-text').value = emitYaml(readDescForm());
  descTab('form');
  showStatus('Declare the fields, then Save. Migrating afterwards creates the table.');
}

/* --- SM502 U-4: the descriptor form ------------------------------------ */
var DESC_TAB = 'form';
var TYPES = ['text', 'integer', 'decimal', 'boolean', 'date', 'datetime', 'enum'];

function descTab(which) {
  if (which === 'yaml' && DESC_TAB === 'form') {
    /* Leaving the form: the text shows what the form would save. */
    document.getElementById('descriptor-text').value = emitYaml(readDescForm());
  }
  DESC_TAB = which;
  document.getElementById('descriptor-form').style.display = which === 'form' ? '' : 'none';
  document.getElementById('descriptor-text').style.display = which === 'yaml' ? '' : 'none';
  document.getElementById('descriptor-yaml-note').style.display = which === 'yaml' ? '' : 'none';
  document.getElementById('desc-tab-form').disabled = which === 'form';
  document.getElementById('desc-tab-yaml').disabled = which === 'yaml';
}

/* Type-specific options, one text input each, in the order the server
   names them. The server still validates: a bad value comes back naming
   the field and the rule, exactly as it does for typed YAML. */
function optionHint(type) {
  return { enum: 'values, comma-separated', decimal: 'digits,places (e.g. 8,2)',
           integer: 'min,max (either may be blank)', text: 'max length; add ",textarea" for a textarea' }[type] || '';
}
function optionsOf(spec) {
  if (!spec) return '';
  if (spec.type === 'enum')    return (spec.values || []).join(', ');
  if (spec.type === 'decimal') return (spec.digits !== undefined ? spec.digits : '') + ',' + (spec.places !== undefined ? spec.places : '');
  if (spec.type === 'integer') return (spec.min !== undefined ? spec.min : '') + ',' + (spec.max !== undefined ? spec.max : '');
  if (spec.type === 'text')    return (spec.max !== undefined ? spec.max : '') + (spec.widget === 'textarea' ? ',textarea' : '');
  return '';
}

function fieldRow(name, spec) {
  spec = spec || { type: 'text' };
  var h = '<tr class="desc-field">'
    + '<td><input class="mg-inp desc-name" value="' + escHtml(name || '') + '" placeholder="name" style="width:9em;"></td>'
    + '<td><select class="mg-inp desc-type" onchange="this.parentNode.parentNode.querySelector(\'.desc-opts\').placeholder = optionHint(this.value)">';
  TYPES.forEach(function(t) { h += '<option' + (spec.type === t ? ' selected' : '') + '>' + t + '</option>'; });
  h += '</select></td>'
    + '<td style="text-align:center;"><input type="checkbox" class="desc-req"' + (spec.required ? ' checked' : '') + '></td>'
    + '<td style="text-align:center;"><input type="checkbox" class="desc-uniq"' + (spec.unique ? ' checked' : '') + '></td>'
    + '<td><input class="mg-inp desc-default" value="' + escHtml(spec['default'] !== undefined && spec['default'] !== null ? String(spec['default']) : '') + '" style="width:7em;"></td>'
    + '<td><input class="mg-inp desc-opts" value="' + escHtml(optionsOf(spec)) + '" placeholder="' + escHtml(optionHint(spec.type)) + '" style="width:13em;"></td>'
    + '<td><button class="mg-btn mg-btn-sm" onclick="this.closest(\'tr\').remove()">Remove</button></td>'
    + '</tr>';
  return h;
}

function buildDescForm(shape) {
  var names = Object.keys(shape.fields || {}).sort();
  var h = '<div style="display:grid;grid-template-columns:auto 1fr;gap:6px 10px;align-items:center;max-width:32rem;margin:0 0 10px;">'
    + '<label>Title</label><input class="mg-inp" id="desc-title" value="' + escHtml(shape.title || '') + '">'
    + '<label>Key</label><select class="mg-inp" id="desc-key"><option value="">automatic id</option>';
  names.forEach(function(n) { h += '<option' + (!shape.auto_key && shape.key === n ? ' selected' : '') + '>' + escHtml(n) + '</option>'; });
  h += '</select>'
    + '<label>Published</label><input type="checkbox" id="desc-public"' + (shape['public'] ? ' checked' : '') + '>'
    + '<label>Timestamps</label><input type="checkbox" id="desc-ts"' + (shape.timestamps ? ' checked' : '') + '>'
    + '<label>Indexes</label><input class="mg-inp" id="desc-indexes" placeholder="one per line: area, street" value="' + escHtml((shape.indexes || []).map(function(ix) { return ix.join(', '); }).join('\n')) + '">'
    + '</div>'
    + '<table class="mg-table" id="desc-fields"><thead><tr><th>Field</th><th>Type</th><th>Required</th><th>Unique</th><th>Default</th><th>Options</th><th></th></tr></thead><tbody>';
  names.forEach(function(n) { h += fieldRow(n, shape.fields[n]); });
  h += '</tbody></table>'
    + '<button class="mg-btn mg-btn-sm" style="margin-top:6px;" onclick="addDescField()">Add a field</button>'
    + '<p style="font-size:0.85em;color:var(--mg-text-muted);margin:8px 0 0;">The key field, if not automatic, is required and unique by implication. Saving from here regenerates the YAML; comments in it are dropped.</p>';
  document.getElementById('descriptor-form').innerHTML = h;
}

function addDescField() {
  var tb = document.querySelector('#desc-fields tbody');
  tb.insertAdjacentHTML('beforeend', fieldRow('', { type: 'text' }));
  var last = tb.lastElementChild.querySelector('.desc-name');
  if (last) last.focus();
}

function readDescForm() {
  var shape = { title: document.getElementById('desc-title').value, fields: {} };
  var key = document.getElementById('desc-key').value;
  if (key) shape.key = key;
  shape['public'] = document.getElementById('desc-public').checked;
  shape.timestamps = document.getElementById('desc-ts').checked;
  var ix = document.getElementById('desc-indexes').value.split(/\n/).map(function(l) {
    return l.split(',').map(function(x) { return x.replace(/^\s+|\s+$/g, ''); }).filter(function(x) { return x; });
  }).filter(function(l) { return l.length; });
  if (ix.length) shape.indexes = ix;
  var order = [];
  document.querySelectorAll('#desc-fields tr.desc-field').forEach(function(tr) {
    var name = tr.querySelector('.desc-name').value.replace(/^\s+|\s+$/g, '');
    if (!name) return;
    var spec = { type: tr.querySelector('.desc-type').value };
    if (tr.querySelector('.desc-req').checked)  spec.required = true;
    if (tr.querySelector('.desc-uniq').checked) spec.unique = true;
    var def = tr.querySelector('.desc-default').value;
    if (def !== '') spec['default'] = def;
    var o = tr.querySelector('.desc-opts').value.replace(/^\s+|\s+$/g, '');
    if (spec.type === 'enum' && o) spec.values = o.split(',').map(function(x) { return x.replace(/^\s+|\s+$/g, ''); }).filter(function(x) { return x; });
    if (spec.type === 'decimal' && o) { var dp = o.split(','); spec.digits = dp[0].replace(/\s/g, ''); spec.places = (dp[1] || '').replace(/\s/g, ''); }
    if (spec.type === 'integer' && o) { var mm = o.split(','); if (mm[0].replace(/\s/g, '') !== '') spec.min = mm[0].replace(/\s/g, ''); if (mm[1] && mm[1].replace(/\s/g, '') !== '') spec.max = mm[1].replace(/\s/g, ''); }
    if (spec.type === 'text' && o) { var tx = o.split(','); if (tx[0].replace(/\s/g, '') !== '') spec.max = tx[0].replace(/\s/g, ''); if (/textarea/.test(o)) spec.widget = 'textarea'; }
    shape.fields[name] = spec;
    order.push(name);
  });
  shape._order = order;
  return shape;
}

/* A small emitter for a flat, known shape. Scalars that could be read as
   YAML syntax are double-quoted; numbers and booleans are written bare. */
function yscalar(v) {
  if (v === true) return 'true';
  if (v === false) return 'false';
  var s = String(v);
  if (/^-?\d+(\.\d+)?$/.test(s)) return s;
  if (/^(true|false|yes|no|null|~)$/i.test(s) || /[:#\[\]{},&*!|>'"%@`]/.test(s) || /^\s|\s$/.test(s) || s === '') return '"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
  return s;
}
function emitYaml(shape) {
  var y = '';
  if (shape.title) y += 'title: ' + yscalar(shape.title) + '\n';
  if (shape.key) y += 'key: ' + shape.key + '\n';
  if (shape['public']) y += 'public: true\n';
  if (shape.timestamps) y += 'timestamps: true\n';
  if (shape.indexes && shape.indexes.length) {
    y += 'indexes:\n';
    shape.indexes.forEach(function(ix) { y += '  - [' + ix.join(', ') + ']\n'; });
  }
  y += 'fields:\n';
  (shape._order || Object.keys(shape.fields)).forEach(function(n) {
    var f = shape.fields[n];
    y += '  ' + n + ':\n    type: ' + f.type + '\n';
    if (f.required) y += '    required: true\n';
    if (f.unique)   y += '    unique: true\n';
    ['digits', 'places', 'min', 'max'].forEach(function(k) { if (f[k] !== undefined && f[k] !== '') y += '    ' + k + ': ' + yscalar(f[k]) + '\n'; });
    if (f.widget) y += '    widget: ' + f.widget + '\n';
    if (f.values) y += '    values: [' + f.values.map(yscalar).join(', ') + ']\n';
    if (f['default'] !== undefined) y += '    default: ' + yscalar(f['default']) + '\n';
  });
  return y;
}

// SM678: a data table's read access IS an ACL, and the manager could not show
// it.
//
// Lazysite::Data::Access keys it as `lazysite/db/tables/<table>`, so acl-get and
// acl-set reach a table's access with the same verbs that reach a page's, and
// may_read consults it through the shared _acl_allows. The mechanism was
// complete and the API could drive it - but the manager's only rights editor is
// rendered inside a FILE's expander on the Files page, and a table is not a
// file, so it never got one.
//
// That matters more than a missing panel: a table is where a site's personal
// data lives, and the one object whose access an operator would most want to
// audit was the one the manager could not show. Silence reads as "there is
// nothing here", and there is something here - the site agent reported
// operators assuming a content scope confines a table, which it does not.
var CAN_ACL = false;

function tableAclKey(table) { return 'lazysite/db/tables/' + table; }

// SM680: closing the rows modal. The editor inside it can hold an unsaved row,
// so a backdrop click must ask first - the same care the plugin modal takes,
// and using mgDirtyGuard.isDirty, which is the real method name (a previous
// page guessed isSet and the guard silently never fired).
function closeRows() {
  if (window.mgDirtyGuard && mgDirtyGuard.isDirty('data-row')
      && !window.confirm('This row has unsaved changes. Close and lose them?')) {
    return;
  }
  var p = document.getElementById('rows-panel');
  if (p) p.style.display = 'none';
  document.body.classList.remove('mg-sheet-open');
}

// SM687/SM678: WHO CAN READ THIS TABLE, in an expander built from the same
// parts as the Files page - the same chevron, the same `mg-expand`, the
// same `mgRights` chips and the same principal picker. A table's access is an
// ACL like a file's, so the operator who has learned one control has learned
// both; a second control that merely resembled the first would be a second
// thing to learn and a second thing to keep in step.
function toggleTableAcl(el, table) {
  var row  = el.closest('.mg-row');
  var card = row && row.nextElementSibling;
  if (!card || card.className.indexOf('mg-expand') < 0) return;

  var willOpen = card.style.display === 'none';

  // One at a time, as on the Files page: two open cards invite an edit in the
  // one that is not being looked at.
  var all = document.querySelectorAll('.mg-expand');
  for (var i = 0; i < all.length; i++) all[i].style.display = 'none';
  var chevs = document.querySelectorAll('.mg-chev');
  for (var j = 0; j < chevs.length; j++) {
    chevs[j].innerHTML = '&#9662;';
    chevs[j].classList.remove('mg-chev-open');
  }
  if (!willOpen) return;

  card.style.display = '';
  el.innerHTML = '&#9652;';
  el.classList.add('mg-chev-open');

  // The exports are in the card markup already and belong to anyone who can
  // see this page. The ACL is fetched only for a reader whose grant can
  // actually read it: acl-get is gated on manage_content, and asking anyway
  // would put a refusal in front of a manage_data holder who was reaching for
  // an export - a correct refusal to a question they did not ask.
  if (CAN_ACL) loadTableAcl(table, card);
}

// Read on OPEN rather than with the listing. A site with thirty tables would
// otherwise pay thirty ACL reads to render a list, and SM679 made the same
// argument the other way for the row count: what every row needs travels with
// the listing, what one row needs is fetched when that row is opened.
function loadTableAcl(table, card) {
  var body = card.querySelector('.mg-acl-body');
  if (!body) return;
  body.innerHTML = 'Loading&hellip;';
  fetch(API + '?action=data-table-acl-get&table=' + encodeURIComponent(table))
    .then(function(r) { return window.mgJson ? window.mgJson(r) : r.json(); })
    .then(function(d) {
      if (!d.ok) { body.innerHTML = '<div class="mg-perms-hint">' + escHtml(d.error || 'Could not read the rule') + '</div>'; return; }
      renderTableAcl(table, card, d.acl || {}, d.path || '');
    })
    .catch(function(e) { body.innerHTML = '<div class="mg-perms-hint">Error: ' + escHtml(e.message) + '</div>'; });
}

function renderTableAcl(table, card, acl, key) {
  var named = (acl.read || []).length || (acl.write || []).length;

  // THREE STATES, not two. SM635 argued it for a protected file row and the
  // middle one is the one that misleads: a rule that exists and names nobody
  // looks like protection and is not, because an empty list reads as open.
  var hint;
  if (!acl.owner && !named) {
    hint = 'No rule. Who may read this table follows the site\'s own rules - a '
         + 'table that names no domain is reachable by any manage_data holder '
         + 'on this instance.';
  } else if (!named) {
    hint = 'This rule has an owner and nobody named. An empty list is not a '
         + 'closed door: it reads as open within the account scope.';
  } else {
    hint = 'Toggle r / w per person. Nobody named = open within the account '
         + 'scope; no owner and nobody named clears the rule.';
  }

  card.querySelector('.mg-acl-body').innerHTML =
      '<div class="mg-perms-owner"><label>Owner</label>'
    +   '<select class="mg-perm-owner">' + tableOwnerOptions(acl.owner) + '</select></div>'
    + '<div class="mg-perms-rights-label">People &amp; groups with access</div>'
    + '<div class="mg-rights">' + mgRights.build(acl) + '</div>'
    + '<div class="mg-rights-add">'
    +   (window.mgPrincipalSelect
        ? mgPrincipalSelect({ onchange: 'addTableAclPrincipal(this)',
                              groupPrefix: '@', cls: 'mg-rights-pick' })
        : '')
    + '</div>'
    + '<div class="mg-perms-hint">' + escHtml(hint) + '</div>'
    + '<div class="mg-perms-hint mg-muted">Rule key: <code>' + escHtml(key) + '</code></div>'
    + '<div class="mg-perms-actions">'
    +   '<button class="mg-btn mg-btn-primary" onclick="saveTableAcl(this,\'' + escHtml(table) + '\')">Save</button> '
    +   '<a class="mg-perms-history" href="/manager/audit?target=' + encodeURIComponent(key) + '" title="This rule\'s audit history">&#128340; Audit</a>'
    + '</div>';
}

function tableOwnerOptions(current) {
  var opts = '<option value="">(nobody)</option>';
  if (window.mgPrincipalOptions) opts += mgPrincipalOptions({ selected: current });
  else if (current) opts += '<option selected>' + escHtml(current) + '</option>';
  return opts;
}

function addTableAclPrincipal(sel) {
  var name = sel.value;
  sel.selectedIndex = 0;
  if (!name) return;
  var card = sel.closest('.mg-expand-body');
  var list = card && card.querySelector('.mg-rights');
  if (!list) return;
  // SM462: a new principal gets BOTH rights. read-on/write-off stores an empty
  // write list, and an empty list means no restriction - so the table would end
  // up writable by more people than can read it.
  if (!list.querySelector('.mg-chip[data-name="' + name.replace(/"/g, '\\"') + '"]')) {
    list.insertAdjacentHTML('beforeend', mgRights.chip(name, 1, 1));
  }
}

function saveTableAcl(btn, table) {
  var card  = btn.closest('.mg-expand-body');
  var owner = (card.querySelector('.mg-perm-owner') || {}).value || '';
  var got   = mgRights.collect(card.querySelector('.mg-rights'));

  // SM306's shape: no owner and nobody named CLEARS the rule rather than
  // storing an empty one, which would read as "open" on one surface and as
  // "named" on another.
  var clearing = !owner && !got.read.length && !got.write.length;
  var action   = clearing ? 'data-table-acl-remove' : 'data-table-acl-set';

  fetch(API + '?action=' + action + '&table=' + encodeURIComponent(table), {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(clearing ? {} : { owner: owner, read: got.read, write: got.write })
  })
    .then(function(r) { return window.mgJson ? window.mgJson(r) : r.json(); })
    .then(function(d) {
      if (!d.ok) { showStatus(d.error || 'Could not save the rule', true); return; }
      showStatus(clearing
        ? 'Rule cleared for "' + table + '".'
        : 'Who can read "' + table + '" updated.');
      loadTableAcl(table, card.closest('.mg-expand-body'));
    })
    .catch(function(e) { showStatus('Error: ' + e.message, true); });
}



function openDescriptor(table) {
  DESC.table = table;
  DESC.lost  = [];
  document.getElementById('descriptor-title').textContent = 'Fields of ' + table;
  document.getElementById('descriptor-error').textContent = '';
  document.getElementById('plan-panel').style.display = 'none';
  showModal('descriptor-panel', closeDescriptor);
  fetch(API + '?action=data-table-source&table=' + encodeURIComponent(table))
    .then(function(r) { return r.json(); })
    .then(function(d) {
      if (!d.ok) { setDescError(d.error || 'could not read the descriptor'); return; }
      document.getElementById('descriptor-text').value = d.descriptor;
      /* U-4: the parsed shape drives the form; the text stays as stored. */
      return fetch(API + '?action=data-table&table=' + encodeURIComponent(table))
        .then(function(r) { return r.json(); })
        .then(function(shape) {
          if (!shape.ok) { descTab('yaml'); setDescError(shape.error || 'the descriptor does not load - edit the YAML'); return; }
          buildDescForm(shape);
          descTab('form');
        });
    })
    .catch(function(e) { setDescError('Could not load: ' + e); });
}

function closeDescriptor() {
  hideModal('descriptor-panel');
  DESC.table = null;
}

function setDescError(msg) {
  var el = document.getElementById('descriptor-error');
  el.textContent = msg || '';
  el.className = msg ? 'mg-status mg-status-error' : 'mg-status';
}

function saveDescriptor() {
  setDescError('');
  /* U-4: saving from the form sends what the form says; from the YAML tab,
     the text exactly as typed. */
  if (DESC_TAB === 'form') {
    document.getElementById('descriptor-text').value = emitYaml(readDescForm());
  }
  fetch(API + '?action=data-table-save&table=' + encodeURIComponent(DESC.table), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ descriptor: document.getElementById('descriptor-text').value })
  })
  .then(function(r) { return r.json(); })
  .then(function(d) {
    if (!d.ok) {
      /* THE SERVER'S SENTENCE, and the field it named. It already says the
         rule - "key 'slug' must be type text", "enum needs a values list". */
      setDescError(d.error + (d.field ? ' (field: ' + d.field + ')' : ''));
      return;
    }
    showStatus('Descriptor saved.' + (d.migrate_required ? ' The stored table does not match it yet - see what migrating would do.' : ''));
    loadTables();
    if (d.migrate_required) planMigration();
  })
  .catch(function(e) { setDescError('Could not save: ' + e); });
}

function planMigration() {
  var panel = document.getElementById('plan-panel');
  var body  = document.getElementById('plan-body');
  panel.style.display = 'block';
  body.textContent = 'Comparing the descriptor with the stored table\u2026';
  document.getElementById('plan-error').textContent = '';
  document.getElementById('plan-migrate-btn').style.display = 'none';
  document.getElementById('plan-rebuild-btn').style.display = 'none';
  DESC.lost = [];

  fetch(API + '?action=data-migrate-plan&table=' + encodeURIComponent(DESC.table))
    .then(function(r) { return r.json(); })
    .then(function(d) {
      if (!d.ok) { body.textContent = d.error || 'could not plan'; return; }
      /* SM502 U-6: the contract, stated where the deciding happens. */
      // SM692: the difference between Migrate and Rebuild is explained WHERE THE
      // CHOICE IS, not before it. This paragraph used to open the panel
      // unconditionally, so the commonest case read:
      //
      //   "Migrate applies only changes that keep every row... Rebuild makes
      //    the descriptor true whatever that costs..."
      //   "The stored table already matches the descriptor. Nothing to do."
      //
      // - a policy lecture followed by the news that neither applies. The only
      // time it was certain to be read was the one time it was irrelevant.
      // Held back and prepended below, once we know a button will be offered.
      var html = '';
      if (d.create) html += '<p>The stored table does not exist yet. <strong>Migrate</strong> creates it.</p>';
      if (d.additive && d.additive.length) {
        html += '<p>Migrate will apply, keeping every row:</p><ul>';
        d.additive.forEach(function(w) { html += '<li>' + escHtml(w) + '</li>'; });
        html += '</ul>';
      }
      if (d.blocked && d.blocked.length) {
        html += '<p><strong>Migrate will refuse</strong> these, because applying them in place could lose data:</p><ul>';
        d.blocked.forEach(function(b) { html += '<li>' + escHtml(b.why) + '</li>'; });
        html += '</ul>';
        if (d.rebuild) {
          /* SM487: the DATA checks. This is the list that used to arrive as a
             rollback after the operator had already confirmed. */
          if (d.rebuild.data_blocked && d.rebuild.data_blocked.length) {
            html += '<p><strong>A rebuild would fail on the existing rows.</strong> Fix these first:</p><ul>';
            d.rebuild.data_blocked.forEach(function(b) { html += '<li>' + escHtml(b.why) + '</li>'; });
            html += '</ul>';
          } else {
            DESC.lost = d.rebuild.lost || [];
            html += '<p>A <strong>rebuild</strong> can make them happen'
              + (DESC.lost.length
                  ? ', and it will <strong>drop ' + DESC.lost.map(escHtml).join(', ') + '</strong> and every value in ' + (DESC.lost.length === 1 ? 'it' : 'them') + '. A safety export is written first.'
                  : ', losing no columns. A safety export is written first.')
              + '</p>';
            document.getElementById('plan-rebuild-btn').style.display = '';
          }
        }
      }
      if (!d.create && !(d.additive && d.additive.length) && !(d.blocked && d.blocked.length)) {
        html += '<p>The stored table already matches the descriptor. Nothing to do.</p>';
      } else if (d.create || (d.additive && d.additive.length)) {
        document.getElementById('plan-migrate-btn').style.display = '';
      }

      // The explainer earns its place only when one of the two is actually on
      // offer - which is exactly when an operator has to tell them apart.
      var offered = document.getElementById('plan-migrate-btn').style.display === ''
                 || document.getElementById('plan-rebuild-btn').style.display === '';
      if (offered) {
        html = '<p style="color:var(--mg-text-muted);font-size:0.95em;"><strong>Migrate</strong> applies only changes that keep every row \u2014 it refuses anything that could lose data. <strong>Rebuild</strong> makes the descriptor true whatever that costs: it names each column it would drop, and writes a safety export first.</p>' + html;
      }
      body.innerHTML = html;
    })
    .catch(function(e) { document.getElementById('plan-error').textContent = 'Could not plan: ' + e; });
}

function runMigrate() {
  fetch(API + '?action=data-migrate&table=' + encodeURIComponent(DESC.table), {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}'
  })
  .then(function(r) { return r.json(); })
  .then(function(d) {
    if (!d.ok) { document.getElementById('plan-error').textContent = d.error || 'migration refused'; return; }
    showStatus('Migrated.');
    loadTables();
    planMigration();
  });
}

function runRebuild() {
  /* CONFIRMED BY NAMING EACH COLUMN. The prompt lists them and the operator
     types them back; agreeing to lose one column you read about must not
     agree to a second you did not notice. An empty list is a rebuild that
     loses nothing, and needs no typing. */
  var confirm_lost = [];
  if (DESC.lost.length) {
    var typed = prompt('This rebuild drops: ' + DESC.lost.join(', ') + '\n\nType the column names, separated by spaces, to confirm losing them:');
    if (typed === null) return;
    confirm_lost = typed.split(/[\s,]+/).filter(function(x) { return x; });
  }
  fetch(API + '?action=data-rebuild&table=' + encodeURIComponent(DESC.table), {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ table: DESC.table, confirm_lost: confirm_lost })
  })
  .then(function(r) { return r.json(); })
  .then(function(d) {
    if (!d.ok) { document.getElementById('plan-error').textContent = d.error || 'rebuild refused'; return; }
    showStatus('Rebuilt. Safety export: ' + (d.safety_export || 'written'));
    loadTables();
    planMigration();
  });
}

/* --- DM-4: staged import --------------------------------------------- */
var IMPORT = { file: null };

function sendImport(apply) {
  var fd = new FormData();
  fd.append('file', IMPORT.file);
  return fetch(API + '?action=data-import&table=' + encodeURIComponent(CURRENT.table) + (apply ? '&apply=1' : ''), {
    method: 'POST',
    body: fd
  }).then(function(r) { return r.json(); });
}

function planImport() {
  var input = document.getElementById('import-file');
  if (!input.files || !input.files[0]) return;
  IMPORT.file = input.files[0];
  input.value = '';
  var panel = document.getElementById('import-panel');
  panel.style.display = 'block';
  document.getElementById('import-plan').textContent = 'Checking ' + IMPORT.file.name + '\u2026';
  document.getElementById('import-error').textContent = '';
  document.getElementById('import-apply-btn').style.display = 'none';

  sendImport(false).then(function(d) {
    if (!d.ok) {
      /* THE SERVER'S SENTENCE, UNCHANGED. It already names the row as the
         spreadsheet numbers it and the field that failed. */
      document.getElementById('import-plan').textContent = 'Nothing was imported.';
      var err = document.getElementById('import-error');
      err.className = 'mg-status mg-status-error';
      err.textContent = d.error || 'The file was refused.';
      return;
    }
    document.getElementById('import-plan').innerHTML =
      '<strong>' + escHtml(IMPORT.file.name) + '</strong>: ' + d.rows + ' row' + (d.rows === 1 ? '' : 's') + ' \u2014 '
      + '<strong>' + d.inserts + '</strong> new, <strong>' + d.updates + '</strong> updating existing rows by key. '
      + 'Nothing has been written yet.';
    document.getElementById('import-apply-btn').style.display = '';
  }).catch(function(e) {
    document.getElementById('import-error').textContent = 'Could not check the file: ' + e;
  });
}

function applyImport() {
  document.getElementById('import-apply-btn').style.display = 'none';
  sendImport(true).then(function(d) {
    if (!d.ok) {
      /* The store may have moved between plan and apply - a row that was an
         insert is now a clash, say. Every row is re-checked, and a refusal
         here means nothing was written, exactly as at plan time. */
      var err = document.getElementById('import-error');
      err.className = 'mg-status mg-status-error';
      err.textContent = d.error || 'The import was refused.';
      return;
    }
    cancelImport();
    showStatus('Imported: ' + d.inserts + ' added, ' + d.updates + ' updated.');
    loadRows(CURRENT.table);
  }).catch(function(e) {
    document.getElementById('import-error').textContent = 'Could not apply: ' + e;
  });
}

function cancelImport() {
  IMPORT.file = null;
  document.getElementById('import-panel').style.display = 'none';
}

function deleteRow(index) {
  var row = CURRENT.rows[index];
  if (!row) return;
  var k = keyOf(row);
  /* Named in the prompt. A yes/no that does not say WHICH row is the one an
     operator clicks through on the wrong line. */
  if (!confirm('Delete row ' + String(k) + ' from ' + CURRENT.table + '? This cannot be undone from here.')) return;
  fetch(API + '?action=data-row-delete&table=' + encodeURIComponent(CURRENT.table) + '&key=' + encodeURIComponent(k), {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: '{}'
  })
  .then(function(r) { return r.json(); })
  .then(function(d) {
    if (!d.ok) { showStatus(d.error || 'Could not delete the row.', true); return; }
    showStatus('Row ' + String(k) + ' deleted.');
    loadRows(CURRENT.table);
  })
  .catch(function(e) { showStatus('Could not delete: ' + e, true); });
}

// SM678: the ACL verbs this panel calls (acl-get, acl-set, acl-remove) are
// gated on manage_content, and THIS PAGE is gated on manage_data. A person can
// hold one without the other, so the "Who can read" control was on offer to
// people every one of those calls would refuse. Ask first, and render the
// button only for someone who can finish what it starts.
function loadDataCaps() {
  return fetch(API + '?action=whoami')
    .then(function(r) { return window.mgJson ? window.mgJson(r) : r.json(); })
    .then(function(d) {
      if (d && d.ok) CAN_ACL = !!(d.capabilities || {}).manage_content;
    })
    .catch(function() { /* leave it off: no button beats a button that refuses */ });
}

// SM077: the assignable names, from the one source every page that names a
// principal already uses. Best-effort: a page that cannot list them still
// edits the rights already on the rule.
function loadDataPrincipals() {
  return fetch(API + '?action=principals')
    .then(function(r) { return window.mgJson ? window.mgJson(r) : r.json(); })
    .then(function(d) {
      if (d && d.ok && window.mgSetPrincipals) mgSetPrincipals(d.users, d.groups);
    })
    .catch(function() { /* the editor still works on what is already there */ });
}

loadDataCaps().then(loadDataPrincipals).then(loadTables);
</script>
