---
title: Domains
auth: manager
search: false
---

<style>
.mg-rowmenu { display: inline-block; }
.mg-rowmenu > summary { list-style: none; cursor: pointer; }
.mg-rowmenu > summary::-webkit-details-marker { display: none; }
.mg-rowmenu-items { display: flex; flex-direction: column; gap: 4px; margin-top: 4px; align-items: flex-start; }
</style>

<div id="status" class="mg-status"></div>

<p style="font-size:0.85em;color:#888;margin:0 0 12px;">
Your site is always served at its default address. This page is for the
<strong>additional domains</strong> you serve from this one instance. Each can be
a first&#8209;class site &mdash; its own home page, sitemap, feeds and search &mdash;
by giving it a content folder; or it can mirror your default site. Point
DNS, the web&#8209;server domain alias and TLS at this server first (your
control&#8209;panel / Hestia's job &mdash; a wildcard record + wildcard
certificate covers every sub&#8209;domain at once), then register the lazysite
side here. In the table below a grey value is inherited from the default site; a
solid value is this domain's own. Use <strong>Preview</strong> to see a domain
before its DNS is live, and <strong>Check</strong> to verify that DNS, HTTPS and
routing are configured so the domain reaches this instance.
</p>

<div style="border:1px solid var(--mg-border,#e2e2e2);border-radius:5px;padding:10px 12px;margin-bottom:12px;">
  <label style="font-size:0.9em;">This server's public IP address(es) <span style="color:#aaa;font-weight:400">&mdash; optional</span><br>
    <input id="f-canonical-ip" placeholder="e.g. 203.0.113.5" style="width:16rem;max-width:100%;box-sizing:border-box;">
    <button class="mg-btn mg-btn-sm mg-btn-primary" onclick="saveCanonicalIp()">Save</button></label>
  <div style="font-size:0.8em;color:#888;margin-top:2px;">Used by <strong>Check</strong> to confirm a domain points to this server. Comma&#8209;separate several. Leave blank to auto&#8209;detect (from your site address, or the server's own address) &mdash; set it when this server sits behind a proxy or NAT.</div>
</div>

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
      <div class="mg-form-row">
        <label>Copy settings from <span style="color:#aaa;font-weight:400">&mdash; optional</span><br>
          <select id="f-clone-from" onchange="cloneFrom(this.value)" style="width:100%;box-sizing:border-box;"><option value="">Start blank</option></select></label>
        <div style="font-size:0.8em;color:#888;margin-top:2px;">Pre-fill this form from an existing domain (its content folder, title and appearance) &mdash; a quick way to stand up another domain like one you already have. You can change anything before saving.</div>
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
        <label>Appearance (layout &amp; theme)<br>
          <select id="f-appearance" style="width:100%;box-sizing:border-box;"><option value="">Inherit the default</option></select></label>
        <div style="font-size:0.8em;color:#888;margin-top:2px;">A theme always belongs to a layout, so pick them together.</div>
      </div>
    </div>
    <div style="flex:1 1 260px;min-width:240px;">
      <div style="font-size:0.78em;color:#888;text-transform:uppercase;letter-spacing:0.04em;margin-bottom:6px;">Language <span style="text-transform:none;letter-spacing:0">&mdash; optional, for a multilingual set</span></div>
      <div class="mg-form-row">
        <label>Language<br>
          <input id="f-lang" placeholder="en" style="width:100%;box-sizing:border-box;"></label>
        <div style="font-size:0.8em;color:#888;margin-top:2px;">This host's language, e.g. <code>en</code>, <code>fr</code>, <code>pt-BR</code>. Sets <code>&lt;html lang&gt;</code> and the Content-Language header.</div>
      </div>
      <div class="mg-form-row">
        <label>Language set<br>
          <input id="f-lang-group" placeholder="providers" style="width:100%;box-sizing:border-box;"></label>
        <div style="font-size:0.8em;color:#888;margin-top:2px;">A shared name across the languages of one site. Two&#8239;+ hosts sharing it become a switchable set.</div>
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

<div id="lang-coverage" style="display:none;margin-top:22px;"></div>

[%# SM165: shared principal datalists backing the domain access token pickers. %]
<datalist id="dom-groups-list"></datalist>
<datalist id="dom-users-list"></datalist>

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
var siteUrlEdited = false;   // true once the operator types in the Site URL field

// Friendly labels for the per-domain keys - the table headers and the edit row
// use these instead of the raw conf key names (site_url, nav_file, ...).
var LABELS = {
  content_root: 'Content folder', site_url: 'Site address', site_name: 'Site title',
  theme: 'Theme', layout: 'Layout', appearance: 'Appearance (layout & theme)',
  nav_file: 'Navigation menu', search_default: 'Search',
  allowed_groups: 'Groups allowed to manage', locked_users: 'Users locked to this domain'
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
// SM167: layout and theme are ONE choice - a theme always belongs to a layout,
// so a theme-without-layout is meaningless. APPEARANCE holds the installed
// { layout, theme } pairs; the value "layout|theme" carries both.
var APPEARANCE = [];   // [{ layout, theme }]
function appearanceSelect(id, curLayout, curTheme) {
  var cur = (curLayout || '') + '|' + (curTheme || '');
  var html = '<select id="' + esc(id) + '"><option value="">Inherit the default</option>';
  APPEARANCE.forEach(function (a) {
    var val = a.layout + '|' + a.theme;
    html += '<option value="' + esc(val) + '"' + (val === cur ? ' selected' : '') + '>'
          + esc(a.layout + ' / ' + a.theme) + '</option>';
  });
  return html + '</select>';
}
// Split an appearance value into { layout, theme } (both '' when inheriting).
function splitAppearance(v) {
  var p = (v || '').split('|');
  return { layout: p[0] || '', theme: p[1] || '' };
}

function loadThemes() {
  // themes-list-all returns every installed theme with the layout it belongs to.
  return fetch(API + '?action=themes-list-all', { credentials: 'same-origin' })
    .then(function (r) { return r.json(); })
    .then(function (d) {
      if (!d || !d.ok) return;
      var seen = {};
      (d.themes || []).forEach(function (t) {
        if (!t.name || !t.layout) return;
        var key = t.layout + '|' + t.name;
        if (!seen[key]) { seen[key] = 1; APPEARANCE.push({ layout: t.layout, theme: t.name }); }
      });
      APPEARANCE.sort(function (a, b) {
        return (a.layout + '/' + a.theme).localeCompare(b.layout + '/' + b.theme);
      });
      var sel = document.getElementById('f-appearance');   // populate the add-form select
      if (sel) {
        APPEARANCE.forEach(function (a) {
          var o = document.createElement('option');
          o.value = a.layout + '|' + a.theme; o.textContent = a.layout + ' / ' + a.theme;
          sel.appendChild(o);
        });
      }
    })
    .catch(function () {});
}
function loadLayouts() { return Promise.resolve(); }   // folded into loadThemes (appearance pairs)

// Columns shown in the domains table - a curated set, so the table stays narrow
// and never runs off the page. Every editable key still appears in the inline
// edit row (EDIT_KEYS) below.
var DISPLAY_KEYS = ['content_root', 'site_name', 'theme'];
// Every per-domain key an existing domain can override, so the edit row is the
// superset of the add form (SM174 - content_root was settable at creation but
// not afterwards, leaving a wrong folder unfixable except by re-adding). The
// backend (domain_set / _clean_content_root) validates content_root the same way
// as at creation, so repointing is safe; it does not move existing files.
// SM167: theme + layout are edited as one 'appearance' field (a layout/theme
// pair); saveDomain splits it back into the two conf keys.
var EDIT_KEYS = ['content_root', 'site_url', 'site_name', 'appearance', 'nav_file', 'search_default',
  'allowed_groups', 'locked_users', 'lang', 'lang_group'];
// The edit panel groups the keys into labelled sections so it reads top-to-bottom
// like the Add form, rather than one ragged row of mixed-width fields.
var EDIT_SECTIONS = [
  { title: 'Identity',     note: '',                                  keys: ['content_root'] },
  { title: 'Presentation', note: 'optional – inherits the default',   keys: ['site_url', 'site_name', 'appearance', 'nav_file', 'search_default'] },
  { title: 'Language',     note: 'for a multilingual set',            keys: ['lang', 'lang_group'] },
  { title: 'Access',       note: 'who may manage this domain',        keys: ['allowed_groups', 'locked_users'] }
];
// Optional grey hint rendered under an edit field where the effect is not obvious.
var EDIT_HINTS = {
  content_root: 'Blank serves the default site. Changing this repoints the domain to another folder – it does not move existing files.',
  lang: 'This host’s language (e.g. en, fr, pt-BR). Sets <html lang> and the Content-Language header.',
  lang_group: 'The language set this host belongs to (a shared name across the languages, e.g. providers). Two+ hosts sharing it become a switchable set.',
  allowed_groups: 'Add the groups whose members may manage this domain (and are confined to it). None = only operators.',
  locked_users: 'Add accounts that can reach ONLY this domain (of the ones their groups allow) – nothing else.'
};
// Keys whose value comes from a fixed set are edited as a <select> (with an
// "inherit" blank), not a free-text box - matching the processor's own config UI
// (SM174). search_default is a true/false choice there, so it is here too.
var EDIT_OPTIONS = {
  search_default: ['true', 'false']
};

// SM165 access fields are lists of existing principals, edited with the SAME
// token-picker widget the Groups and Users pages use - a datalist-backed input +
// Add button, with removable pills - so the group/user UI is consistent
// everywhere. allowed_groups picks from the site's groups; locked_users from its
// accounts. PRINCIPALS feeds the two shared datalists.
var PICK_KEYS = { allowed_groups: 'groups', locked_users: 'users' };
var PRINCIPALS = { users: [], groups: [] };
function loadPrincipals() {
  return fetch(API + '?action=principals', { credentials: 'same-origin' })
    .then(function (r) { return r.json(); })
    .then(function (d) {
      if (d && d.ok) {
        PRINCIPALS.users = d.users || [];
        PRINCIPALS.groups = d.groups || [];
        fillDatalist('dom-groups-list', PRINCIPALS.groups);
        fillDatalist('dom-users-list', PRINCIPALS.users);
      }
    })
    .catch(function () {});
}
function fillDatalist(id, items) {
  var dl = document.getElementById(id);
  if (dl) dl.innerHTML = (items || []).map(function (v) { return '<option value="' + esc(v) + '">'; }).join('');
}
function tokenPill(v) {
  return '<span class="mg-token" data-val="' + esc(v) + '">' + esc(v)
    + '<button type="button" class="mg-token-x" title="Remove ' + esc(v) + '" onclick="this.parentNode.remove()">&times;</button></span>';
}
// The token picker for one access key: current members as removable pills + a
// datalist-backed input and Add button. The .mg-tokens container is id
// e-<host>-<key>, so saveDomain reads the chosen values from its pills.
function tokenPicker(host, k, currentCsv) {
  var chosen = (currentCsv || '').split(',').map(function (v) { return v.trim(); }).filter(Boolean);
  var listId = PICK_KEYS[k] === 'groups' ? 'dom-groups-list' : 'dom-users-list';
  var noun = PICK_KEYS[k] === 'groups' ? 'a group' : 'a user';
  var pills = chosen.length ? chosen.map(tokenPill).join('') : '<span class="mg-tokens-empty">None yet.</span>';
  return '<div class="mg-tokens" id="e-' + esc(host) + '-' + esc(k) + '">' + pills + '</div>'
    + '<div class="mg-tokens-pick">'
    + '<input list="' + listId + '" class="mg-inp" style="max-width:14rem" placeholder="add ' + noun + '&hellip;"'
    + ' onkeydown="if(event.key===\'Enter\'){addToken(this);event.preventDefault();}">'
    + ' <button type="button" class="mg-btn mg-btn-sm mg-btn-primary" onclick="addToken(this.previousElementSibling)">Add</button></div>';
}
function addToken(input) {
  var name = (input.value || '').trim();
  if (!name) return;
  var box = input.closest('.mg-tokens-pick').previousElementSibling;
  var dup = Array.prototype.some.call(box.querySelectorAll('.mg-token'), function (t) { return t.getAttribute('data-val') === name; });
  var empty = box.querySelector('.mg-tokens-empty'); if (empty) empty.remove();
  if (!dup) box.insertAdjacentHTML('beforeend', tokenPill(name));
  input.value = '';
}

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
  var ap = splitAppearance(document.getElementById('f-appearance').value);
  post('domain-add', {
    host: host,
    content_root: document.getElementById('f-croot').value.trim(),   // empty = default site
    site_url: document.getElementById('f-siteurl').value.trim(),
    site_name: document.getElementById('f-sitename').value.trim(),
    theme: ap.theme,
    layout: ap.layout,
    lang: document.getElementById('f-lang').value.trim(),
    lang_group: document.getElementById('f-lang-group').value.trim(),
    seed: document.getElementById('f-seed').checked ? 1 : 0
  }).then(function (d) {
    if (d && d.ok) { showStatus('Registered ' + host); toggleAdd(); loadDomains(); }
    else { showStatus((d && d.error) || 'Could not register the domain.', true); }
  });
}


function removeDomain(host) {
  if (!window.confirm('Delete ' + host + '? The domain is de-registered; its content files are kept.')) return;
  post('domain-remove', { host: host }).then(function (d) {
    if (d && d.ok) { showStatus('Deleted ' + host); loadDomains(); }
    else { showStatus((d && d.error) || 'Could not delete the domain.', true); }
  });
}

// SM183: package this domain's site (content + nav + referenced theme/layout +
// presentation, no secrets) into a portable .tar.gz. It lands under "Site
// packages" on the Backups page, to download, apply or hand to a client. The
// server gates this on manage_domains + scope access to the content root.
function exportSite(host) {
  showStatus('Packaging ' + host + '…');
  post('site-backup-create', { host: host }).then(function (d) {
    if (d && d.ok) {
      showStatus('Exported ' + host + ' → ' + d.name
        + '. Open the Backups page (Site packages) to download or apply it.');
    } else {
      showStatus((d && d.error) || 'Could not export the site.', true);
    }
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
  var setKey = function (key, value) {
    chain = chain.then(function () { return post('domain-set', { host: host, key: key, value: value }); });
  };
  EDIT_KEYS.forEach(function (k) {
    var inp = document.getElementById('e-' + host + '-' + k);
    if (!inp) return;
    changed++;
    if (PICK_KEYS[k]) {
      // Token picker: the comma-list is the pills in the container.
      var picked = [];
      Array.prototype.forEach.call(inp.querySelectorAll('.mg-token'), function (t) { picked.push(t.getAttribute('data-val')); });
      setKey(k, picked.join(','));
    } else if (k === 'appearance') {
      // One field, two conf keys: split "layout|theme" and write both.
      var ap = splitAppearance(inp.value);
      setKey('layout', ap.layout);
      setKey('theme', ap.theme);
    } else {
      setKey(k, inp.value.trim());
    }
  });
  chain.then(function () {
    if (changed) { showStatus('Saved ' + host); loadDomains(); }
  });
}

// One inline edit field: friendly label, the domain's OWN value pre-filled; an
// inherited value is shown as a greyed placeholder so the current effective
// value is always visible without overwriting the inherit. Each field fills its
// grid cell (width:100%) so columns line up regardless of content.
function editField(host, k, row) {
  var own = row[k + '_inherited'] ? '' : (row[k] || '');
  var effective = row[k] || '';
  var hint = EDIT_HINTS[k]
    ? '<span style="font-weight:400;color:#999;font-size:0.92em;margin-top:2px;">' + esc(EDIT_HINTS[k]) + '</span>'
    : '';
  var full = 'width:100%;box-sizing:border-box;';
  var wrap = function (inner, span) {
    // A field cell: label above, control below. `span` makes a wide control (the
    // tick-lists) claim the full grid width so it doesn't squeeze the columns.
    return '<label style="display:flex;flex-direction:column;gap:3px;font-size:0.85em;color:#555;'
      + (span ? 'grid-column:1/-1;' : '') + '">'
      + '<span style="font-weight:600;color:#444;">' + esc(label(k)) + '</span>'
      + inner + hint + '</label>';
  };

  // SM165 access keys: the shared token picker, not a text box.
  if (PICK_KEYS[k]) {
    return wrap(tokenPicker(host, k, own), true);
  }
  var field;
  if (k === 'appearance') {
    var curLayout = row.layout_inherited ? '' : (row.layout || '');
    var curTheme  = row.theme_inherited  ? '' : (row.theme  || '');
    // appearanceSelect builds a <select id=...>; widen it to fill the cell.
    field = appearanceSelect('e-' + host + '-appearance', curLayout, curTheme)
      .replace('<select ', '<select style="' + full + '" ');
  } else if (EDIT_OPTIONS[k]) {
    var blank = (row[k + '_inherited'] && effective)
      ? 'Inherit the default (' + effective + ')' : 'Inherit the default';
    var opts = '<option value="">' + esc(blank) + '</option>';
    EDIT_OPTIONS[k].forEach(function (o) {
      opts += '<option value="' + esc(o) + '"' + (o === own ? ' selected' : '') + '>' + esc(o) + '</option>';
    });
    field = '<select id="e-' + esc(host) + '-' + esc(k) + '" style="' + full + '">' + opts + '</select>';
  } else {
    var ph = (row[k + '_inherited'] && effective)
      ? ' placeholder="' + esc(effective) + ' (inherited)"' : '';
    field = '<input id="e-' + esc(host) + '-' + esc(k) + '" value="' + esc(own) + '"' + ph + ' style="' + full + '">';
  }
  return wrap(field, false);
}

// The fields of one edit section, laid out in an aligned responsive grid.
function editSection(host, section, row) {
  var cells = section.keys.map(function (k) { return editField(host, k, row); }).join('');
  var note = section.note
    ? ' <span style="text-transform:none;letter-spacing:0;font-weight:400;color:#aaa;">&mdash; ' + esc(section.note) + '</span>'
    : '';
  return '<div style="margin-top:12px;">'
    + '<div style="font-size:0.72em;color:#999;text-transform:uppercase;letter-spacing:0.05em;margin-bottom:6px;">'
    + esc(section.title) + note + '</div>'
    + '<div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:12px 16px;align-items:start;">'
    + cells + '</div></div>';
}

// The last-loaded domain rows, so the Add form can pre-fill from an existing one.
var DOMAINS = [];
// "Copy settings from": pre-fill the Add form from an existing domain's OWN
// values (a create-time convenience - once created the new domain is unrelated).
function cloneFrom(host) {
  if (!host) return;
  var src = null;
  for (var i = 0; i < DOMAINS.length; i++) { if (DOMAINS[i].host === host) { src = DOMAINS[i]; break; } }
  if (!src) return;
  var own = function (k) { return src[k + '_inherited'] ? '' : (src[k] || ''); };
  var setV = function (id, v) { var e = document.getElementById(id); if (e) e.value = v || ''; };
  setV('f-croot', own('content_root'));
  setV('f-sitename', own('site_name'));
  var ap = document.getElementById('f-appearance');
  if (ap) { var lay = own('layout'), th = own('theme'); ap.value = (lay || th) ? (lay + '|' + th) : ''; }
  setV('f-lang', own('lang'));
  setV('f-lang-group', own('lang_group'));
  // site_url is intentionally NOT copied - the new host gets its own address.
}

function loadDomains() {
  fetch(API + '?action=domains-list', { credentials: 'same-origin' })
    .then(function (r) { return r.json(); })
    .then(function (d) {
      var listEl = document.getElementById('domains-list');
      if (!d || !d.ok) { listEl.innerHTML = '<div class="mg-status">Could not load domains.</div>'; return; }
      var rows = d.domains || [];
      DOMAINS = rows;    // for the Add form's "Copy settings from" pre-fill
      var cf = document.getElementById('f-clone-from');
      if (cf) {
        var opts = '<option value="">Start blank</option>';
        rows.forEach(function (r) { if (!r.is_primary) opts += '<option value="' + esc(r.host) + '">' + esc(r.host) + '</option>'; });
        cf.innerHTML = opts;
      }
      // Table scrolls inside its own box (overflow-x) so a wide row never pushes
      // the page sideways; the column set is curated (DISPLAY_KEYS) to stay slim.
      var html = '<div style="overflow-x:auto;"><table class="mg-file-table" style="min-width:0;"><thead><tr><th>Domain</th>';
      DISPLAY_KEYS.forEach(function (k) { html += '<th>' + esc(label(k)) + '</th>'; });
      html += '<th>Actions</th></tr></thead><tbody>';
      rows.forEach(function (row) {
        if (row.is_primary) return;   // the default site lives in Site settings, not this list
        html += '<tr><td class="mg-file-name"><strong>' + esc(row.host) + '</strong></td>';
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
        // Actions folded into a per-row dropdown (Edit + the domain actions) so
        // the row stays uncluttered; it expands inline (no clipping inside the
        // table's overflow-x box).
        html += '<td><details class="mg-rowmenu"><summary class="mg-btn mg-btn-sm">Actions &#9662;</summary>'
              + '<div class="mg-rowmenu-items">'
              + '<button class="mg-btn mg-btn-sm" onclick="editDomain(' + esc(JSON.stringify(row.host)) + ')">Edit</button>'
              + '<button class="mg-btn mg-btn-sm" onclick="previewDomain(' + esc(JSON.stringify(row.host)) + ')">Preview</button>'
              + '<button class="mg-btn mg-btn-sm" onclick="checkDomain(' + esc(JSON.stringify(row.host)) + ')">Check</button>'
              + (row.content_root ? '<button class="mg-btn mg-btn-sm" onclick="exportSite(' + esc(JSON.stringify(row.host)) + ')">Export site</button>' : '')
              + '<button class="mg-btn mg-btn-sm mg-btn-danger" onclick="removeDomain(' + esc(JSON.stringify(row.host)) + ')">Delete</button>'
              + '</div></details></td></tr>';
        // Hidden inline edit panel - sectioned (Identity / Presentation /
        // Access), each a grid of aligned fields (editSection/editField).
        html += '<tr id="edit-' + esc(row.host) + '" style="display:none"><td colspan="' + (DISPLAY_KEYS.length + 2) + '">'
              + '<div style="background:var(--mg-panel,#fafafa);border:1px solid var(--mg-border,#e2e2e2);border-radius:6px;padding:14px 16px;max-width:760px;">'
              + '<div style="font-size:0.9em;font-weight:600;color:#444;border-bottom:1px solid var(--mg-border,#e2e2e2);padding-bottom:8px;margin-bottom:4px;">Edit ' + esc(row.host) + '</div>';
        EDIT_SECTIONS.forEach(function (s) { html += editSection(row.host, s, row); });
        html += '<div style="margin-top:16px;">'
              + '<button class="mg-btn mg-btn-sm mg-btn-primary" onclick="saveDomain(' + esc(JSON.stringify(row.host)) + ')">Save changes</button>'
              + '</div></div></td></tr>';
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

// SM156: the server's public IP(s) - stored as the canonical_ip config key,
// read/written like any config value. Used by Check when this server is behind
// a proxy/NAT and can't self-discover its public address.
function loadCanonicalIp() {
  return fetch(API + '?action=config-read', { credentials: 'same-origin' })
    .then(function (r) { return r.json(); })
    .then(function (d) {
      if (d && d.ok && d.config) { document.getElementById('f-canonical-ip').value = d.config.canonical_ip || ''; }
    })
    .catch(function () {});
}
function saveCanonicalIp() {
  var v = document.getElementById('f-canonical-ip').value.trim();
  post('config-set', { key: 'canonical_ip', value: v }).then(function (d) {
    if (d && d.ok) { showStatus('Saved this server’s public IP'); }
    else { showStatus((d && d.error) || 'Could not save the IP.', true); }
  });
}

// SM179 P6: translation coverage for a language set. Read-only; the panel stays
// hidden unless this instance actually has a set (two+ hosts sharing a
// lang_group). Each non-source root shows its current / stale / missing counts
// so an operator sees at a glance what still needs translating.
function coverageBar(root) {
  var total = root.total || 0;
  var seg = function (n, colour, title) {
    if (!n) return '';
    var pct = total ? (n / total * 100) : 0;
    return '<span title="' + title + ': ' + n + '" style="display:inline-block;height:100%;width:' + pct + '%;background:' + colour + ';"></span>';
  };
  return '<span style="display:inline-flex;height:9px;width:120px;border-radius:4px;overflow:hidden;background:#eee;vertical-align:middle;">'
       + seg(root.current, '#2e9e50', 'current')
       + seg(root.stale, '#d99a20', 'stale')
       + seg(root.missing, '#cccccc', 'missing')
       + '</span>';
}
function loadLangStatus() {
  var box = document.getElementById('lang-coverage');
  return fetch(API + '?action=lang-status', { credentials: 'same-origin' })
    .then(function (r) { return r.json(); })
    .then(function (d) {
      if (!d || !d.ok || !d.members || d.members < 2) { box.style.display = 'none'; return; }
      var s = d.source || {};
      var html = '<h2 style="font-size:1.05em;margin:0 0 4px;">Language coverage</h2>'
        + '<p style="font-size:0.82em;color:#888;margin:0 0 10px;">'
        + 'This is a language set (group <code>' + esc(d.group) + '</code>). The source is <strong>'
        + esc(s.lang || '?') + '</strong> with ' + (s.files || 0) + ' page(s). '
        + 'Each other language is compared to it &mdash; '
        + '<span style="color:#2e9e50">current</span>, '
        + '<span style="color:#d99a20">stale</span> (source changed since translating) or '
        + '<span style="color:#999">missing</span>. Translate the sibling root at the same path to fill gaps.</p>';
      html += '<div style="overflow-x:auto;"><table class="mg-file-table" style="min-width:0;"><thead><tr>'
        + '<th>Language</th><th>Host</th><th>Coverage</th><th>Current</th><th>Stale</th><th>Missing</th></tr></thead><tbody>';
      (d.roots || []).forEach(function (root) {
        html += '<tr><td><strong>' + esc(root.lang || '?') + '</strong></td>'
          + '<td>' + esc(root.host || '') + '</td>'
          + '<td>' + coverageBar(root) + '</td>'
          + '<td>' + (root.current || 0) + '</td>'
          + '<td' + (root.stale ? ' style="color:#d99a20;font-weight:600"' : '') + '>' + (root.stale || 0) + '</td>'
          + '<td' + (root.missing ? ' style="color:#b00;font-weight:600"' : '') + '>' + (root.missing || 0) + '</td>'
          + '</tr>';
      });
      html += '</tbody></table></div>';
      box.innerHTML = html;
      box.style.display = '';
    })
    .catch(function () { box.style.display = 'none'; });
}

Promise.all([loadThemes(), loadLayouts(), loadCanonicalIp(), loadPrincipals()]).then(loadDomains).then(loadLangStatus);
</script>
