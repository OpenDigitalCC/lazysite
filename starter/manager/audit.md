---
title: Audit log
auth: manager
search: false
query_params:
  - user
  - target
---

<div id="status" class="mg-status"></div>

<div class="mg-card">
<div class="mg-card-body">

<div class="mg-line">
  <label for="audit-user">User</label>
  <select id="audit-user" class="mg-inp" style="max-width:12rem" onchange="filterAudit()"><option value="">(all users)</option></select>
  <label for="audit-target-f">Target</label>
  <select id="audit-target-f" class="mg-inp" style="max-width:18rem" onchange="filterAudit()"><option value="">(all targets)</option></select>
</div>
<!-- Date range on its own line so From/To never split across a wrap. -->
<div class="mg-line">
  <label for="audit-from">From</label>
  <input type="date" id="audit-from" class="mg-inp" style="max-width:10rem" onchange="filterAudit()">
  <label for="audit-to">To</label>
  <input type="date" id="audit-to" class="mg-inp" style="max-width:10rem" onchange="filterAudit()">
  <button class="mg-btn mg-btn-sm" onclick="clearAuditFilter()">Clear</button>
  <button class="mg-btn mg-btn-sm" onclick="loadAudit()">Refresh</button>
</div>

<div id="audit-scope" style="margin-top:0.4rem;font-size:0.85rem;color:#666;"></div>

<div id="audit-table" style="margin-top:0.6rem;">Loading&hellip;</div>

</div>
</div>

<!-- audit-table styles consolidated into manager.css (SM109 phase 3) -->
<script>
function aesc(s) { var d = document.createElement('div'); d.textContent = (s == null ? '' : String(s)); return d.innerHTML; }

var auditTarget = '';   // SM077: when set, show one file's history
var auditPage = 1;      // pagination (50 rows/page)

function filterAudit() {
  auditPage = 1;   // the selects are read in loadAudit
  loadAudit();
}
function clearAuditFilter() {
  document.getElementById('audit-user').value = '';
  document.getElementById('audit-target-f').value = '';
  document.getElementById('audit-from').value = '';
  document.getElementById('audit-to').value = '';
  auditTarget = ''; auditPage = 1; loadAudit();
}

// SM119: fill a filter <select> from the distinct values in the log, keeping the
// current selection. Empty value -> a "(none)" option (the __none sentinel filters
// to blank-valued entries server-side).
function fillAuditSelect(id, values, label) {
  var sel = document.getElementById(id);
  if (!sel) return;
  var cur = sel.value;
  var hasBlank = false, real = [];
  (values || []).forEach(function (v) { if (v === '' || v == null) hasBlank = true; else real.push(v); });
  var opts = '<option value="">(all ' + label + 's)</option>';
  if (hasBlank) opts += '<option value="__none">(none)</option>';
  real.forEach(function (v) {
    var a = aesc(v).replace(/"/g, '&quot;');
    opts += '<option value="' + a + '">' + aesc(v) + '</option>';
  });
  // Keep a deep-linked / current value selectable even before its facet arrives.
  if (cur && cur !== '__none' && real.indexOf(cur) === -1) {
    opts += '<option value="' + aesc(cur).replace(/"/g, '&quot;') + '">' + aesc(cur) + '</option>';
  }
  sel.innerHTML = opts;
  sel.value = cur;
}
function populateAuditFilters(d) {
  fillAuditSelect('audit-user', d.users, 'user');
  fillAuditSelect('audit-target-f', d.targets, 'target');
}
// Deep-link: ensure a value exists as an option, then select it (before facets load).
function setAuditSelect(id, v) {
  var sel = document.getElementById(id);
  if (!sel || !v) return;
  var found = false;
  for (var i = 0; i < sel.options.length; i++) { if (sel.options[i].value === v) { found = true; break; } }
  if (!found) { var o = document.createElement('option'); o.value = v; o.textContent = v; sel.appendChild(o); }
  sel.value = v;
}
function goAuditPage(n) { auditPage = n; loadAudit(); }

// Click-through: a username -> the Users page with that user expanded; a page
// target -> the rendered public page; a file/config target stays plain text.
function auditUserLink(u) {
  if (!u) return '';
  return '<a href="/manager/users?user=' + encodeURIComponent(u) + '">' + aesc(u) + '</a>';
}
function auditTargetLink(e) {
  var t = e.target || '';
  if (!t) return '';
  if (/^user-/.test(e.action || '')) return auditUserLink(t);
  // A move logs "from -> to"; point the link at the destination.
  var fileT = t, arrow = t.indexOf(' -> ');
  if (arrow >= 0) fileT = t.slice(arrow + 4);
  // Any file (by slash or extension) opens in the manager editor - this covers
  // .md plus .conf, .brief and other editable files, not just public pages.
  if (/\//.test(fileT) || /\.[A-Za-z0-9]+$/.test(fileT)) {
    return '<a href="/manager/edit?path=' + encodeURIComponent(fileT) +
      '" title="Edit this file">' + aesc(t) + '</a>';
  }
  return aesc(t);
}

function paginationHtml(d) {
  var pages = d.pages || 1, page = d.page || 1, total = d.total || 0;
  var info = 'Page ' + page + ' of ' + pages + ' (' + total + ' event' + (total === 1 ? '' : 's') + ')';
  if (pages <= 1) return '<div class="audit-pagination"><span class="audit-page-info">' + total + ' event' + (total === 1 ? '' : 's') + '</span></div>';
  var prev = page > 1 ? '<button class="mg-btn mg-btn-sm" onclick="goAuditPage(' + (page - 1) + ')">&larr; Prev</button>' : '';
  var next = page < pages ? '<button class="mg-btn mg-btn-sm" onclick="goAuditPage(' + (page + 1) + ')">Next &rarr;</button>' : '';
  return '<div class="audit-pagination">' + prev + '<span class="audit-page-info">' + info + '</span>' + next + '</div>';
}

function loadAudit() {
  var u = document.getElementById('audit-user').value;
  var t = document.getElementById('audit-target-f').value;
  var from = document.getElementById('audit-from').value;
  var to   = document.getElementById('audit-to').value;
  auditTarget = t;   // kept for the scope note
  var url = '/cgi-bin/lazysite-manager-api.pl?action=audit'
          + '&page=' + auditPage + '&per_page=50'
          + (u ? ('&user=' + encodeURIComponent(u)) : '')
          + (t ? ('&target=' + encodeURIComponent(t)) : '')
          + (from ? ('&start=' + encodeURIComponent(from)) : '')
          + (to ? ('&end=' + encodeURIComponent(to)) : '');
  fetch(url).then(function (r) { return r.json(); }).then(function (d) {
    var el = document.getElementById('audit-table');
    if (!d.ok) { el.textContent = d.error || 'Failed to load.'; return; }
    populateAuditFilters(d);
    var note = document.getElementById('audit-scope');
    if (note) {
      note.innerHTML = auditTarget
        ? 'History for <code>' + aesc(auditTarget) + '</code> '
          + '<a href="#" onclick="document.getElementById(\'audit-target-f\').value=\'\';auditPage=1;loadAudit();return false;">(show all)</a>'
        : '';
    }
    if (!d.entries.length) { el.textContent = 'No audit entries yet.'; return; }
    var h = '<table class="audit-table"><thead><tr>' +
      '<th>When (UTC)</th><th>User</th><th>Source</th><th>Action</th><th>Target</th><th>From</th><th>Status</th>' +
      '</tr></thead><tbody>';
    d.entries.forEach(function (e, i) {
      var cls = e.status === 'fail' ? ' class="audit-fail"' : '';
      var statusCell = aesc(e.status);
      var detailRow = '';
      if (e.status === 'fail' && e.detail) {
        // Click the (i) to expand the reason on its own full-width row below,
        // rather than cramming it into the narrow Status cell.
        var did = 'audit-d-' + i;
        statusCell = aesc(e.status) +
          ' <a href="#" class="audit-info" title="Show reason" ' +
          'onclick="var r=document.getElementById(\'' + did +
          '\');r.hidden=!r.hidden;return false;">&#9432;</a>';
        detailRow = '<tr id="' + did + '" class="audit-detail-row" hidden>' +
          '<td colspan="7"><strong>Reason:</strong> ' + aesc(e.detail) + '</td></tr>';
      }
      h += '<tr' + cls + '><td>' + aesc(e.ts) + '</td><td>' + auditUserLink(e.user) +
        '</td><td>' + aesc(e.origin || '') +
        '</td><td>' + aesc(e.action) + '</td><td>' + auditTargetLink(e) +
        '</td><td>' + aesc(e.ip) +
        '</td><td>' + statusCell + '</td></tr>' + detailRow;
    });
    h += '</tbody></table>';
    el.innerHTML = h + paginationHtml(d);
  }).catch(function (e) { document.getElementById('audit-table').textContent = 'Error: ' + e.message; });
}

(function () {
  var mu = location.search.match(/[?&]user=([^&]+)/);
  if (mu) { setAuditSelect('audit-user', decodeURIComponent(mu[1])); }
  var mt = location.search.match(/[?&]target=([^&]+)/);
  if (mt) { auditTarget = decodeURIComponent(mt[1]); setAuditSelect('audit-target-f', auditTarget); }
  loadAudit();
})();
</script>
