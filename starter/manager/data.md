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
  <div style="overflow-x:auto;">
    <table class="mg-table" id="rows-table"><thead></thead><tbody></tbody></table>
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
      /* THE COLUMNS COME FROM THE DESCRIPTOR, not from the first row. A row
         that happens to have nothing in a column would otherwise hide that
         column from every row, which is the shape of bug that makes an
         operator think data has been lost. */
      var cols = data.fields ? Object.keys(data.fields).sort() : [];
      if (!cols.length && rows.length) cols = Object.keys(rows[0]).sort();

      document.getElementById('rows-note').textContent =
        (rows.length === 1 ? '1 row' : rows.length + ' rows')
        + ' — read-only for now; editing arrives with DM-3.';

      var head = '<tr>';
      for (var c = 0; c < cols.length; c++) head += '<th>' + escHtml(cols[c]) + '</th>';
      head += '</tr>';
      tbl.querySelector('thead').innerHTML = head;

      var body = '';
      for (var i = 0; i < rows.length; i++) {
        body += '<tr>';
        for (var c2 = 0; c2 < cols.length; c2++) {
          body += '<td>' + cell(rows[i][cols[c2]]) + '</td>';
        }
        body += '</tr>';
      }
      if (!rows.length) {
        body = '<tr><td colspan="' + (cols.length || 1) + '" style="color:#888;">'
             + 'This table holds no rows yet.</td></tr>';
      }
      tbl.querySelector('tbody').innerHTML = body;
    })
    .catch(function(e) { showStatus('Could not load rows: ' + e, true); });
}

loadTables();
</script>
