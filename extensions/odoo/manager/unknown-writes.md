---
title: Unknown Odoo writes
auth: manager
search: false
---

<!-- SM1369 X6, H-8 (ruling 188): THE ODOO EXTENSION'S OWN MANAGER PAGE. It was a
     panel inside the extension-config page, drawn there because core knew the
     extension by name (SM1278). It is the extension's now: shipped in its
     payload (extensions/odoo/manager), declared in hooks.panels, served at
     /manager/odoo-unknown-writes to a manager holding settle_odoo_writes, and
     linked from the Odoo card on the extension-config page. What it asks of the
     API is gated by the API's own rows, as before. -->
<div class="mg-toolbar">
  <a class="mg-btn mg-btn-sm" href="/manager/extension-config">Extensions - configure</a>
</div>

<div id="status" class="mg-status"></div>

<div class="mg-note mg-note-info" id="odoo-unknown-note">A run whose apply sent a change and got no answer stays open until it is settled or closed. <strong>Check again</strong> asks for each change to be read back; <strong>It was made</strong> and <strong>It was not made</strong> are your word for one change; <strong>Close run</strong> dismisses the run without sending anything.</div>

<div class="mg-card-body" id="odoo-unknown-body">Loading&hellip;</div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';

function esc(s) { return (s||'').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;').replace(/'/g,'&#39;'); }

// --- Unknown Odoo writes (SM1278, rulings 10b and 10c) ---
//
// An Odoo run whose apply sent a change and got no answer stays open until it is
// settled or dismissed. Each open run is listed with the changes still unknown.
// Check again asks OOM to read them back; It was made / It was not made is the
// operator's word for one change (settle_odoo_writes); Close run dismisses it
// without sending anything. A run a person made signed in to Odoo ran on their
// own login, so only they can resume it: it is offered Close run alone. The keys are
// held in window._unknownRuns and named by index, never written into a handler.

// SM1328: Odoo by the site's odoo_display_name, which the listing answers ('' for
// none: the text then names nothing); "Odoo" until a listing has said.
window._odooName = 'Odoo';
function odooSaid(named, plain) {
  var n = window._odooName;
  return n ? named.split('{name}').join(n) : plain;
}

function loadUnknownRuns() {
  var el = document.getElementById('odoo-unknown-body');
  if (!el) return;
  fetch(API + '?action=odoo-unknown-runs').then(function (r) { return r.json(); }).then(function (d) {
    if (!d || !d.ok) { el.innerHTML = '<p class="mg-muted">' + esc((d && d.error) || 'Unavailable.') + '</p>'; return; }
    window._unknownRuns = d.runs || [];
    if (d.display_name !== undefined) window._odooName = String(d.display_name || '');
    if (!window._unknownRuns.length) { el.innerHTML = '<p class="mg-muted">' + esc(odooSaid('No {name} run is waiting.', 'No run is waiting.')) + '</p>'; return; }
    var h = '<div class="mg-table-wrap"><table class="mg-table"><thead><tr>'
          + '<th>Binding</th><th>Made by</th><th>When</th><th>Change</th><th></th></tr></thead><tbody>';
    window._unknownRuns.forEach(function (run, i) {
      var when = run.at ? new Date(run.at * 1000).toLocaleString() : '';
      var who = run.person ? odooSaid('a person signed in to {name}', 'a signed-in person') : (run.owner || '');
      var changes = run.changes && run.changes.length ? run.changes : [{}];
      changes.forEach(function (c, j) {
        var what = [c.key || ('#' + (c.seq || '')), c.action, c.model, c.id].filter(function (x) { return x !== undefined && x !== ''; }).join(' ');
        h += '<tr><td>' + (j ? '' : esc(run.binding)) + '</td><td>' + (j ? '' : esc(who)) + '</td><td>'
           + (j ? '' : esc(when)) + '</td><td><code>' + esc(what) + '</code></td><td>';
        if (!run.person && c.seq !== undefined) {
          h += '<button class="mg-btn mg-btn-sm" onclick="settleChange(' + i + ',' + j + ',\'done\')">It was made</button> '
             + '<button class="mg-btn mg-btn-sm" onclick="settleChange(' + i + ',' + j + ',\'not\')">It was not made</button>';
        }
        h += '</td></tr>';
      });
      h += '<tr><td colspan="5">';
      if (!run.person) h += '<button class="mg-btn mg-btn-sm" onclick="checkRunAgain(' + i + ')">Check again</button> ';
      h += '<button class="mg-btn mg-btn-sm" onclick="dismissRun(' + i + ')">Close run</button></td></tr>';
    });
    el.innerHTML = h + '</tbody></table></div>';
  }).catch(function (e) { el.textContent = 'Error: ' + e.message; });
}

function resumeRun(body, done) {
  fetch(API + '?action=odoo-resume', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body)
  })
    .then(function (r) { return r.json(); })
    .then(function (d) {
      if (d && d.ok) showStatus(done);
      else if (d && d.kind === 'unknown-outcome') showStatus(odooSaid('{name} cannot be asked about a change of this run. Say whether it was made.', 'A change of this run cannot be read back. Say whether it was made.'), true);
      else if (d && d.unknown) showStatus('The run went on and a change got no answer again. It is listed below.', true);
      else showStatus((d && d.error) || 'The run was not resumed', true);
      loadUnknownRuns();
    })
    .catch(function (e) { showStatus('Error: ' + e.message, true); });
}

function checkRunAgain(i) {
  var run = (window._unknownRuns || [])[i];
  if (run) resumeRun({ run: run.run }, 'Read back: the run is settled.');
}

function settleChange(i, j, how) {
  var run = (window._unknownRuns || [])[i];
  var c = run && run.changes && run.changes[j];
  if (!c) return;
  var name = c.key || String(c.seq);
  var body = { run: run.run };
  body[how === 'done' ? 'assume_done' : 'assume_not_done'] = [name];
  resumeRun(body, how === 'done' ? 'Settled: the change is recorded as made.' : 'Settled: the change was sent again.');
}

function dismissRun(i) {
  var run = (window._unknownRuns || [])[i];
  if (!run) return;
  mgConfirm(odooSaid('Close this run? It is no longer offered, and nothing is sent to {name}.', 'Close this run? It is no longer offered, and nothing is sent.'), { ok: 'Close run' }).then(function (ok) {
    if (!ok) return;
    fetch(API + '?action=odoo-dismiss', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ run: run.run })
    })
      .then(function (r) { return r.json(); })
      .then(function (d) {
        if (!d || !d.ok) { showStatus((d && d.error) || 'The run was not dismissed', true); return; }
        showStatus('Closed: the run is dismissed.');
        loadUnknownRuns();
      })
      .catch(function (e) { showStatus('Error: ' + e.message, true); });
  });
}

loadUnknownRuns();
</script>
