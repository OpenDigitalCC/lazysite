---
title: Domains
auth: manager
search: false
---

<div id="status" class="mg-status"></div>

<p style="font-size:0.85em;color:#888;margin:0 0 12px;">
This instance can serve several domains at once. Each domain can be a
first&#8209;class site &mdash; its own home page, sitemap, feeds and search &mdash;
by giving it a content folder; or it can simply show your default site. Point
DNS, the web&#8209;server domain alias and TLS at this server first (your
control&#8209;panel / Hestia's job &mdash; a wildcard record + wildcard
certificate covers every sub&#8209;domain at once), then register the lazysite
side here. In the table below a grey value is inherited from the default site; a
solid value is this domain's own. Use <strong>Preview</strong> to see a domain
before its DNS is live, and <strong>Check</strong> to verify that DNS, HTTPS and
routing are configured so the domain reaches this instance.
</p>

<div class="mg-toolbar" style="margin-bottom:12px;">
  <button class="mg-btn" onclick="toggleAdd()">Add domain</button>
</div>

<div id="add-panel" style="display:none;border:1px solid var(--mg-border,#ddd);border-radius:6px;padding:14px;margin-bottom:16px;">
  <div style="display:flex;flex-wrap:wrap;gap:22px;">
    <div style="flex:1 1 260px;min-width:240px;">
      <div style="font-size:0.78em;color:#888;text-transform:uppercase;letter-spacing:0.04em;margin-bottom:6px;">Identity</div>
      <div class="mg-form-row">
        <label>Full domain name<br>
          <input id="f-host" placeholder="clienta.com" style="width:100%;box-sizing:border-box;" oninput="onHostInput()"></label>
        <div style="font-size:0.8em;color:#888;margin-top:2px;">The complete hostname visitors type &mdash; e.g. <code>clienta.com</code> or <code>shop.clienta.com</code>. Must be unique in this instance.</div>
      </div>
      <div class="mg-form-row">
        <label>Content folder <span style="color:#aaa;font-weight:400">&mdash; optional</span><br>
          <input id="f-croot" placeholder="sites/clienta" style="width:100%;box-sizing:border-box;"></label>
        <div style="font-size:0.8em;color:#888;margin-top:2px;">The folder inside your site that holds this domain's pages (created if missing). Leave empty to show your <strong>default site</strong>. The lazysite system area is reserved &mdash; pick any other folder.</div>
      </div>
    </div>
    <div style="flex:1 1 260px;min-width:240px;">
      <div style="font-size:0.78em;color:#888;text-transform:uppercase;letter-spacing:0.04em;margin-bottom:6px;">Presentation <span style="text-transform:none;letter-spacing:0">&mdash; optional, inherits the default site</span></div>
      <div class="mg-form-row">
        <label>Site address (URL)<br>
          <input id="f-siteurl" placeholder="https://clienta.com" style="width:100%;box-sizing:border-box;" oninput="siteUrlEdited=true"></label>
        <div style="font-size:0.8em;color:#888;margin-top:2px;">Filled in automatically from the domain. Change only if visitors reach it on a different address.</div>
      </div>
      <div class="mg-form-row">
        <label>Site title<br>
          <input id="f-sitename" placeholder="Client A" style="width:100%;box-sizing:border-box;"></label>
        <div style="font-size:0.8em;color:#888;margin-top:2px;">Shown in the page header and the browser tab.</div>
      </div>
      <div class="mg-form-row">
        <label>Theme<br>
          <select id="f-theme" style="width:100%;box-sizing:border-box;"><option value="">Inherit the default</option></select></label>
      </div>
    </div>
  </div>
  <div class="mg-form-row" style="margin:6px 0 12px;">
    <label><input type="checkbox" id="f-seed" checked> Seed a starter home page (only when a content folder is given)</label>
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
      <a id="domain-preview-open" href="#" target="_blank" rel="noopener noreferrer" class="mg-btn mg-btn-sm">Open live site &#8599;</a>
      <button class="mg-btn mg-btn-sm" onclick="closePreview()">Close</button>
    </div>
    <iframe id="domain-preview-frame" sandbox="allow-same-origin" style="flex:1;border:0;width:100%;"></iframe>
  </div>
</div>

<div id="domain-check-overlay" style="display:none;position:fixed;inset:0;background:rgba(0,0,0,0.5);z-index:1000;align-items:center;justify-content:center;">
  <div style="background:#fff;width:92%;max-width:680px;max-height:86%;border-radius:8px;display:flex;flex-direction:column;overflow:hidden;">
    <div style="display:flex;align-items:center;gap:10px;padding:8px 12px;border-bottom:1px solid var(--mg-border,#ddd);">
      <strong id="domain-check-title" style="flex:1;font-size:0.95em;"></strong>
      <button class="mg-btn mg-btn-sm" onclick="closeCheck()">Close</button>
    </div>
    <div id="domain-check-body" style="padding:14px 16px;overflow:auto;"></div>
  </div>
</div>

<script>
var API = '/cgi-bin/lazysite-manager-api.pl';
var THEMES = [];    // installed theme names, loaded once (see loadThemes)
var LAYOUTS = [];   // installed layout names, loaded once (see loadLayouts)
var siteUrlEdited = false;   // true once the operator types in the Site URL field

// Friendly labels for the per-domain keys - the table headers and the edit row
// use these instead of the raw conf key names (site_url, nav_file, ...).
var LABELS = {
  content_root: 'Content folder', site_url: 'Site address', site_name: 'Site title',
  theme: 'Theme', layout: 'Layout', nav_file: 'Navigation menu', search_default: 'Search'
};
function label(k) { return LABELS[k] || k; }

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

// Site URL auto-derives from the domain: scheme://host. We only overwrite it
// while the operator has not typed their own value, so a deliberate override is
// never clobbered.
function onHostInput() {
  if (siteUrlEdited) return;
  var host = document.getElementById('f-host').value.trim();
  document.getElementById('f-siteurl').value = host ? 'https://' + host : '';
}

// A <select> of installed themes, with an "(inherit)" first option and, for an
// edit row, the domain's current theme pre-selected. This is a picker over what
// is already installed - not the theme installer (that lives on Appearance).
function themeSelect(id, current) {
  var html = '<select id="' + esc(id) + '"><option value="">Inherit the default</option>';
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

// A <select> of installed layouts (like themeSelect) - the edit row uses it so
// layout is chosen from what is installed, not typed.
function layoutSelect(id, current) {
  var html = '<select id="' + esc(id) + '"><option value="">Inherit the default</option>';
  LAYOUTS.forEach(function (name) {
    html += '<option value="' + esc(name) + '"' + (name === current ? ' selected' : '') + '>' + esc(name) + '</option>';
  });
  return html + '</select>';
}

function loadLayouts() {
  return fetch(API + '?action=layouts-available', { credentials: 'same-origin' })
    .then(function (r) { return r.json(); })
    .then(function (d) { if (d && d.ok) { LAYOUTS = (d.layouts || []).slice().sort(); } })
    .catch(function () {});
}

// Columns shown in the domains table - a curated set, so the table stays narrow
// and never runs off the page. Every editable key still appears in the inline
// edit row (EDIT_KEYS) below.
var DISPLAY_KEYS = ['content_root', 'site_name', 'theme'];
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
  if (!host) { showStatus('A full domain name is required.', true); return; }
  post('domain-add', {
    host: host,
    content_root: document.getElementById('f-croot').value.trim(),   // empty = default site
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
// (e.g. www.clienta.com for clienta.com). Unique host, shared content + look.
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
  // The in-session render shows the site now (pre-DNS); the link opens the REAL
  // domain in a new tab, for once it is live.
  document.getElementById('domain-preview-open').href = 'https://' + encodeURIComponent(host).replace(/%2F/gi, '/') + '/';
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

// SM156: check whether a domain is configured to serve THIS instance live. The
// server side does the authoritative DNS / IP / TLS / marker work (a browser
// cannot); then a browser-side probe confirms the visitor's-eye view.
function checkDomain(host) {
  var ov = document.getElementById('domain-check-overlay');
  var body = document.getElementById('domain-check-body');
  document.getElementById('domain-check-title').textContent = 'Domain check: ' + host;
  body.innerHTML = '<p style="color:#888">Checking ' + esc(host) + '&hellip;</p>';
  ov.style.display = 'flex';
  fetch(API + '?action=domain-check&host=' + encodeURIComponent(host), { credentials: 'same-origin' })
    .then(function (r) { return r.json(); })
    .then(function (d) { renderCheck(host, d); })
    .catch(function (e) { body.innerHTML = '<p style="color:#b00">Check failed: ' + esc(e.message) + '</p>'; });
}
function renderCheck(host, d) {
  var body = document.getElementById('domain-check-body');
  if (!d || !d.ok) { body.innerHTML = '<p style="color:#b00">' + esc((d && d.error) || 'Check failed') + '</p>'; return; }
  var rows = (d.checks || []).map(function (c) {
    var icon = (c.pass == null) ? '<span style="color:#c90">&#9679;</span>'
             : c.pass ? '<span style="color:#080">&#10004;</span>'
             : '<span style="color:#b00">&#10008;</span>';
    return '<tr><td style="padding:5px 10px 5px 0;vertical-align:top">' + icon + '</td>'
         + '<td style="padding:5px 12px 5px 0;font-weight:600;white-space:nowrap;vertical-align:top">' + esc(c.label) + '</td>'
         + '<td style="padding:5px 0;color:#555">' + esc(c.detail) + '</td></tr>';
  }).join('');
  var summary = d.all_pass
    ? '<p style="color:#080;font-weight:600;margin:0 0 10px">This domain is live and served by this instance.</p>'
    : '<p style="color:#b00;font-weight:600;margin:0 0 10px">This domain is not fully configured yet.</p>';
  body.innerHTML = summary + '<table style="border-collapse:collapse">' + rows + '</table>'
    + '<div id="browser-probe" style="margin-top:12px;padding-top:10px;border-top:1px solid var(--mg-border,#eee);color:#888;font-size:0.9em">Checking from your browser&hellip;</div>';
  browserProbe(host);
}
// Browser-eye view: our own instance id (same origin) vs the id served over the
// candidate host. A cross-origin failure means the browser could not reach it
// over HTTPS (DNS / certificate / not live) - which is exactly what a visitor
// would hit.
function browserProbe(host) {
  var el = document.getElementById('browser-probe');
  fetch('/.well-known/lazysite-instance.json', { cache: 'no-store' })
    .then(function (r) { return r.json(); })
    .then(function (mine) {
      return fetch('https://' + host + '/.well-known/lazysite-instance.json', { cache: 'no-store' })
        .then(function (r) { return r.json(); })
        .then(function (remote) {
          if (remote && remote.instance && mine && remote.instance === mine.instance) {
            el.innerHTML = '<span style="color:#080">&#10004;</span> Your browser reaches this domain over HTTPS and it serves this instance.';
          } else {
            el.innerHTML = '<span style="color:#c90">&#9679;</span> Your browser reached it over HTTPS, but a different instance answered.';
          }
        });
    })
    .catch(function () {
      el.innerHTML = '<span style="color:#b00">&#10008;</span> Your browser could not reach https://' + esc(host) + ' (DNS, certificate, or the site is not live yet).';
    });
}
function closeCheck() { document.getElementById('domain-check-overlay').style.display = 'none'; }
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

// One inline edit field: friendly label, the domain's OWN value pre-filled; an
// inherited value is shown as a greyed placeholder so the current effective
// value is always visible without overwriting the inherit.
function editField(host, k, row) {
  var own = row[k + '_inherited'] ? '' : (row[k] || '');
  var effective = row[k] || '';
  var field;
  if (k === 'theme') {
    field = themeSelect('e-' + host + '-' + k, own);
  } else if (k === 'layout') {
    field = layoutSelect('e-' + host + '-' + k, own);
  } else {
    var ph = (row[k + '_inherited'] && effective)
      ? ' placeholder="' + esc(effective) + ' (inherited)"' : '';
    field = '<input id="e-' + esc(host) + '-' + esc(k) + '" value="' + esc(own) + '"' + ph + ' style="width:14rem;max-width:100%;box-sizing:border-box;">';
  }
  return '<label style="display:inline-flex;flex-direction:column;gap:2px;margin:0 14px 10px 0;font-size:0.85em;color:#555;">'
       + esc(label(k)) + field + '</label>';
}

function loadDomains() {
  fetch(API + '?action=domains-list', { credentials: 'same-origin' })
    .then(function (r) { return r.json(); })
    .then(function (d) {
      var listEl = document.getElementById('domains-list');
      if (!d || !d.ok) { listEl.innerHTML = '<div class="mg-status">Could not load domains.</div>'; return; }
      var rows = d.domains || [];
      // Table scrolls inside its own box (overflow-x) so a wide row never pushes
      // the page sideways; the column set is curated (DISPLAY_KEYS) to stay slim.
      var html = '<div style="overflow-x:auto;"><table class="mg-file-table" style="min-width:0;"><thead><tr><th>Domain</th>';
      DISPLAY_KEYS.forEach(function (k) { html += '<th>' + esc(label(k)) + '</th>'; });
      html += '<th>Actions</th></tr></thead><tbody>';
      rows.forEach(function (row) {
        // SM155: an alias row is indented and tagged under its canonical domain.
        var tag = row.is_primary ? ' <span style="color:#888;font-weight:400">default site</span>'
                : row.alias_of ? ' <span style="color:#888;font-weight:400" title="serves the same content as ' + esc(row.alias_of) + '">&#8627; alias of ' + esc(row.alias_of) + '</span>'
                : '';
        var pad = row.alias_of ? ' style="padding-left:1.6rem"' : '';
        html += '<tr><td class="mg-file-name"' + pad + '><strong>' + esc(row.host) + '</strong>' + tag + '</td>';
        DISPLAY_KEYS.forEach(function (k) {
          var v = row[k], inherited = row[k + '_inherited'], cell;
          if (k === 'content_root' && !v) {
            cell = '<span style="color:#999" title="serves your default site">default site</span>';
          } else if (!v) {
            cell = '<span style="color:#ccc">&mdash;</span>';
          } else if (inherited) {
            cell = '<span style="color:#999" title="inherited from the default site">' + esc(v) + '</span>';
          } else {
            cell = esc(v);
          }
          html += '<td>' + cell + '</td>';
        });
        // Actions - buttons may wrap on a narrow screen (no nowrap).
        if (row.is_primary) {
          html += '<td></td></tr>';
        } else if (row.alias_of) {
          html += '<td>'
                + '<button class="mg-btn mg-btn-sm" onclick="previewDomain(' + esc(JSON.stringify(row.host)) + ')">Preview</button> '
                + '<button class="mg-btn mg-btn-sm" onclick="checkDomain(' + esc(JSON.stringify(row.host)) + ')">Check</button> '
                + '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="removeDomain(' + esc(JSON.stringify(row.host)) + ')">Remove</button>'
                + '</td></tr>';
        } else {
          html += '<td>'
                + '<button class="mg-btn mg-btn-sm" onclick="previewDomain(' + esc(JSON.stringify(row.host)) + ')">Preview</button> '
                + '<button class="mg-btn mg-btn-sm" onclick="checkDomain(' + esc(JSON.stringify(row.host)) + ')">Check</button> '
                + '<button class="mg-btn mg-btn-sm" onclick="editDomain(' + esc(JSON.stringify(row.host)) + ')">Edit</button> '
                + '<button class="mg-btn mg-btn-sm" onclick="addAlias(' + esc(JSON.stringify(row.host)) + ')">Alias</button> '
                + '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="removeDomain(' + esc(JSON.stringify(row.host)) + ')">Remove</button>'
                + '</td></tr>';
          // Hidden inline edit row for the presentation keys - styled panel,
          // friendly labels, current values pre-filled (editField).
          html += '<tr id="edit-' + esc(row.host) + '" style="display:none"><td colspan="' + (DISPLAY_KEYS.length + 2) + '">'
                + '<div style="background:var(--mg-panel,#fafafa);border:1px solid var(--mg-border,#e2e2e2);border-radius:5px;padding:12px 14px;">'
                + '<div style="font-size:0.78em;color:#888;text-transform:uppercase;letter-spacing:0.04em;margin-bottom:8px;">Edit ' + esc(row.host) + '</div>'
                + '<div style="display:flex;flex-wrap:wrap;align-items:flex-end;">';
          EDIT_KEYS.forEach(function (k) { html += editField(row.host, k, row); });
          html += '</div>'
                + '<button class="mg-btn mg-btn-sm mg-btn-primary" onclick="saveDomain(' + esc(JSON.stringify(row.host)) + ')">Save changes</button>'
                + '</div></td></tr>';
        }
      });
      html += '</tbody></table></div>';
      if (rows.length <= 1) {
        html += '<p style="font-size:0.85em;color:#888;margin-top:10px;">'
              + 'No extra domains yet. Use <strong>Add domain</strong> to host several '
              + 'first-class sites from this one instance.</p>';
      }
      listEl.innerHTML = html;
    })
    .catch(function () {
      document.getElementById('domains-list').innerHTML = '<div class="mg-status">Error loading domains.</div>';
    });
}

Promise.all([loadThemes(), loadLayouts()]).then(loadDomains);
</script>
