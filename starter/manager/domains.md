---
title: Domains
auth: manager
search: false
---

<div id="status" class="mg-status"></div>

<p style="font-size:0.85em;color:#888;margin:0 0 12px;">
This instance serves one or more domains. Each domain has its own
<code>content_root</code> (a first&#8209;class site: its own home, sitemap, feeds
and search) and can override presentation keys. Point DNS, the web&#8209;server
domain alias and TLS at this server first (that is your control&#8209;panel /
Hestia's job) &mdash; then register the lazysite side here. A grey value is
inherited from the default host; a solid value is a per&#8209;domain override.
</p>

<div class="mg-toolbar" style="margin-bottom:12px;">
  <button class="mg-btn" onclick="toggleAdd()">Add domain</button>
</div>

<div id="add-panel" style="display:none;border:1px solid var(--mg-border,#ddd);border-radius:6px;padding:12px;margin-bottom:16px;">
  <div class="mg-form-row"><label>Host <input id="f-host" placeholder="clienta.com" size="24"></label></div>
  <div class="mg-form-row"><label>Content root <input id="f-croot" placeholder="sites/clienta" size="24"></label>
    <span style="font-size:0.8em;color:#888;">directory under the docroot; not the lazysite/ tree</span></div>
  <div class="mg-form-row"><label>Site URL <input id="f-siteurl" placeholder="https://clienta.com" size="24"></label></div>
  <div class="mg-form-row"><label>Site name <input id="f-sitename" placeholder="Client A" size="24"></label></div>
  <div class="mg-form-row"><label>Theme <input id="f-theme" placeholder="(inherit)" size="16"></label>
    <label style="margin-left:12px;"><input type="checkbox" id="f-seed" checked> seed a starter page</label></div>
  <div class="mg-form-row" style="margin-top:8px;">
    <button class="mg-btn mg-btn-primary" onclick="addDomain()">Register domain</button>
    <button class="mg-btn" onclick="toggleAdd()">Cancel</button>
  </div>
</div>

<div id="domains-list"><div class="mg-status">Loading&hellip;</div></div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';

// SEC: attribute-safe escape (all five significant characters), not the weak
// textContent->innerHTML which leaves quotes raw.
function esc(s) {
  s = (s == null ? '' : String(s));
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
          .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
function showStatus(msg, isError) {
  var el = document.getElementById('status');
  el.textContent = msg;
  el.style.color = isError ? '#b00' : '#080';
  if (!isError) setTimeout(function () { el.textContent = ''; }, 4000);
}
function toggleAdd() {
  var p = document.getElementById('add-panel');
  p.style.display = (p.style.display === 'none') ? 'block' : 'none';
}

// Presentation keys an existing domain can override (content_root is set at
// creation - changing where content lives is a move, done via Files).
var EDIT_KEYS = ['site_url', 'site_name', 'theme', 'layout', 'nav_file', 'search_default'];

function post(action, obj) {
  return fetch(API + '?action=' + action, {
    method: 'POST', credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(obj || {})
  }).then(function (r) { return r.json(); });
}

function addDomain() {
  var host = document.getElementById('f-host').value.trim();
  var croot = document.getElementById('f-croot').value.trim();
  if (!host || !croot) { showStatus('Host and content root are required.', true); return; }
  post('domain-add', {
    host: host, content_root: croot,
    site_url: document.getElementById('f-siteurl').value.trim(),
    site_name: document.getElementById('f-sitename').value.trim(),
    theme: document.getElementById('f-theme').value.trim(),
    seed: document.getElementById('f-seed').checked ? 1 : 0
  }).then(function (d) {
    if (d && d.ok) { showStatus('Registered ' + host); toggleAdd(); loadDomains(); }
    else { showStatus((d && d.error) || 'Could not register the domain.', true); }
  });
}

function removeDomain(host) {
  if (!window.confirm('Unregister ' + host + '? Its content files are kept.')) return;
  post('domain-remove', { host: host }).then(function (d) {
    if (d && d.ok) { showStatus('Removed ' + host); loadDomains(); }
    else { showStatus((d && d.error) || 'Could not remove the domain.', true); }
  });
}

function editDomain(host) {
  var row = document.getElementById('edit-' + host);
  if (row) row.style.display = (row.style.display === 'none') ? 'table-row' : 'none';
}

function saveDomain(host) {
  var chain = Promise.resolve();
  var changed = 0;
  EDIT_KEYS.forEach(function (k) {
    var inp = document.getElementById('e-' + host + '-' + k);
    if (!inp) return;
    changed++;
    chain = chain.then(function () { return post('domain-set', { host: host, key: k, value: inp.value.trim() }); });
  });
  chain.then(function () {
    if (changed) { showStatus('Saved ' + host); loadDomains(); }
  });
}

function loadDomains() {
  fetch(API + '?action=domains-list', { credentials: 'same-origin' })
    .then(function (r) { return r.json(); })
    .then(function (d) {
      var host = document.getElementById('domains-list');
      if (!d || !d.ok) { host.innerHTML = '<div class="mg-status">Could not load domains.</div>'; return; }
      var keys = d.keys || [];
      var rows = d.domains || [];
      var html = '<table class="mg-file-table"><thead><tr><th>Host</th>';
      keys.forEach(function (k) { html += '<th>' + esc(k) + '</th>'; });
      html += '<th></th></tr></thead><tbody>';
      rows.forEach(function (row) {
        html += '<tr><td class="mg-file-name"><strong>' + esc(row.host) + '</strong>'
              + (row.is_primary ? ' <span style="color:#888;font-weight:400">primary</span>' : '') + '</td>';
        keys.forEach(function (k) {
          var v = row[k], inherited = row[k + '_inherited'], cell;
          if (!v) cell = '<span style="color:#ccc">&mdash;</span>';
          else if (inherited) cell = '<span style="color:#999" title="inherited from the default host">' + esc(v) + '</span>';
          else cell = esc(v);
          html += '<td>' + cell + '</td>';
        });
        // Actions (never on the primary/default row).
        if (row.is_primary) {
          html += '<td></td></tr>';
        } else {
          html += '<td style="white-space:nowrap">'
                + '<button class="mg-btn mg-btn-sm" onclick="editDomain(' + esc(JSON.stringify(row.host)) + ')">Edit</button> '
                + '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="removeDomain(' + esc(JSON.stringify(row.host)) + ')">Remove</button>'
                + '</td></tr>';
          // Hidden inline edit row for the presentation keys.
          html += '<tr id="edit-' + esc(row.host) + '" style="display:none"><td colspan="' + (keys.length + 2) + '">';
          EDIT_KEYS.forEach(function (k) {
            html += '<label style="display:inline-block;margin:2px 10px 2px 0">' + esc(k) + ' '
                  + '<input id="e-' + esc(row.host) + '-' + esc(k) + '" value="' + esc(row[k + '_inherited'] ? '' : (row[k] || '')) + '" size="16"></label>';
          });
          html += ' <button class="mg-btn mg-btn-sm mg-btn-primary" onclick="saveDomain(' + esc(JSON.stringify(row.host)) + ')">Save</button>';
          html += '</td></tr>';
        }
      });
      html += '</tbody></table>';
      if (rows.length <= 1) {
        html += '<p style="font-size:0.85em;color:#888;margin-top:10px;">'
              + 'No alias domains yet. Use <strong>Add domain</strong> to host several '
              + 'first-class sites from this one instance.</p>';
      }
      host.innerHTML = html;
    })
    .catch(function () {
      document.getElementById('domains-list').innerHTML = '<div class="mg-status">Error loading domains.</div>';
    });
}

loadDomains();
</script>
