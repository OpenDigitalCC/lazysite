---
title: Data tables
auth: manager
search: false
---

<div id="status" class="mg-status"></div>

<p style="font-size:0.85em;color:#888;margin:0 0 12px;">Tables this site declares and holds &mdash; a product list, an events calendar, a directory. A table is <strong>closed until it is published</strong>: until its descriptor says <code>public: true</code>, an anonymous visitor sees nothing, not even that it exists. What you see here is what the store holds, whoever may read it.</p>

<div style="display:flex;gap:8px;margin-bottom:12px;align-items:center;">
<button class="mg-btn" onclick="loadTables()">Refresh</button>
<span id="table-count" style="font-size:0.85em;color:#888;"></span>
</div>

<p style="font-size:0.85em;color:#888;margin:0 0 12px;"><strong>JSON</strong> is the exact copy &mdash; types survive, and it is the one that goes back in. <strong>CSV</strong> is for a spreadsheet: it has no types, cannot tell an unset value from an empty one, and cells that a spreadsheet would run as formulas are prefixed with an apostrophe to make them safe, which changes those values.</p>

<div class="mg-file-list" id="table-list">
<div class="mg-file-item"><span class="mg-file-name">Loading...</span></div>
</div>

<div id="rows-panel" style="display:none;margin-top:18px;">
  <h2 style="font-size:1.05em;margin:0 0 4px;" id="rows-title"></h2>
  <p style="font-size:0.85em;color:#888;margin:0 0 10px;" id="rows-note"></p>
  <div style="margin:0 0 10px;"><button class="mg-btn mg-btn-primary" id="row-add-btn" onclick="openEditor(null)">Add a row</button></div>
  <div style="overflow-x:auto;">
    <table class="mg-table" id="rows-table"><thead></thead><tbody></tbody></table>
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
  <div id="editor-fields"></div>
  <div id="editor-error" class="mg-status" style="margin-top:8px;"></div>
  <div style="display:flex;gap:8px;margin-top:12px;">
    <button class="mg-btn mg-btn-primary" onclick="saveRow()">Save</button>
    <button class="mg-btn" onclick="closeEditor()">Cancel</button>
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
    return '<span style="color:#bbb;font-style:italic;">not set</span>';
  }
  if (v === '') {
    return '<span style="color:#bbb;font-style:italic;">empty</span>';
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
        list.innerHTML = '<div class="mg-file-item"><span class="mg-file-name">'
          + escHtml(data.error || 'could not read the tables') + '</span></div>';
        document.getElementById('table-count').textContent = '';
        return;
      }
      var tables = data.tables || [];
      document.getElementById('table-count').textContent =
        tables.length === 1 ? '1 table' : tables.length + ' tables';

      if (!tables.length) {
        list.innerHTML = '<div class="mg-file-item"><span class="mg-file-name">'
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
        if (t.pending_schema) bits.push('needs migrating');
        var enc = encodeURIComponent(name);
        html += '<div class="mg-file-item">'
          + '<span class="mg-file-name"><code>' + escHtml(name) + '</code> '
          + '<span style="color:#888;font-size:0.85em;">' + bits.join(' &middot; ') + '</span></span>'
          + '<span><button class="mg-btn" onclick="loadRows(\'' + escHtml(name) + '\')">Rows</button> '
          /* Plain links, not fetch(): a download is a navigation, and letting
             the browser do it means the file lands where the operator expects
             instead of being assembled in memory. */
          + '<a class="mg-btn" href="' + API + '?action=data-export&amp;format=json&amp;table=' + enc + '">JSON</a> '
          + '<a class="mg-btn" href="' + API + '?action=data-export&amp;format=csv&amp;table=' + enc + '">CSV</a></span>'
          + '</div>';
      }
      list.innerHTML = html;
    })
    .catch(function(e) { showStatus('Could not load tables: ' + e, true); });
}

function loadRows(table) {
  showStatus('');
  fetch(API + '?action=data-rows&table=' + encodeURIComponent(table))
    .then(function(r) { return r.json(); })
    .then(function(data) {
      var panel = document.getElementById('rows-panel');
      var tbl   = document.getElementById('rows-table');
      panel.style.display = 'block';
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

  document.getElementById('rows-note').textContent =
    (rows.length === 1 ? '1 row' : rows.length + ' rows');
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
    body = '<tr><td colspan="' + (cols.length + 1) + '" style="color:#888;">'
         + 'This table holds no rows yet.</td></tr>';
  }
  tbl.querySelector('tbody').innerHTML = body;
}

/* ONE INPUT PER DECLARED FIELD, its kind chosen by the TYPE. */
function inputFor(name, spec, value) {
  var id   = 'f-' + name;
  var type = spec.type || 'text';
  var v    = (value === null || value === undefined) ? '' : String(value);
  var req  = spec.required ? ' <span style="color:#c33;" title="required">*</span>' : '';
  var label = '<label for="' + id + '" style="display:block;font-size:0.85em;color:#666;margin:8px 0 2px;">'
            + escHtml(name) + req + ' <span style="color:#aaa;">' + escHtml(type) + '</span></label>';

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
         + escHtml(name) + req + ' <span style="color:#aaa;font-size:0.85em;">boolean</span></label>';
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
      field = field.replace('<input ', '<input readonly style="width:100%;background:#f3f3f3;" ');
    }
    html += field;
  });
  document.getElementById('editor-fields').innerHTML = html;
  setError('');
  document.getElementById('row-editor').style.display = 'block';
  var first = document.querySelector('#editor-fields .mg-inp');
  if (first) first.focus();
}

function closeEditor() {
  document.getElementById('row-editor').style.display = 'none';
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

loadTables();
</script>
