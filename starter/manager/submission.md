---
title: Submission
auth: manager
search: false
---

<div id="status" class="mg-status"></div>

<!-- SM938 D5: ONE SUBMISSION, ADDRESSABLE. The operator's words: the bell
     "should show link to the thing that happened". A submission notice linked to
     a manager SECTION, and no page addressed a single submission, so following
     the link still left the operator to find the row. The file handler now
     reports which row it wrote, the notice links here with that store and id,
     and this page shows that row and nothing else. It reads through
     form-submission, under the same grant as the submissions table. -->
<div class="mg-card">
<div class="mg-card-header"><span class="mg-card-title" id="sub-title">Submission</span></div>
<div class="mg-card-body">
<div id="sub-body"><div class="mg-empty">Loading...</div></div>
<div class="mg-toolbar" id="sub-actions"></div>
</div>
</div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';

function node(tag, cls, text) {
  var e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;    // submitted values are untrusted: text only
  return e;
}

function show(message) {
  var body = document.getElementById('sub-body');
  body.textContent = '';
  body.appendChild(node('div', 'mg-empty', message));
}

function render(d) {
  var r = d.record || {};
  document.getElementById('sub-title').textContent = 'Submission: ' + (r._form || d.file);
  var body = document.getElementById('sub-body');
  body.textContent = '';
  var list = node('div', 'mg-list');
  (d.fields || []).forEach(function(k) {
    var row = node('div', 'mg-row');
    row.appendChild(node('span', 'mg-row-name', k));
    row.appendChild(node('span', 'mg-row-meta', r[k]));
    list.appendChild(row);
  });
  body.appendChild(list);
  var meta = [];
  if (r._submitted) meta.push('Received ' + r._submitted);
  if (r._ip) meta.push('from ' + r._ip);
  if (r._quarantined) meta.push('held as suspect' + (r._spam_reason ? ' (' + r._spam_reason + ')' : ''));
  if (meta.length) body.appendChild(node('p', 'mg-muted', meta.join(' ')));

  var dir = d.file.replace(/\/[^\/]*$/, '');
  var a = node('a', 'mg-btn', 'All submissions in this store');
  a.href = '/manager/plugin-config?submissions=' + encodeURIComponent('/' + dir + '/');
  document.getElementById('sub-actions').appendChild(a);
}

(function() {
  var q = new URLSearchParams(location.search);
  var file = q.get('file') || '', id = q.get('id') || '';
  if (!file || !id) { show('This page shows one submission, and the link that opened it did not say which.'); return; }
  fetch(API + '?action=form-submission&file=' + encodeURIComponent(file) + '&id=' + encodeURIComponent(id),
        { credentials: 'same-origin' })
    .then(function(res) { return res.json(); })
    .then(function(d) {
      if (!d.ok) { show(d.error || 'Could not read the submission.'); return; }
      render(d);
    })
    .catch(function(e) { show('Could not read the submission: ' + e.message); });
})();
</script>
