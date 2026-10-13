---
title: Account import
auth: manager
search: false
---

<div id="status" class="mg-status"></div>

<!-- SM1053 (P-5), ruled 2026-10-12, "Operator-run import": a partner stages a
     list of accounts (usernames, emails, groups - never a password) with
     accounts-import-stage; the operator reviews the dry run here and applies it.
     Each new account has no password and gets a claim link; its address is
     recorded, so "forgot password" sends the person their own link. Groups that
     do not exist are left out, and say so. -->
<div class="mg-note mg-note-info">A partner prepares an import; you review what it would do and apply it. New accounts have no password: each person sets their own with the claim link shown after applying (mailed to them if you tick the box), or by using <em>forgot password</em> with the address recorded. Groups that do not exist are left out.</div>

<div class="mg-card">
<div class="mg-card-header"><span class="mg-card-title">Staged imports</span></div>
<div class="mg-card-body">
<div class="mg-list" id="imports"><div class="mg-empty">Loading...</div></div>
</div>
</div>

<div class="mg-card" id="plan-card" hidden>
<div class="mg-card-header"><span class="mg-card-title" id="plan-title">Dry run</span></div>
<div class="mg-card-body">
<p class="mg-muted" id="plan-summary"></p>
<div class="mg-list" id="plan-rows"></div>
<!-- n570: mailing the links is the operator's choice, made at each apply; off unless ticked. -->
<label class="mg-chk"><input type="checkbox" id="apply-mail"> Mail each new account its claim link, at the address its row carries</label>
<div class="mg-toolbar"><button class="mg-btn mg-btn-primary" id="apply-btn" data-impact="commit">Apply this import</button></div>
</div>
</div>

<div class="mg-card" id="result-card" hidden>
<div class="mg-card-header"><span class="mg-card-title">Applied</span></div>
<div class="mg-card-body"><div class="mg-list" id="result-rows"></div></div>
</div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';
var current = '';

function node(tag, cls, text) {
  var e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text != null) e.textContent = text;    // staged values are a partner's: text only
  return e;
}

function fail(msg) {
  if (typeof mgShowWarning === 'function') mgShowWarning(msg, true);
}

function row(name, meta) {
  var r = node('div', 'mg-row');
  r.appendChild(node('span', 'mg-row-name', name));
  r.appendChild(node('span', 'mg-row-meta', meta));
  return r;
}

function loadImports() {
  fetch(API + '?action=accounts-import-list', { credentials: 'same-origin' })
    .then(function(res) { return res.json(); })
    .then(function(d) {
      var list = document.getElementById('imports');
      list.textContent = '';
      if (!d.ok) { list.appendChild(node('div', 'mg-empty', d.error || 'Could not list the imports.')); return; }
      if (!(d.imports || []).length) { list.appendChild(node('div', 'mg-empty', 'Nothing is staged.')); return; }
      d.imports.forEach(function(i) {
        var when = new Date(i.staged_at * 1000).toISOString().replace('T', ' ').slice(0, 16);
        var meta = i.accounts + ' account(s) staged by ' + i.staged_by + ' at ' + when
          + (i.invalid ? ', ' + i.invalid + ' invalid row(s)' : '')
          + (i.applied_at ? ' - applied by ' + i.applied_by : '');
        var r = row(i.id, meta);
        var b = node('button', 'mg-btn', 'Review');
        b.addEventListener('click', function() { review(i.id); });
        r.appendChild(b);
        list.appendChild(r);
      });
    })
    .catch(function(e) { fail('Could not list the imports: ' + e.message); });
}

function review(id) {
  fetch(API + '?action=accounts-import-plan&id=' + encodeURIComponent(id), { credentials: 'same-origin' })
    .then(function(res) { return res.json(); })
    .then(function(d) {
      if (!d.ok) { fail(d.error || 'Could not plan the import.'); return; }
      current = d.id;
      document.getElementById('plan-card').hidden = false;
      document.getElementById('plan-title').textContent = 'Dry run: ' + d.id;
      document.getElementById('plan-summary').textContent = d.create + ' to create, ' + d.skip
        + ' already exist (skipped), ' + (d.invalid || []).length + ' invalid'
        + ((d.groups_missing || []).length ? '. Groups that do not exist, left out: ' + d.groups_missing.join(', ') : '')
        + (d.applied_at ? '. Already applied.' : '.');
      var rows = document.getElementById('plan-rows');
      rows.textContent = '';
      (d.rows || []).forEach(function(r) {
        rows.appendChild(row(r.username, r.action + (r.email ? ' - ' + r.email : '')
          + ((r.groups || []).length ? ' - joins ' + r.groups.join(', ') : '')
          + ((r.groups_missing || []).length ? ' - not ' + r.groups_missing.join(', ') : '')));
      });
      (d.invalid || []).forEach(function(r) {
        rows.appendChild(row('row ' + r.row + (r.username ? ' (' + r.username + ')' : ''), 'invalid - ' + r.error));
      });
      document.getElementById('apply-btn').disabled = !!d.applied_at || !d.create;
    })
    .catch(function(e) { fail('Could not plan the import: ' + e.message); });
}

document.getElementById('apply-btn').addEventListener('click', function() {
  if (!current || !confirm('Create the accounts in ' + current + '?')) return;
  fetch(API + '?action=accounts-import-apply', {
    method: 'POST', credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ id: current, confirm: current, mail: document.getElementById('apply-mail').checked })
  })
    .then(function(res) { return res.json(); })
    .then(function(d) {
      if (!d.ok && !(d.created || []).length) { fail(d.error || 'The import was not applied.'); return; }
      if (typeof mgClearWarning === 'function') mgClearWarning();
      document.getElementById('result-card').hidden = false;
      var rows = document.getElementById('result-rows');
      rows.textContent = '';
      (d.created || []).forEach(function(c) {
        rows.appendChild(row(c.username, (c.claim_url || c.claim_path)
          + ((c.unplaced || []).length ? ' - not placed in ' + c.unplaced.map(function(u) { return u.group; }).join(', ') : '')
          + (c.mailed ? ' - mailed' : '') + (c.mail_error ? ' - not mailed: ' + c.mail_error : '')));
      });
      (d.failed || []).forEach(function(f) { rows.appendChild(row(f.username, 'not created - ' + f.error)); });
      loadImports();
      review(current);
    })
    .catch(function(e) { fail('The import was not applied: ' + e.message); });
});

loadImports();
</script>
