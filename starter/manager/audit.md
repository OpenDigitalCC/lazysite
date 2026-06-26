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
<div class="mg-card-header"><span class="mg-card-title">Audit log</span></div>
<div class="mg-card-body">

<div class="mg-line">
  <label for="audit-user">User</label>
  <input type="text" id="audit-user" class="mg-inp" placeholder="(all)" style="max-width:10rem">
  <label for="audit-target-f">Target</label>
  <input type="text" id="audit-target-f" class="mg-inp" placeholder="(all)" style="max-width:14rem">
  <button class="mg-btn mg-btn-sm" onclick="filterAudit()">Filter</button>
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
  auditPage = 1;
  var t = document.getElementById('audit-target-f');
  if (t) auditTarget = t.value.trim();
  loadAudit();
}
function clearAuditFilter() {
  document.getElementById('audit-user').value = '';
  var t = document.getElementById('audit-target-f'); if (t) t.value = '';
  auditTarget = ''; auditPage = 1; loadAudit();
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
  var u = document.getElementById('audit-user').value.trim();
  var url = '/cgi-bin/lazysite-manager-api.pl?action=audit'
          + '&page=' + auditPage + '&per_page=50'
          + (u ? ('&user=' + encodeURIComponent(u)) : '')
          + (auditTarget ? ('&target=' + encodeURIComponent(auditTarget)) : '');
  fetch(url).then(function (r) { return r.json(); }).then(function (d) {
    var el = document.getElementById('audit-table');
    if (!d.ok) { el.textContent = d.error || 'Failed to load.'; return; }
    var note = document.getElementById('audit-scope');
    if (note) {
      note.innerHTML = auditTarget
        ? 'History for <code>' + aesc(auditTarget) + '</code> '
          + '<a href="#" onclick="auditTarget=\'\';auditPage=1;this.parentNode.innerHTML=\'\';loadAudit();return false;">(show all)</a>'
        : '';
    }
    if (!d.entries.length) { el.textContent = 'No audit entries yet.'; return; }
    var h = '<table class="audit-table"><thead><tr>' +
      '<th>When (UTC)</th><th>User</th><th>Source</th><th>Action</th><th>Target</th><th>From</th><th>Status</th>' +
      '</tr></thead><tbody>';
    d.entries.forEach(function (e) {
      var cls = e.status === 'fail' ? ' class="audit-fail"' : '';
      var statusCell = aesc(e.status);
      if (e.status === 'fail' && e.detail) {
        // The reason is a click-to-reveal popup on the (i), not always inline.
        statusCell = aesc(e.status) +
          ' <a href="#" class="audit-info" title="' + aesc(e.detail) +
          '" onclick="var d=this.nextElementSibling;d.style.display=(d.style.display===\'none\'?\'inline\':\'none\');return false;">&#9432;</a>' +
          '<span class="audit-detail" style="display:none"> ' + aesc(e.detail) + '</span>';
      }
      h += '<tr' + cls + '><td>' + aesc(e.ts) + '</td><td>' + auditUserLink(e.user) +
        '</td><td>' + aesc(e.origin || '') +
        '</td><td>' + aesc(e.action) + '</td><td>' + auditTargetLink(e) +
        '</td><td>' + aesc(e.ip) +
        '</td><td>' + statusCell + '</td></tr>';
    });
    h += '</tbody></table>';
    el.innerHTML = h + paginationHtml(d);
  }).catch(function (e) { document.getElementById('audit-table').textContent = 'Error: ' + e.message; });
}

(function () {
  var mu = location.search.match(/[?&]user=([^&]+)/);
  if (mu) { document.getElementById('audit-user').value = decodeURIComponent(mu[1]); }
  var mt = location.search.match(/[?&]target=([^&]+)/);
  if (mt) { auditTarget = decodeURIComponent(mt[1]); var tf = document.getElementById('audit-target-f'); if (tf) tf.value = auditTarget; }
  loadAudit();
})();
</script>
