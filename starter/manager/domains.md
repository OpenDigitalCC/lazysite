---
title: Domains
auth: manager
search: false
---

<style>
/* SM144-style config sheet reuses the shared .mg-sheet / .mg-box machinery from
   manager.css (same as the Users page). The domain editor sections keep their
   own grid layout, so a small scope wrapper is all that is added here. */
.mg-dom-chip { display:inline-block; font-size:0.72em; padding:0.05em 0.5em; border-radius:999px;
  background:var(--mg-surface-alt,#f0f0f0); color:var(--mg-text-muted,#777); margin-left:6px; vertical-align:middle; }
.mg-dom-tools { display:flex; flex-wrap:wrap; gap:8px; align-items:center; }
</style>

<div id="status" class="mg-status"></div>

<p style="font-size:0.85em;color:#888;margin:0 0 12px;">
Your site is always served at its default address. This page is for the
<strong>additional domains</strong> you serve from this one instance. Each can be
a first&#8209;class site &mdash; its own home page, sitemap, feeds and search &mdash;
by giving it a content folder; or it can mirror your default site. Point
DNS, the web&#8209;server domain alias and TLS at this server first (your
control&#8209;panel / Hestia's job &mdash; a wildcard record + wildcard
certificate covers every sub&#8209;domain at once), then configure the lazysite
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
  <button class="mg-btn" onclick="openCreateSheet()">Add domain</button>
</div>


<div id="domains-list"><div class="mg-status">Loading&hellip;</div></div>

<div id="lang-coverage" style="display:none;margin-top:22px;"></div>

<!-- The full-width domain editor sheet (Users-style, SM144). One consistent
     surface for configuring ANY domain, opened by a row's Configure button - the
     same size and position for every domain. A coloured header names the domain.
     Click the backdrop or press Esc to close. -->
<div id="cfg-sheet" class="mg-sheet" hidden onclick="if(event.target===this)closeConfig()">
  <div class="mg-sheet-panel" role="dialog" aria-modal="true" aria-label="Domain settings" tabindex="-1">
    <div class="mg-sheet-head">
      <span id="cfg-sheet-title" class="mg-sheet-title"></span>
      <button type="button" class="mg-sheet-close" onclick="closeConfig()" aria-label="Close settings">&times;</button>
    </div>
    <div class="mg-sheet-body" id="cfg-sheet-body"></div>
  </div>
</div>


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
      // SM259: nothing to populate eagerly - the create sheet builds its
      // appearance <select> from APPEARANCE via appearanceSelect() each time it
      // opens, so it always reflects what is installed now.
    })
    .catch(function () {});
}
function loadLayouts() { return Promise.resolve(); }   // folded into loadThemes (appearance pairs)

// Columns shown in the domains table - a curated set, so the table stays narrow
// and never runs off the page. Every editable key appears in the config sheet
// (EDIT_KEYS) below.
var DISPLAY_KEYS = ['content_root', 'site_name', 'theme'];
// Every per-domain key an existing domain can override, so the editor is the
// superset of the add form (SM174 - content_root was settable at creation but
// not afterwards, leaving a wrong folder unfixable except by re-adding). The
// backend (domain_set / _clean_content_root) validates content_root the same way
// as at creation, so repointing is safe; it does not move existing files.
// SM167: theme + layout are edited as one 'appearance' field (a layout/theme
// pair); saveDomain splits it back into the two conf keys.
var EDIT_KEYS = ['content_root', 'site_url', 'site_name', 'appearance', 'nav_file', 'search_default',
  'allowed_groups', 'locked_users', 'lang', 'lang_group'];
// The editor groups the keys into labelled sections so the sheet reads
// top-to-bottom like the Add form, rather than one ragged row of mixed-width
// fields. Identity holds the site address / title / content folder; Presentation
// the appearance + nav + search; then Access and Language.
var EDIT_SECTIONS = [
  { title: 'Identity',     note: '',                                  keys: ['site_url', 'site_name', 'content_root'] },
  { title: 'Presentation', note: 'optional – inherits the default',   keys: ['appearance', 'nav_file', 'search_default'] },
  { title: 'Access',       note: 'who may manage this domain',        keys: ['allowed_groups', 'locked_users'] },
  { title: 'Language',     note: 'for a multilingual set',            keys: ['lang', 'lang_group'] }
];
// Optional grey hint rendered under an edit field where the effect is not obvious.
var EDIT_HINTS = {
  content_root: 'Blank serves the default site. Changing this repoints the domain to another folder – it does not move existing files.',
  site_name: 'Shown in the page header and the browser tab.',
  appearance: 'A theme always belongs to a layout, so pick them together.',
  lang: 'This host’s language (e.g. en, fr, pt-BR). Sets <html lang> and the Content-Language header.',
  lang_group: 'The language set this host belongs to (a shared name across the languages, e.g. providers). Two+ hosts sharing it become a switchable set.',
  allowed_groups: 'Add the groups whose members may manage this domain (and are confined to it). None = only operators.',
  locked_users: 'Add accounts that can reach ONLY this domain (of the ones their groups allow) – nothing else.'
};
// SM259: two hints read differently when the domain does not exist yet - a
// content folder is CREATED rather than repointed, and the site URL is derived
// from the host as you type. Overlaid on EDIT_HINTS in create mode rather than
// compromising one string to serve both.
var CREATE_HINTS = {
  content_root: 'The folder inside your site holding this domain’s pages – created if missing. Leave empty to serve your default site. The lazysite system area is reserved; pick any other folder.',
  site_url: 'Filled in automatically from the domain name. Change it only if visitors reach this site on a different address.'
};

// Keys whose value comes from a fixed set are edited as a <select> (with an
// "inherit" blank), not a free-text box - matching the processor's own config UI
// (SM174). search_default is a true/false choice there, so it is here too.
var EDIT_OPTIONS = {
  search_default: ['true', 'false']
};

// SM165 access fields are lists of existing principals, edited with the SAME
// token-picker widget the Groups and Users pages use - the shared principal
// <select> (SM305) + Add button, with removable pills - so the group/user UI is
// consistent everywhere. allowed_groups picks from the site's groups;
// locked_users from its accounts. PRINCIPALS feeds the shared picker.
var PICK_KEYS = { allowed_groups: 'groups', locked_users: 'users' };
var PRINCIPALS = { users: [], groups: [] };
function loadPrincipals() {
  return fetch(API + '?action=principals', { credentials: 'same-origin' })
    .then(function (r) { return r.json(); })
    .then(function (d) {
      if (d && d.ok) {
        PRINCIPALS.users = d.users || [];
        PRINCIPALS.groups = d.groups || [];
        // SM305: one source for every picker on the page.
        if (window.mgSetPrincipals) mgSetPrincipals(PRINCIPALS.users, PRINCIPALS.groups);
      }
    })
    .catch(function () {});
}
function tokenPill(v) {
  return '<span class="mg-token" data-val="' + esc(v) + '">' + esc(v)
    + '<button type="button" class="mg-token-x" title="Remove ' + esc(v) + '" onclick="this.parentNode.remove()">&times;</button></span>';
}
// The token picker for one access key: current members as removable pills + the
// shared principal <select> and an Add button. The .mg-tokens container is id
// e-<host>-<key>, so saveDomain reads the chosen values from its pills.
function tokenPicker(host, k, currentCsv) {
  var chosen = (currentCsv || '').split(',').map(function (v) { return v.trim(); }).filter(Boolean);
  var kind = PICK_KEYS[k] === 'groups' ? 'groups' : 'users';
  var noun = kind === 'groups' ? 'a group' : 'a user';
  var pills = chosen.length ? chosen.map(tokenPill).join('') : '<span class="mg-tokens-empty">None yet.</span>';
  // SM305: the shared <select>, not a datalist-backed input. A typo here is
  // costly in a way the Groups page's is not - a misspelt name in
  // allowed_groups leaves a domain that nobody can manage, and the control
  // accepted anything typed while looking as though it did not.
  return '<div class="mg-tokens" id="e-' + esc(host) + '-' + esc(k) + '">' + pills + '</div>'
    + '<div class="mg-tokens-pick">'
    + mgPrincipalSelect({ only: kind, groupPrefix: '',
                          placeholder: 'add ' + noun + '…',
                          style: 'max-width:14rem' })
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


function removeDomain(host) {
  if (!window.confirm('Delete ' + host + '? The domain configuration is removed; its content files are kept.')) return;
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

// --- The full-width domain editor sheet (Users-style, SM144) ---------------
// One consistent surface for configuring a domain, the same size and position
// for every host. Driven by whichever Configure button was pressed. Only one
// domain's controls exist in the DOM at a time, so the per-field ids (e-<host>-*)
// stay unique - exactly as the inline edit row relied on.
var DOMAINS_BY_HOST = {};       // host -> row, refreshed each render
var currentConfigHost = null;   // host whose sheet is open (null = closed)

// Wrap a sheet section in a bounded box with an uppercase heading, matching the
// Users editor's sec() helper (uses the shared .mg-box / .mg-sec classes).
function sec(title, inner) {
  return '<div class="mg-box"><div class="mg-sec">' + title + '</div>' + inner + '</div>';
}

// Open the editor sheet for a domain, or toggle it shut if already open.
function configureDomain(host) {
  if (currentConfigHost === host) { closeConfig(); return; }
  currentConfigHost = host;
  renderConfigSheet(host);
}

// The body of the sheet: the grouped sections (Identity / Presentation / Access
// / Language) built from the SHARED editSection/editField, plus a Tools footer
// with the domain actions. This is a RE-HOST of the proven inline editor into one
// modal - the field machinery, validation, token picker and datalists are unchanged.
// Each section is boxed (mg-box) to match the Users sheet's card look.
// SM259: the pseudo-host the create sheet uses for its field ids, so editField
// and the token pickers work unchanged. Deliberately a shape no real host can
// take (a hostname cannot contain underscores at the edges or be bracketed like
// this), so it can never collide with a domain being configured.
var NEW_HOST = '__new__';

function domainSettingsHtml(row, isCreate) {
  var host = row.host;
  var h = '';

  // SM259: creating and configuring are the same object described twice, so the
  // sheet renders both from ONE set of sections. Only the create-only parts
  // differ: the host itself (fixed once the domain exists), a starting point to
  // copy from, and whether to seed a home page.
  if (isCreate) {
    var opts = '<option value="">Start blank</option>';
    DOMAINS.forEach(function (d) {
      if (d.host && d.host !== '(default)') {
        opts += '<option value="' + esc(d.host) + '">' + esc(d.host) + '</option>';
      }
    });
    h += '<div class="mg-box"><div style="font-size:0.72em;color:#999;text-transform:uppercase;letter-spacing:0.05em;margin-bottom:6px;">New domain</div>'
      + '<div style="display:grid;grid-template-columns:repeat(auto-fill,minmax(220px,1fr));gap:12px 16px;align-items:start;">'
      + '<label style="display:flex;flex-direction:column;gap:3px;font-size:0.85em;color:#555;">'
      + '<span style="font-weight:600;color:#444;">Full domain name</span>'
      + '<input id="e-' + esc(NEW_HOST) + '-host" placeholder="clienta.com" style="width:100%;box-sizing:border-box;" oninput="onNewHostInput()">'
      + '<span style="font-weight:400;color:#999;font-size:0.92em;margin-top:2px;">The complete hostname visitors type – e.g. clienta.com or shop.clienta.com. Must be unique in this instance.</span>'
      + '</label>'
      + '<label style="display:flex;flex-direction:column;gap:3px;font-size:0.85em;color:#555;">'
      + '<span style="font-weight:600;color:#444;">Copy settings from</span>'
      + '<select id="e-' + esc(NEW_HOST) + '-clone" onchange="cloneFrom(this.value)" style="width:100%;box-sizing:border-box;">' + opts + '</select>'
      + '<span style="font-weight:400;color:#999;font-size:0.92em;margin-top:2px;">Pre-fill from an existing domain – a quick way to stand up another like one you already have. You can change anything before saving.</span>'
      + '</label>'
      + '</div></div>';
  }

  EDIT_SECTIONS.forEach(function (s) {
    h += '<div class="mg-box">' + editSection(host, s, row, isCreate) + '</div>';
  });

  if (isCreate) {
    h += '<div class="mg-line" style="margin-top:4px;">'
      + '<button class="mg-btn mg-btn-primary" onclick="createDomain()">Configure domain</button> '
      + '<button class="mg-btn" onclick="closeConfig()">Cancel</button></div>';
    return h;
  }

  // Save is the primary action, sitting under the field groups.
  h += '<div class="mg-line" style="margin-top:4px;">'
     + '<button class="mg-btn mg-btn-primary" onclick="saveDomain(' + esc(JSON.stringify(host)) + ')">Save changes</button></div>';

  // --- Tools (a footer group): the domain actions as buttons. Export appears
  // only when a content folder is set (as before); Delete is the danger action,
  // set apart in its own row. ---
  var tools = '<div class="mg-dom-tools">'
    + '<button class="mg-btn mg-btn-sm" onclick="previewDomain(' + esc(JSON.stringify(host)) + ')">Preview</button>'
    + '<button class="mg-btn mg-btn-sm" onclick="checkDomain(' + esc(JSON.stringify(host)) + ')">Check</button>'
    + (row.content_root ? '<button class="mg-btn mg-btn-sm" onclick="exportSite(' + esc(JSON.stringify(host)) + ')">Export site</button>' : '')
    + '</div>';
  h += sec('Tools', tools);
  h += '<div class="mg-box mg-box-danger"><div class="mg-sec">Danger zone</div>'
     + '<div class="mg-line"><button class="mg-btn mg-btn-sm mg-btn-danger" onclick="removeDomain(' + esc(JSON.stringify(host)) + ')">Delete domain</button></div></div>';
  return h;
}

// (Re)fill the sheet for the open domain - also called after a reload so the
// editor reflects fresh data (a save reloads the list underneath).
function renderConfigSheet(host) {
  var row = DOMAINS_BY_HOST[host];
  if (!row) { closeConfig(); return; }
  var croot = row.content_root
    ? (row.content_root_inherited ? row.content_root + ' (inherited)' : row.content_root)
    : 'default site';
  document.getElementById('cfg-sheet-title').innerHTML =
    'Configuring ' + esc(host) + ' <span class="mg-sheet-sub">' + esc(croot) + '</span>';
  document.getElementById('cfg-sheet-body').innerHTML = domainSettingsHtml(row);
  var sheet = document.getElementById('cfg-sheet');
  sheet.hidden = false;
  document.body.classList.add('mg-sheet-open');
  var b = document.getElementById('cfg-sheet-body'); if (b) b.scrollTop = 0;
  // Move focus into the sheet so keyboard users land inside it (and Esc/Tab work
  // against the dialog, not the page behind).
  var panel = sheet.querySelector('.mg-sheet-panel');
  if (panel) { try { panel.focus(); } catch (e) {} }
  markConfiguring(host);
}

// SM259: open the SAME sheet in create mode. An empty row means every field
// renders blank with its inherit placeholder, exactly as a new domain inherits.
function openCreateSheet() {
  siteUrlEdited = false;
  document.getElementById('cfg-sheet-title').innerHTML =
    'Add a domain <span class="mg-sheet-sub">configures a new host on this instance</span>';
  document.getElementById('cfg-sheet-body').innerHTML =
    domainSettingsHtml({ host: NEW_HOST }, true);
  var sheet = document.getElementById('cfg-sheet');
  sheet.hidden = false;
  document.body.classList.add('mg-sheet-open');
  var b = document.getElementById('cfg-sheet-body'); if (b) b.scrollTop = 0;
  var panel = sheet.querySelector('.mg-sheet-panel');
  if (panel) { try { panel.focus(); } catch (e) {} }
  markConfiguring(null);
  var hf = document.getElementById('e-' + NEW_HOST + '-host');
  if (hf) {
    try { hf.focus(); } catch (e) {}
    // SM437: the folder is derived from the host, so the preview has to follow
    // it as it is typed - not only on submit, where a surprise is too late.
    hf.addEventListener('input', syncContentRoot);
  }
  loadFolderChoices();
  syncSeedVisible();
}

// Derive the site URL from the host as it is typed, until the operator edits it.
// SM259: show the seed option only while a content folder is named. Called on
// input, after the sheet opens, and after a clone pre-fills the box - a value
// that arrives without a keystroke must reveal it too.
function syncSeedVisible() {
  // SM437: under the picker the text box is hidden and empty, so asking IT
  // whether a folder was named would hide the seed option permanently. Ask
  // for the value that will actually be submitted.
  if (document.getElementById('e-' + NEW_HOST + '-cr-parent')) {
    var wrapEl = document.getElementById('seed-wrap');
    if (wrapEl) wrapEl.style.display = contentRootValue() ? 'block' : 'none';
    return;
  }
  var croot = document.getElementById('e-' + NEW_HOST + '-content_root');
  var wrap  = document.getElementById('seed-wrap');
  if (!wrap) return;
  wrap.style.display = (croot && croot.value.trim()) ? 'block' : 'none';
}

function onNewHostInput() {
  if (siteUrlEdited) return;
  var hf = document.getElementById('e-' + NEW_HOST + '-host');
  var uf = document.getElementById('e-' + NEW_HOST + '-site_url');
  if (!hf || !uf) return;
  var h = hf.value.trim();
  uf.value = h ? 'https://' + h : '';
}

// SM437: populate the parent-folder picker, and keep the derived path visible.
//
// The operator picks a parent that EXISTS; the child is named from the host and
// created if absent - which domain_add already does (make_path when missing,
// adopt when present), so no new behaviour is needed underneath.
function crParentSelect() { return document.getElementById('e-' + NEW_HOST + '-cr-parent'); }
function crHostValue() {
  var e = document.getElementById('e-' + NEW_HOST + '-host');
  return e ? e.value.trim().toLowerCase() : '';
}

// The value the form will actually submit. Derived, never typed - except under
// "Somewhere else…", where the operator has said they know better.
function contentRootValue() {
  var sel = crParentSelect();
  if (!sel) {
    var box = document.getElementById('e-' + NEW_HOST + '-content_root');
    return box ? box.value.trim() : '';
  }
  if (sel.value === '__custom') {
    var b = document.getElementById('e-' + NEW_HOST + '-content_root');
    return b ? b.value.trim() : '';
  }
  if (sel.value === '') return '';                    // serve the default site
  var h = crHostValue();
  return h ? (sel.value + '/' + h) : sel.value;
}

function syncContentRoot() {
  var sel = crParentSelect(); if (!sel) return;
  var custom = document.getElementById('cr-custom');
  var prev   = document.getElementById('cr-preview');
  if (custom) custom.style.display = (sel.value === '__custom') ? 'block' : 'none';
  if (prev) {
    var v = contentRootValue();
    prev.textContent = (sel.value === '')
      ? 'This domain will serve your default site.'
      : (v ? 'Folder: ' + v + (crHostValue() ? '  (created if it does not exist)' : '')
           : 'Enter the domain name above and this fills in.');
  }
  if (typeof syncSeedVisible === 'function') syncSeedVisible();
}

function loadFolderChoices() {
  var sel = crParentSelect(); if (!sel) return;
  fetch(API + '?action=list&path=/', { credentials: 'same-origin' })
    .then(function (r) { return r.json(); })
    .then(function (d) {
      var dirs = ((d && d.entries) || []).filter(function (e) {
        // lazysite/ is the system area and is never a content root.
        return e.type === 'dir' && e.name !== 'lazysite';
      }).map(function (e) { return e.name; });
      var opts = '<option value="">Serve the default site (no folder)</option>';
      dirs.forEach(function (n) {
        opts += '<option value="' + esc(n) + '"' + (n === 'sites' ? ' selected' : '') + '>'
             +  esc(n) + '/</option>';
      });
      opts += '<option value="__custom">Somewhere else…</option>';
      sel.innerHTML = opts;
      syncContentRoot();
    })
    .catch(function () {
      // If the listing cannot be read, fall back to the text box rather than
      // leaving a select that can only say "Loading…".
      sel.innerHTML = '<option value="__custom">Type a folder path</option>';
      sel.value = '__custom';
      syncContentRoot();
    });
}

function createDomain() {
  var v = function (k) {
    var e = document.getElementById('e-' + NEW_HOST + '-' + k);
    return e ? e.value.trim() : '';
  };
  var host = v('host');
  if (!host) { showStatus('A full domain name is required.', true); return; }
  var apEl = document.getElementById('e-' + NEW_HOST + '-appearance');
  var ap = splitAppearance(apEl ? apEl.value : '');
  var seedEl = document.getElementById('e-' + NEW_HOST + '-seed');
  post('domain-add', {
    host: host,
    content_root: contentRootValue(),  // SM437: derived from the picker + host
    site_url: v('site_url'),
    site_name: v('site_name'),
    theme: ap.theme,
    layout: ap.layout,
    nav_file: v('nav_file'),
    search_default: v('search_default'),
    lang: v('lang'),
    lang_group: v('lang_group'),
    seed: (seedEl && seedEl.checked) ? 1 : 0
  }).then(function (d) {
    if (d && d.ok) { showStatus("Configured " + host); closeConfig(); loadDomains(); }
    else { showStatus((d && d.error) || 'Could not configure the domain.', true); }
  });
}

function closeConfig() {
  currentConfigHost = null;
  var sheet = document.getElementById('cfg-sheet');
  if (sheet) sheet.hidden = true;
  var body = document.getElementById('cfg-sheet-body'); if (body) body.innerHTML = '';
  document.body.classList.remove('mg-sheet-open');
  markConfiguring(null);
}

// Highlight the Configure button of the domain whose sheet is open.
function markConfiguring(host) {
  var btns = document.querySelectorAll('.mg-configbtn');
  for (var i = 0; i < btns.length; i++) {
    btns[i].classList.toggle('active', !!host && btns[i].getAttribute('data-cfg') === host);
  }
}

// Esc closes the sheet (a click on the backdrop closes via the onclick above).
document.addEventListener('keydown', function (e) {
  if (e.key === 'Escape' && currentConfigHost) closeConfig();
});

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
function editField(host, k, row, isCreate) {
  var own = row[k + '_inherited'] ? '' : (row[k] || '');
  var effective = row[k] || '';
  var hintText = (isCreate && CREATE_HINTS[k]) ? CREATE_HINTS[k] : EDIT_HINTS[k];
  var hint = hintText
    ? '<span style="font-weight:400;color:#999;font-size:0.92em;margin-top:2px;">' + esc(hintText) + '</span>'
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
    // SM259: the create sheet's content-folder box drives the seed option's
    // visibility, so it needs a handler the edit sheet does not.
    var oi = (isCreate && k === 'content_root') ? ' oninput="syncSeedVisible()"' : '';
    field = '<input id="e-' + esc(host) + '-' + esc(k) + '" value="' + esc(own) + '"' + ph + oi + ' style="' + full + '">';

    // SM437: on the CREATE sheet the content folder is CHOSEN, not typed.
    //
    // Every domain on the estate is sites/<hostname>, retyped by hand each
    // time. A field whose correct value is derivable from another field on
    // the same form should not be typed: the parent comes from a list of
    // folders that exist, and the child is named from the host.
    //
    // The failure it removes is quiet. domain_add accepts any clean relative
    // path and provisions it, so a typo produces a domain pointing at a new
    // EMPTY directory - the site serves, with nothing in it, and the intended
    // content sits one directory away under the name that was meant. The
    // typo'd path is perfectly valid, which is why nothing catches it and why
    // the remedy is to stop asking for it rather than to check it harder.
    //
    // The text box is kept behind "Somewhere else…" rather than removed: an
    // operator with a layout the convention does not cover must not be stuck,
    // and the picker is a default, not a cage.
    if ( isCreate && k === 'content_root' ) {
      field = '<select id="e-' + esc(host) + '-cr-parent" style="' + full + '"'
            + ' onchange="syncContentRoot()">'
            + '<option value="">Loading folders…</option></select>'
            + '<div id="cr-preview" style="margin-top:4px;font-size:0.85em;color:#666;"></div>'
            + '<div id="cr-custom" style="display:none;margin-top:4px;">' + field + '</div>';
    }
  }
  // SM259 (operator, 0.10.4 validation): the seed option is conditional on the
  // content folder, and its own label was doing the explaining that proximity
  // and conditional display should do - "(only when a content folder is given)".
  // So it lives INSIDE that field and appears only once the box has a value. A
  // field whose relevance is conditional reads better next to its condition, and
  // hidden entirely when it does not apply.
  if ( isCreate && k === 'content_root' ) {
    var seedHidden = ' style="display:none;margin-top:6px;font-size:0.85em;color:#555;"';
    return wrap(
      field
        + '<label id="seed-wrap"' + seedHidden + '>'
        + '<input type="checkbox" id="e-' + esc(NEW_HOST) + '-seed" checked> '
        + 'Seed a starter home page in this folder</label>',
      false );
  }

  return wrap(field, false);
}

// The fields of one edit section, laid out in an aligned responsive grid.
function editSection(host, section, row, isCreate) {
  var cells = section.keys.map(function (k) { return editField(host, k, row, isCreate); }).join('');
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
  // SM259: the create sheet's fields, not the retired add panel's.
  var setV = function (k, v) {
    var e = document.getElementById('e-' + NEW_HOST + '-' + k);
    if (e) e.value = v || '';
  };
  setV('content_root', own('content_root'));
  setV('site_name', own('site_name'));
  setV('nav_file', own('nav_file'));
  setV('search_default', own('search_default'));
  var ap = document.getElementById('e-' + NEW_HOST + '-appearance');
  if (ap) { var lay = own('layout'), th = own('theme'); ap.value = (lay || th) ? (lay + '|' + th) : ''; }
  setV('lang', own('lang'));
  setV('lang_group', own('lang_group'));
  syncSeedVisible();   // SM259: a cloned content folder must reveal the option too
  // site_url is intentionally NOT copied - the new host gets its own address.
  // The access keys (allowed_groups / locked_users) are not copied either: who
  // may manage a domain is a deliberate grant, not a starting-point convenience.
}

function loadDomains() {
  fetch(API + '?action=domains-list', { credentials: 'same-origin' })
    .then(function (r) { return r.json(); })
    .then(function (d) {
      var listEl = document.getElementById('domains-list');
      if (!d || !d.ok) { listEl.innerHTML = '<div class="mg-status">Could not load domains.</div>'; return; }
      var rows = d.domains || [];
      DOMAINS = rows;    // SM259: the create sheet's "Copy settings from" list
      DOMAINS_BY_HOST = {};
      rows.forEach(function (r) { DOMAINS_BY_HOST[r.host] = r; });   // the editor sheet reads domains by host from here
      // Each domain is a slim single-line row - host, content folder, active
      // theme and a state chip - with ONE Configure button. Everything else
      // (edit + the domain actions) lives in the config sheet, so the row never
      // sprouts a dropdown or an inline edit panel. The table scrolls inside its
      // own box (overflow-x) so a wide value never pushes the page sideways.
      var html = '<div style="overflow-x:auto;"><table class="mg-file-table" style="min-width:0;"><thead><tr><th>Domain</th>';
      DISPLAY_KEYS.forEach(function (k) { html += '<th>' + esc(label(k)) + '</th>'; });
      html += '<th></th></tr></thead><tbody>';
      rows.forEach(function (row) {
        if (row.is_primary) return;   // the default site lives in Site settings, not this list
        // A small state chip where the data exposes one: an alias (no content
        // folder = mirrors the default site) or membership of a language set.
        var chip = '';
        if (!row.content_root) chip += '<span class="mg-dom-chip" title="mirrors your default site">alias</span>';
        if (row.lang_group && !row.lang_group_inherited) chip += '<span class="mg-dom-chip" title="part of a language set">set: ' + esc(row.lang_group) + '</span>';
        html += '<tr><td class="mg-file-name"><strong>' + esc(row.host) + '</strong>' + chip + '</td>';
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
        // ONE control: Configure opens the full-width editor sheet. data-cfg lets
        // markConfiguring() highlight the button of the open domain.
        html += '<td style="text-align:right;white-space:nowrap;">'
              + '<button type="button" class="mg-btn mg-btn-sm mg-configbtn" data-cfg="' + esc(row.host) + '"'
              + ' onclick="configureDomain(' + esc(JSON.stringify(row.host)) + ')">Configure</button></td></tr>';
      });
      html += '</tbody></table></div>';
      if (rows.length <= 1) {
        html += '<p style="font-size:0.85em;color:#888;margin-top:10px;">'
              + 'No extra domains yet. Use <strong>Add domain</strong> to host several '
              + 'first-class sites from this one instance.</p>';
      }
      listEl.innerHTML = html;
      // Keep an open editor in sync with the fresh data (a save reloads the list),
      // or close it if its domain is gone (deleted).
      if (currentConfigHost) {
        if (DOMAINS_BY_HOST[currentConfigHost]) renderConfigSheet(currentConfigHost);
        else closeConfig();
      }
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
