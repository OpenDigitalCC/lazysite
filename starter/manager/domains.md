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
domain alias and TLS at this server first (your control&#8209;panel / Hestia's
job &mdash; a wildcard record + wildcard certificate covers every sub&#8209;domain
at once) &mdash; then register the lazysite side here. A grey value is inherited
from the default host; a solid value is a per&#8209;domain override.
</p>

<div class="mg-toolbar" style="margin-bottom:12px;">
  <button class="mg-btn" onclick="toggleAdd()">Add domain</button>
</div>

<div id="add-panel" style="display:none;border:1px solid var(--mg-border,#ddd);border-radius:6px;padding:12px;margin-bottom:16px;max-width:520px;">
  <fieldset style="border:1px solid var(--mg-border,#e2e2e2);border-radius:5px;padding:8px 12px 12px;margin:0 0 12px;">
    <legend style="font-size:0.78em;color:#888;padding:0 4px;">Identity</legend>
    <div class="mg-form-row"><label>Host<br><input id="f-host" placeholder="clienta.com" size="30"></label></div>
    <div class="mg-form-row"><label>Content root<br><input id="f-croot" placeholder="sites/clienta" size="30"></label>
      <div style="font-size:0.8em;color:#888;margin-top:2px;">A directory under the docroot (created if missing). Not the <code>lazysite/</code> tree.</div></div>
  </fieldset>
  <fieldset style="border:1px solid var(--mg-border,#e2e2e2);border-radius:5px;padding:8px 12px 12px;margin:0 0 12px;">
    <legend style="font-size:0.78em;color:#888;padding:0 4px;">Presentation &mdash; optional (inherits the default site otherwise)</legend>
    <div class="mg-form-row"><label>Site URL<br><input id="f-siteurl" placeholder="https://clienta.com" size="30"></label></div>
    <div class="mg-form-row"><label>Site name<br><input id="f-sitename" placeholder="Client A" size="30"></label></div>
    <div class="mg-form-row"><label>Theme<br>
      <select id="f-theme"><option value="">(inherit the default)</option></select></label></div>
  </fieldset>
  <div class="mg-form-row" style="margin:0 0 10px;">
    <label><input type="checkbox" id="f-seed" checked> Seed a starter home page</label>
  </div>
  <div class="mg-form-row">
    <button class="mg-btn mg-btn-primary" onclick="addDomain()">Register domain</button>
    <button class="mg-btn" onclick="toggleAdd()">Cancel</button>
  </div>
</div>

<div id="domains-list"><div class="mg-status">Loading&hellip;</div></div>

<div id="domain-preview-overlay" style="display:none;position:fixed;inset:0;background:rgba(0,0,0,0.5);z-index:1000;align-items:center;justify-content:center;">
  <div style="background:#fff;width:92%;max-width:1100px;height:86%;border-radius:8px;display:flex;flex-direction:column;overflow:hidden;">
    <div style="display:flex;align-items:center;gap:10px;padding:8px 12px;border-bottom:1px solid var(--mg-border,#ddd);">
      <strong id="domain-preview-title" style="flex:1;font-size:0.95em;"></strong>
      <span style="font-size:0.8em;color:#888;">public render &mdash; scripts disabled</span>
      <button class="mg-btn mg-btn-sm" onclick="closePreview()">Close</button>
    </div>
    <iframe id="domain-preview-frame" sandbox="allow-same-origin" style="flex:1;border:0;width:100%;"></iframe>
  </div>
</div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';
var THEMES = [];   // installed theme names, loaded once (see loadThemes)

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

// A <select> of installed themes, with an "(inherit)" first option and, for an
// edit row, the domain's current theme pre-selected. This is a picker over what
// is already installed - not the theme installer (that lives on Appearance).
function themeSelect(id, current) {
  var html = '<select id="' + esc(id) + '"><option value="">(inherit)</option>';
  THEMES.forEach(function (name) {
    html += '<option value="' + esc(name) + '"' + (name === current ? ' selected' : '') + '>' + esc(name) + '</option>';
  });
  return html + '</select>';
}

function loadThemes() {
  return fetch(API + '?action=themes-list-all', { credentials: 'same-origin' })
    .then(function (r) { return r.json(); })
    .then(function (d) {
      if (!d || !d.ok) return;
      var seen = {};
      (d.themes || []).forEach(function (t) {
        if (t.name && !seen[t.name]) { seen[t.name] = 1; THEMES.push(t.name); }
      });
      THEMES.sort();
      var sel = document.getElementById('f-theme');   // populate the add-form select
      if (sel) {
        THEMES.forEach(function (name) {
          var o = document.createElement('option');
          o.value = name; o.textContent = name;
          sel.appendChild(o);
        });
      }
    })
    .catch(function () {});
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
    theme: document.getElementById('f-theme').value,
    seed: document.getElementById('f-seed').checked ? 1 : 0
  }).then(function (d) {
    if (d && d.ok) { showStatus('Registered ' + host); toggleAdd(); loadDomains(); }
    else { showStatus((d && d.error) || 'Could not register the domain.', true); }
  });
}

// SM155: add an alias host that serves the same content as a canonical domain
// (e.g. www.clienta.com for clienta.com). Unique host, shared content root.
function addAlias(canonical) {
  var host = window.prompt('Alias host for ' + canonical + ' (serves the same content):', 'www.' + canonical);
  if (!host) return;
  host = host.trim();
  if (!host) return;
  post('domain-alias-add', { host: host, of: canonical }).then(function (d) {
    if (d && d.ok) { showStatus('Added alias ' + host + ' -> ' + canonical); loadDomains(); }
    else { showStatus((d && d.error) || 'Could not add the alias.', true); }
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

// SM155: preview a domain's home page as a public visitor would see it under its
// own Host - rendered server-side, so it works BEFORE DNS/TLS is live (to
// prepare/debug a new domain). The HTML is shown in a sandboxed iframe srcdoc.
function previewDomain(host) {
  var ov = document.getElementById('domain-preview-overlay');
  var frame = document.getElementById('domain-preview-frame');
  var title = document.getElementById('domain-preview-title');
  title.textContent = 'Preview: ' + host;
  frame.srcdoc = '<p style="font:14px system-ui;padding:1rem;color:#888">Rendering&hellip;</p>';
  ov.style.display = 'flex';
  fetch(API + '?action=domain-preview&host=' + encodeURIComponent(host), { credentials: 'same-origin' })
    .then(function (r) { return r.json(); })
    .then(function (d) {
      if (d && d.ok) { frame.srcdoc = d.html || '<p style="padding:1rem">(empty page)</p>'; }
      else { frame.srcdoc = '<p style="font:14px system-ui;padding:1rem;color:#b00">' + (d && d.error ? d.error : 'Preview failed') + '</p>'; }
    })
    .catch(function (e) { frame.srcdoc = '<p style="font:14px system-ui;padding:1rem;color:#b00">Error: ' + e.message + '</p>'; });
}
function closePreview() { document.getElementById('domain-preview-overlay').style.display = 'none'; }

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
        // SM155: an alias row is indented and tagged under its canonical domain.
        var tag = row.is_primary ? ' <span style="color:#888;font-weight:400">primary</span>'
                : row.alias_of ? ' <span style="color:#888;font-weight:400" title="serves the same content as ' + esc(row.alias_of) + '">&#8627; alias of ' + esc(row.alias_of) + '</span>'
                : '';
        var pad = row.alias_of ? ' style="padding-left:1.6rem"' : '';
        html += '<tr><td class="mg-file-name"' + pad + '><strong>' + esc(row.host) + '</strong>' + tag + '</td>';
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
        } else if (row.alias_of) {
          // An alias shares its canonical's content - preview + remove only.
          html += '<td style="white-space:nowrap">'
                + '<button class="mg-btn mg-btn-sm" onclick="previewDomain(' + esc(JSON.stringify(row.host)) + ')">Preview</button> '
                + '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="removeDomain(' + esc(JSON.stringify(row.host)) + ')">Remove</button>'
                + '</td></tr>';
        } else {
          html += '<td style="white-space:nowrap">'
                + '<button class="mg-btn mg-btn-sm" onclick="previewDomain(' + esc(JSON.stringify(row.host)) + ')">Preview</button> '
                + '<button class="mg-btn mg-btn-sm" onclick="editDomain(' + esc(JSON.stringify(row.host)) + ')">Edit</button> '
                + '<button class="mg-btn mg-btn-sm" onclick="addAlias(' + esc(JSON.stringify(row.host)) + ')">Alias</button> '
                + '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="removeDomain(' + esc(JSON.stringify(row.host)) + ')">Remove</button>'
                + '</td></tr>';
          // Hidden inline edit row for the presentation keys.
          html += '<tr id="edit-' + esc(row.host) + '" style="display:none"><td colspan="' + (keys.length + 2) + '">';
          EDIT_KEYS.forEach(function (k) {
            var cur = row[k + '_inherited'] ? '' : (row[k] || '');
            var field = (k === 'theme')
              ? themeSelect('e-' + row.host + '-' + k, cur)
              : '<input id="e-' + esc(row.host) + '-' + esc(k) + '" value="' + esc(cur) + '" size="16">';
            html += '<label style="display:inline-block;margin:2px 10px 2px 0">' + esc(k) + ' ' + field + '</label>';
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

loadThemes().then(loadDomains);
</script>
