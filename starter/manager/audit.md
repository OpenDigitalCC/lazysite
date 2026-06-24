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
  <label for="audit-user">Filter by user</label>
  <input type="text" id="audit-user" class="mg-inp" placeholder="(all users)">
  <button class="mg-btn mg-btn-sm" onclick="loadAudit()">Filter</button>
  <button class="mg-btn mg-btn-sm" onclick="document.getElementById('audit-user').value='';loadAudit()">Clear</button>
</div>

<div id="audit-scope" style="margin-top:0.4rem;font-size:0.85rem;color:#666;"></div>

<div id="audit-table" style="margin-top:0.6rem;">Loading&hellip;</div>

</div>
</div>

<style>
  .audit-table { width:100%; border-collapse:collapse; font-size:0.85rem; }
  .audit-table th, .audit-table td { text-align:left; padding:0.3rem 0.5rem; border-bottom:1px solid #eee; }
  .audit-table th { color:#666; font-weight:600; }
  .audit-fail { color:#c33; }
</style>

<script>
function aesc(s) { var d = document.createElement('div'); d.textContent = (s == null ? '' : String(s)); return d.innerHTML; }

var auditTarget = '';   // SM077: when set, show one file's history

function loadAudit() {
  var u = document.getElementById('audit-user').value.trim();
  var url = '/cgi-bin/lazysite-manager-api.pl?action=audit'
          + (u ? ('&user=' + encodeURIComponent(u)) : '')
          + (auditTarget ? ('&target=' + encodeURIComponent(auditTarget)) : '');
  fetch(url).then(function (r) { return r.json(); }).then(function (d) {
    var el = document.getElementById('audit-table');
    if (!d.ok) { el.textContent = d.error || 'Failed to load.'; return; }
    var note = document.getElementById('audit-scope');
    if (note) {
      note.innerHTML = auditTarget
        ? 'History for <code>' + aesc(auditTarget) + '</code> '
          + '<a href="#" onclick="auditTarget=\'\';this.parentNode.innerHTML=\'\';loadAudit();return false;">(show all)</a>'
        : '';
    }
    if (!d.entries.length) { el.textContent = 'No audit entries yet.'; return; }
    var h = '<table class="audit-table"><thead><tr>' +
      '<th>When (UTC)</th><th>User</th><th>Source</th><th>Action</th><th>Target</th><th>From</th><th>Status</th>' +
      '</tr></thead><tbody>';
    d.entries.forEach(function (e) {
      var cls = e.status === 'fail' ? ' class="audit-fail"' : '';
      h += '<tr' + cls + '><td>' + aesc(e.ts) + '</td><td>' + aesc(e.user) +
        '</td><td>' + aesc(e.origin || '') +
        '</td><td>' + aesc(e.action) + '</td><td>' + aesc(e.target || '') +
        '</td><td>' + aesc(e.ip) +
        '</td><td>' + aesc(e.status) + '</td></tr>';
    });
    h += '</tbody></table>';
    el.innerHTML = h;
  }).catch(function (e) { document.getElementById('audit-table').textContent = 'Error: ' + e.message; });
}

(function () {
  var mu = location.search.match(/[?&]user=([^&]+)/);
  if (mu) { document.getElementById('audit-user').value = decodeURIComponent(mu[1]); }
  var mt = location.search.match(/[?&]target=([^&]+)/);
  if (mt) { auditTarget = decodeURIComponent(mt[1]); }
  loadAudit();
})();
</script>
