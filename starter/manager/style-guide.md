---
title: Manager Style Guide
auth: manager
search: false
---

<p class="mg-config-help">Every component the manager pages emit, in one place, with
test content. <strong>This is the contract</strong>: the pages name what they need here,
and <code>manager.css</code> must style everything named. A component present here and
unstyled is a gap in the stylesheet, not a licence to hand-style a page.</p>

<div class="mg-card">
  <div class="mg-card-header"><span class="mg-card-title">How to use this page</span></div>
  <div class="mg-card-body">
    <p>Read it as a rendered page, not as source. That is the whole point: SM686, SM689
    and SM697 were each a page that was correct in source and wrong in the browser, and
    each reached an operator because nobody was looking at the rendering.</p>
    <p>Adding a component: register it here the moment a page starts emitting its class,
    so there is something to style against. A structural class may carry a neutral
    token-based default in the meantime.</p>
    <p><code>t/lint/96</code> holds both directions - every class this guide names is
    defined in the stylesheet, and every class the stylesheet defines appears here.</p>
  </div>
</div>

<h2 class="mg-sg-h">Buttons</h2>
<p class="mg-sg-note">One button element with modifiers. A destructive action uses <code>mg-btn-danger</code> and must ALSO be confirmed - the colour is a warning, not the guard.</p>
<div class="mg-sg-demo">
<button class="mg-btn">Default</button>
<button class="mg-btn mg-btn-primary">Primary</button>
<button class="mg-btn mg-btn-outline">Outline</button>
<button class="mg-btn mg-btn-danger">Delete</button>
<button class="mg-btn mg-btn-sm">Small</button>
</div>

<h2 class="mg-sg-h">Status and toasts</h2>
<p class="mg-sg-note">A status line is persistent and belongs to the page. A toast is transient and belongs to the action just taken.</p>
<div class="mg-sg-demo">
<div class="mg-status">Neutral status, waiting.</div>
<div class="mg-status mg-status-success">Saved.</div>
<div class="mg-status mg-status-error">Refused, naming the rule that refused.</div>
<div class="mg-toast mg-toast-success mg-toast-in">Row added</div>
<div class="mg-toast mg-toast-error mg-toast-in">Could not save</div>
</div>

<h2 class="mg-sg-h">Badges and tags</h2>
<p class="mg-sg-note">A badge labels a thing. A tag records a state - on or off, and who set it.</p>
<div class="mg-sg-demo">
<span class="mg-badge">plain</span>
<span class="mg-badge mg-badge-muted">no members</span>
<span class="mg-badge mg-badge-success">enabled</span>
<span class="mg-tag mg-tag-on">on</span>
<span class="mg-tag mg-tag-off">off</span>
<span class="mg-tag mg-tag-human">set by a person</span>
<span class="mg-tag mg-tag-auto">set automatically</span>
</div>

<h2 class="mg-sg-h">Cards</h2>
<p class="mg-sg-note">The page-level container. A card holds one subject, and cards do not nest.</p>
<div class="mg-sg-demo">
<div class="mg-card">
  <div class="mg-card-header">
    <span class="mg-card-title">Card title</span>
    <span class="mg-card-subtitle">what it is for</span>
  </div>
  <div class="mg-card-body">Body content sits here.</div>
</div>
</div>

<h2 class="mg-sg-h">The row expander - THE ONE IDIOM</h2>
<p class="mg-sg-note"><strong>When to use it (release manager, 2026-08-30):</strong> when a row has too much detail for the row, but not enough to demand a modal. Too little and it belongs on the row; too much - its own subject, its own controls - and it belongs in a modal (SM680). <strong>And when you add the expander, take that detail OFF the row</strong>, so the row carries only the essentials. Files and Domains are the reference. A listing row and a card that opens beneath it. This is the manager&rsquo;s single expander: the chevron sits in the row, the card is the row&rsquo;s next sibling, and only one is open at a time. Any page showing more detail for one row of a list uses THIS. Eight pages currently roll their own show/hide; that is the inconsistency this guide exists to end.</p>
<div class="mg-sg-demo">
<div class="mg-file-item">
  <span class="mg-file-name"><code>an-item</code> <span class="mg-file-meta">9 rows &middot; published</span></span>
  <span>
    <button class="mg-btn">Read</button>
    <a href="#" class="mg-chev mg-chev-open" onclick="return false;">&#9652;</a>
  </span>
</div>
<div class="mg-perms-row">
  <div class="mg-perms-card">
    <div class="mg-perms-rights-label">Export</div>
    <div class="mg-perms-actions"><a class="mg-btn" href="#">JSON</a> <a class="mg-btn" href="#">CSV</a></div>
    <div class="mg-perms-owner"><label>Owner</label> <select class="mg-perm-owner"><option>alice</option></select></div>
    <div class="mg-perms-rights-label">People &amp; groups with access</div>
    <div class="mg-rights">
      <span class="mg-chip" data-name="alice"><span class="mg-chip-name">alice</span><button type="button" class="mg-chip-right on" data-right="r">r</button><button type="button" class="mg-chip-right off" data-right="w">w</button><button type="button" class="mg-chip-x">&times;</button></span>
    </div>
    <div class="mg-rights-add"><select class="mg-rights-pick"><option>+ add person or @group&hellip;</option></select></div>
    <div class="mg-perms-hint">Toggle r / w per person. Nobody named = open within the account scope.</div>
    <div class="mg-perms-actions"><button class="mg-btn mg-btn-primary mg-perms-save">Save</button> <a class="mg-perms-history" href="#">Audit</a></div>
  </div>
</div>
</div>

<h2 class="mg-sg-h">Tables</h2>
<p class="mg-sg-note">A listing of like things. A checkbox column is checkbox-width; a column that can be long wraps rather than pushing the row sideways.</p>
<div class="mg-sg-demo">
<table class="mg-table">
  <thead><tr><th class="mg-col-check"><input type="checkbox"></th><th>Name</th><th>Age</th><th class="mg-col-access">Access</th></tr></thead>
  <tbody>
    <tr><td class="mg-col-check"><input type="checkbox"></td><td>first</td><td>2 days</td><td class="mg-col-access"><span class="mg-rwflag mg-rwflag-ok">r</span> <span class="mg-rwflag mg-rwflag-no">w</span></td></tr>
    <tr><td class="mg-col-check"><input type="checkbox"></td><td>second</td><td>just now</td><td class="mg-col-access"><span class="mg-rwflag mg-rwflag-none">none</span></td></tr>
  </tbody>
</table>
</div>

<h2 class="mg-sg-h">Modal</h2>
<p class="mg-sg-note">For a subject that is not more detail about a row - its own application, with its own controls. SM680: a panel opening below a long list is not seen.</p>
<div class="mg-sg-demo">
<div class="mg-modal">
  <div class="mg-modal-overlay"></div>
  <div class="mg-modal-in">
    <div class="mg-modal-msg">Type the table name to confirm.</div>
    <input class="mg-modal-input" value="">
    <div class="mg-modal-actions"><button class="mg-btn">Cancel</button> <button class="mg-btn mg-btn-danger">Drop</button></div>
  </div>
</div>
</div>

<h2 class="mg-sg-h">Inputs and configuration fields</h2>
<p class="mg-sg-note">A read-only value is shown as a value, never as a disabled input that looks editable. A note explains a field; a help line explains a page.</p>
<div class="mg-sg-demo">
<p class="mg-config-help">What this page is for.</p>
<div class="mg-config-section">
  <div class="mg-config-group">
    <div class="mg-config-field">
      <label>A setting</label>
      <input class="mg-inp" value="a value">
      <div class="mg-field-note">What it does, and what happens if it is wrong.</div>
    </div>
    <div class="mg-config-field">
      <label>Derived</label>
      <span class="mg-readonly-value">computed, not editable</span>
    </div>
    <div class="mg-config-field"><button class="mg-btn mg-config-preset">Apply a preset</button></div>
  </div>
</div>
</div>

<h2 class="mg-sg-h">The capability hint marker</h2>
<p class="mg-sg-note">SM686: an information affordance, not a question mark in the label text. Focusable, because a title attribute alone is mouse-only.</p>
<div class="mg-sg-demo">
<label class="mg-chk"><input type="checkbox" checked> Manage forms
  <span class="mg-cap-what" tabindex="0" role="img" aria-label="What this grants: an example sentence" title="An example sentence.">i</span></label>
</div>

<h2 class="mg-sg-h">The rest of the vocabulary</h2>
<p class="mg-sg-note">Every remaining class the stylesheet defines, with a live specimen carrying its own name. Each sits in its own containing block, so an overlay or a full-viewport component is trapped in its cell rather than covering the page.</p>
<h3 class="mg-sg-fam">acc</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-acc</code><div class="mg-acc">acc</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-acc-body</code><div class="mg-acc-body">acc-body</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-acc-kids</code><div class="mg-acc-kids">acc-kids</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-acc-leaf</code><div class="mg-acc-leaf">acc-leaf</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-acc-line</code><div class="mg-acc-line">acc-line</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-acc-list</code><div class="mg-acc-list">acc-list</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-acc-name</code><div class="mg-acc-name">acc-name</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-acc-note</code><div class="mg-acc-note">acc-note</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-acc-spacer</code><div class="mg-acc-spacer">acc-spacer</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-acc-tags</code><div class="mg-acc-tags">acc-tags</div></div>
</div>
<h3 class="mg-sg-fam">alias</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-alias-302</code><div class="mg-alias-302">alias-302</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-alias-badge</code><div class="mg-alias-badge">alias-badge</div></div>
</div>
<h3 class="mg-sg-fam">apply</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-apply-block</code><div class="mg-apply-block">apply-block</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-apply-keep</code><div class="mg-apply-keep">apply-keep</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-apply-ok</code><div class="mg-apply-ok">apply-ok</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-apply-panel</code><div class="mg-apply-panel">apply-panel</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-apply-preview</code><div class="mg-apply-preview">apply-preview</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-apply-warn</code><div class="mg-apply-warn">apply-warn</div></div>
</div>
<h3 class="mg-sg-fam">bar</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-bar</code><div class="mg-bar">bar</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-bar-fill</code><div class="mg-bar-fill">bar-fill</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-bar-label</code><div class="mg-bar-label">bar-label</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-bar-row</code><div class="mg-bar-row">bar-row</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-bar-val</code><div class="mg-bar-val">bar-val</div></div>
</div>
<h3 class="mg-sg-fam">bars</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-bars</code><div class="mg-bars">bars</div></div>
</div>
<h3 class="mg-sg-fam">bc</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-bc-root</code><div class="mg-bc-root">bc-root</div></div>
</div>
<h3 class="mg-sg-fam">body</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-body</code><div class="mg-body">body</div></div>
</div>
<h3 class="mg-sg-fam">box</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-box</code><div class="mg-box">box</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-box-danger</code><div class="mg-box-danger">box-danger</div></div>
</div>
<h3 class="mg-sg-fam">brand</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-brand</code><div class="mg-brand">brand</div></div>
</div>
<h3 class="mg-sg-fam">breadcrumb</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-breadcrumb</code><div class="mg-breadcrumb">breadcrumb</div></div>
</div>
<h3 class="mg-sg-fam">cap</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-cap-dormant</code><div class="mg-cap-dormant">cap-dormant</div></div>
</div>
<h3 class="mg-sg-fam">checks</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-checks</code><div class="mg-checks">checks</div></div>
</div>
<h3 class="mg-sg-fam">cm</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-cm-content</code><div class="mg-cm-content">cm-content</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-cm-yaml</code><div class="mg-cm-yaml">cm-yaml</div></div>
</div>
<h3 class="mg-sg-fam">code</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-code</code><div class="mg-code">code</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-code-box</code><div class="mg-code-box">code-box</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-code-stale</code><div class="mg-code-stale">code-stale</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-code-token</code><div class="mg-code-token">code-token</div></div>
</div>
<h3 class="mg-sg-fam">col</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-col-exp</code><div class="mg-col-exp">col-exp</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-col-mod</code><div class="mg-col-mod">col-mod</div></div>
</div>
<h3 class="mg-sg-fam">configbtn</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-configbtn</code><div class="mg-configbtn">configbtn</div></div>
</div>
<h3 class="mg-sg-fam">connect</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-connect-hint</code><div class="mg-connect-hint">connect-hint</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-connect-pick</code><div class="mg-connect-pick">connect-pick</div></div>
</div>
<h3 class="mg-sg-fam">cred</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-cred-reveal</code><div class="mg-cred-reveal">cred-reveal</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-cred-value</code><div class="mg-cred-value">cred-value</div></div>
</div>
<h3 class="mg-sg-fam">diff</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-diff-minus</code><div class="mg-diff-minus">diff-minus</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-diff-plus</code><div class="mg-diff-plus">diff-plus</div></div>
</div>
<h3 class="mg-sg-fam">dirty</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-dirty-note</code><div class="mg-dirty-note">dirty-note</div></div>
</div>
<h3 class="mg-sg-fam">dom</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-dom-chip</code><div class="mg-dom-chip">dom-chip</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-dom-open</code><div class="mg-dom-open">dom-open</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-dom-tools</code><div class="mg-dom-tools">dom-tools</div></div>
</div>
<h3 class="mg-sg-fam">domain</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-domain-note</code><div class="mg-domain-note">domain-note</div></div>
</div>
<h3 class="mg-sg-fam">editor</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-editor-dirty</code><div class="mg-editor-dirty">editor-dirty</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-editor-divider</code><div class="mg-editor-divider">editor-divider</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-editor-main</code><div class="mg-editor-main">editor-main</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-editor-pane</code><div class="mg-editor-pane">editor-pane</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-editor-path</code><div class="mg-editor-path">editor-path</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-editor-root</code><div class="mg-editor-root">editor-root</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-editor-saved</code><div class="mg-editor-saved">editor-saved</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-editor-statusbar</code><div class="mg-editor-statusbar">editor-statusbar</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-editor-toolbar</code><div class="mg-editor-toolbar">editor-toolbar</div></div>
</div>
<h3 class="mg-sg-fam">empty</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-empty</code><div class="mg-empty">empty</div></div>
</div>
<h3 class="mg-sg-fam">err</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-err</code><div class="mg-err">err</div></div>
</div>
<h3 class="mg-sg-fam">file</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-file-actions</code><div class="mg-file-actions">file-actions</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-file-actions-left</code><div class="mg-file-actions-left">file-actions-left</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-file-actions-right</code><div class="mg-file-actions-right">file-actions-right</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-file-actions-row</code><div class="mg-file-actions-row">file-actions-row</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-file-dl</code><div class="mg-file-dl">file-dl</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-file-filter</code><div class="mg-file-filter">file-filter</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-file-filter-row</code><div class="mg-file-filter-row">file-filter-row</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-file-icon</code><div class="mg-file-icon">file-icon</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-file-list</code><div class="mg-file-list">file-list</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-file-select</code><div class="mg-file-select">file-select</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-file-size</code><div class="mg-file-size">file-size</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-file-table</code><div class="mg-file-table">file-table</div></div>
</div>
<h3 class="mg-sg-fam">fm</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-fm-fields</code><div class="mg-fm-fields">fm-fields</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-fm-section</code><div class="mg-fm-section">fm-section</div></div>
</div>
<h3 class="mg-sg-fam">foot</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-foot</code><div class="mg-foot">foot</div></div>
</div>
<h3 class="mg-sg-fam">form</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-form-row</code><div class="mg-form-row">form-row</div></div>
</div>
<h3 class="mg-sg-fam">handler</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-handler-group</code><div class="mg-handler-group">handler-group</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-handler-group-header</code><div class="mg-handler-group-header">handler-group-header</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-handler-group-label</code><div class="mg-handler-group-label">handler-group-label</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-handler-item</code><div class="mg-handler-item">handler-item</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-handler-item-actions</code><div class="mg-handler-item-actions">handler-item-actions</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-handler-item-header</code><div class="mg-handler-item-header">handler-item-header</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-handler-name</code><div class="mg-handler-name">handler-name</div></div>
</div>
<h3 class="mg-sg-fam">header</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-header</code><div class="mg-header">header</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-header-inner</code><div class="mg-header-inner">header-inner</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-header-tools</code><div class="mg-header-tools">header-tools</div></div>
</div>
<h3 class="mg-sg-fam">help</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-help</code><div class="mg-help">help</div></div>
</div>
<h3 class="mg-sg-fam">holder</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-holder-count</code><div class="mg-holder-count">holder-count</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-holder-line</code><div class="mg-holder-line">holder-line</div></div>
</div>
<h3 class="mg-sg-fam">info</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-info</code><div class="mg-info">info</div></div>
</div>
<h3 class="mg-sg-fam">inline</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-inline-msg</code><div class="mg-inline-msg">inline-msg</div></div>
</div>
<h3 class="mg-sg-fam">inp</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-inp-wide</code><div class="mg-inp-wide">inp-wide</div></div>
</div>
<h3 class="mg-sg-fam">json</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-json-pre</code><div class="mg-json-pre">json-pre</div></div>
</div>
<h3 class="mg-sg-fam">jsonl</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-jsonl-more</code><div class="mg-jsonl-more">jsonl-more</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-jsonl-table</code><div class="mg-jsonl-table">jsonl-table</div></div>
</div>
<h3 class="mg-sg-fam">line</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-line</code><div class="mg-line">line</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-line-lbl</code><div class="mg-line-lbl">line-lbl</div></div>
</div>
<h3 class="mg-sg-fam">lock</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-lock</code><div class="mg-lock">lock</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-lock-dot</code><div class="mg-lock-dot">lock-dot</div></div>
</div>
<h3 class="mg-sg-fam">main</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-main</code><div class="mg-main">main</div></div>
</div>
<h3 class="mg-sg-fam">muted</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-muted</code><div class="mg-muted">muted</div></div>
</div>
<h3 class="mg-sg-fam">nav</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-nav</code><div class="mg-nav">nav</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-nav-group</code><div class="mg-nav-group">nav-group</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-nav-handle</code><div class="mg-nav-handle">nav-handle</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-nav-item</code><div class="mg-nav-item">nav-item</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-nav-label</code><div class="mg-nav-label">nav-label</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-nav-url</code><div class="mg-nav-url">nav-url</div></div>
</div>
<h3 class="mg-sg-fam">new</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-new-group-row</code><div class="mg-new-group-row">new-group-row</div></div>
</div>
<h3 class="mg-sg-fam">no</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-no-password-warn</code><div class="mg-no-password-warn">no-password-warn</div></div>
</div>
<h3 class="mg-sg-fam">notif</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-notif</code><div class="mg-notif">notif</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-notif-badge</code><div class="mg-notif-badge">notif-badge</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-notif-btn</code><div class="mg-notif-btn">notif-btn</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-notif-empty</code><div class="mg-notif-empty">notif-empty</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-notif-item</code><div class="mg-notif-item">notif-item</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-notif-msg</code><div class="mg-notif-msg">notif-msg</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-notif-panel</code><div class="mg-notif-panel">notif-panel</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-notif-time</code><div class="mg-notif-time">notif-time</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-notif-unread</code><div class="mg-notif-unread">notif-unread</div></div>
</div>
<h3 class="mg-sg-fam">ok</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-ok</code><div class="mg-ok">ok</div></div>
</div>
<h3 class="mg-sg-fam">onb</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-onb</code><div class="mg-onb">onb</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-onb-card</code><div class="mg-onb-card">onb-card</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-onb-card-go</code><div class="mg-onb-card-go">onb-card-go</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-onb-head</code><div class="mg-onb-head">onb-head</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-onb-list</code><div class="mg-onb-list">onb-list</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-onb-ok</code><div class="mg-onb-ok">onb-ok</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-onb-wait</code><div class="mg-onb-wait">onb-wait</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-onb-warn</code><div class="mg-onb-warn">onb-warn</div></div>
</div>
<h3 class="mg-sg-fam">owner</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-owner-name</code><div class="mg-owner-name">owner-name</div></div>
</div>
<h3 class="mg-sg-fam">page</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-page-title</code><div class="mg-page-title">page-title</div></div>
</div>
<h3 class="mg-sg-fam">pager</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-pager</code><div class="mg-pager">pager</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-pager-info</code><div class="mg-pager-info">pager-info</div></div>
</div>
<h3 class="mg-sg-fam">palette</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-palette</code><div class="mg-palette">palette</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-palette-btn</code><div class="mg-palette-btn">palette-btn</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-palette-empty</code><div class="mg-palette-empty">palette-empty</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-palette-input</code><div class="mg-palette-input">palette-input</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-palette-item</code><div class="mg-palette-item">palette-item</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-palette-list</code><div class="mg-palette-list">palette-list</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-palette-overlay</code><div class="mg-palette-overlay">palette-overlay</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-palette-url</code><div class="mg-palette-url">palette-url</div></div>
</div>
<h3 class="mg-sg-fam">perms</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-perms-cell</code><div class="mg-perms-cell">perms-cell</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-perms-head</code><div class="mg-perms-head">perms-head</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-perms-title</code><div class="mg-perms-title">perms-title</div></div>
</div>
<h3 class="mg-sg-fam">plugin</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-plugin-card</code><div class="mg-plugin-card">plugin-card</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-plugin-ctl</code><div class="mg-plugin-ctl">plugin-ctl</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-plugin-desc</code><div class="mg-plugin-desc">plugin-desc</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-plugin-end</code><div class="mg-plugin-end">plugin-end</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-plugin-main</code><div class="mg-plugin-main">plugin-main</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-plugin-registry</code><div class="mg-plugin-registry">plugin-registry</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-plugin-row</code><div class="mg-plugin-row">plugin-row</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-plugin-row-config</code><div class="mg-plugin-row-config">plugin-row-config</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-plugin-row-desc</code><div class="mg-plugin-row-desc">plugin-row-desc</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-plugin-row-name</code><div class="mg-plugin-row-name">plugin-row-name</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-plugin-title</code><div class="mg-plugin-title">plugin-title</div></div>
</div>
<h3 class="mg-sg-fam">preview</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-preview-frame</code><div class="mg-preview-frame">preview-frame</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-preview-pane</code><div class="mg-preview-pane">preview-pane</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-preview-toolbar</code><div class="mg-preview-toolbar">preview-toolbar</div></div>
</div>
<h3 class="mg-sg-fam">protect</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-protect-here</code><div class="mg-protect-here">protect-here</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-protect-lock</code><div class="mg-protect-lock">protect-lock</div></div>
</div>
<h3 class="mg-sg-fam">prov</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-prov</code><div class="mg-prov">prov</div></div>
</div>
<h3 class="mg-sg-fam">qr</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-qr</code><div class="mg-qr">qr</div></div>
</div>
<h3 class="mg-sg-fam">readonly</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-readonly</code><div class="mg-readonly">readonly</div></div>
</div>
<h3 class="mg-sg-fam">recent</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-recent-dot</code><div class="mg-recent-dot">recent-dot</div></div>
</div>
<h3 class="mg-sg-fam">rwflag</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-rwflag-g</code><div class="mg-rwflag-g">rwflag-g</div></div>
</div>
<h3 class="mg-sg-fam">sec</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-sec</code><div class="mg-sec">sec</div></div>
</div>
<h3 class="mg-sg-fam">section</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-section-label</code><div class="mg-section-label">section-label</div></div>
</div>
<h3 class="mg-sg-fam">sheet</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-sheet</code><div class="mg-sheet">sheet</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-sheet-body</code><div class="mg-sheet-body">sheet-body</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-sheet-close</code><div class="mg-sheet-close">sheet-close</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-sheet-head</code><div class="mg-sheet-head">sheet-head</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-sheet-open</code><div class="mg-sheet-open">sheet-open</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-sheet-panel</code><div class="mg-sheet-panel">sheet-panel</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-sheet-sub</code><div class="mg-sheet-sub">sheet-sub</div></div>
</div>
<h3 class="mg-sg-fam">shell</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-shell</code><div class="mg-shell">shell</div></div>
</div>
<h3 class="mg-sg-fam">sidebar</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-sidebar</code><div class="mg-sidebar">sidebar</div></div>
</div>
<h3 class="mg-sg-fam">signout</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-signout</code><div class="mg-signout">signout</div></div>
</div>
<h3 class="mg-sg-fam">sort</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-sort-ind</code><div class="mg-sort-ind">sort-ind</div></div>
</div>
<h3 class="mg-sg-fam">sortable</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-sortable</code><div class="mg-sortable">sortable</div></div>
</div>
<h3 class="mg-sg-fam">split</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-split-bar</code><div class="mg-split-bar">split-bar</div></div>
</div>
<h3 class="mg-sg-fam">stat</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-stat-block</code><div class="mg-stat-block">stat-block</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-stat-col</code><div class="mg-stat-col">stat-col</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-stat-cols</code><div class="mg-stat-cols">stat-cols</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-stat-label</code><div class="mg-stat-label">stat-label</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-stat-tile</code><div class="mg-stat-tile">stat-tile</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-stat-tiles</code><div class="mg-stat-tiles">stat-tiles</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-stat-value</code><div class="mg-stat-value">stat-value</div></div>
</div>
<h3 class="mg-sg-fam">subcount</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-subcount</code><div class="mg-subcount">subcount</div></div>
</div>
<h3 class="mg-sg-fam">theme</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-theme-toggle</code><div class="mg-theme-toggle">theme-toggle</div></div>
</div>
<h3 class="mg-sg-fam">toggle</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-toggle</code><div class="mg-toggle">toggle</div></div>
</div>
<h3 class="mg-sg-fam">token</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-token</code><div class="mg-token">token</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-token-x</code><div class="mg-token-x">token-x</div></div>
</div>
<h3 class="mg-sg-fam">tokens</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-tokens</code><div class="mg-tokens">tokens</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-tokens-empty</code><div class="mg-tokens-empty">tokens-empty</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-tokens-pick</code><div class="mg-tokens-pick">tokens-pick</div></div>
</div>
<h3 class="mg-sg-fam">undo</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-undo-bar</code><div class="mg-undo-bar">undo-bar</div></div>
</div>
<h3 class="mg-sg-fam">user</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-user</code><div class="mg-user">user</div></div>
</div>
<h3 class="mg-sg-fam">warning</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-warning-bar</code><div class="mg-warning-bar">warning-bar</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-warning-bar-close</code><div class="mg-warning-bar-close">warning-bar-close</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-warning-error</code><div class="mg-warning-error">warning-error</div></div>
</div>
<h3 class="mg-sg-fam">wizard</h3>
<div class="mg-sg-grid">
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-wizard</code><div class="mg-wizard">wizard</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-wizard-actions</code><div class="mg-wizard-actions">wizard-actions</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-wizard-section-label</code><div class="mg-wizard-section-label">wizard-section-label</div></div>
  <div class="mg-sg-item"><code class="mg-sg-name">.mg-wizard-title</code><div class="mg-wizard-title">wizard-title</div></div>
</div>

<style>
.mg-sg-h { margin: 1.6rem 0 0.2rem; font-size: 1.05rem; }
.mg-sg-note { margin: 0 0 0.6rem; font-size: 0.86rem; color: var(--mg-text-muted); max-width: 46rem; }
.mg-sg-demo { padding: 0.9rem; border: 1px solid var(--mg-border); border-radius: 4px;
  background: var(--mg-bg); display: flex; flex-wrap: wrap; gap: 0.5rem; align-items: flex-start; }
.mg-sg-demo > * { max-width: 100%; }
.mg-sg-fam { margin: 1.1rem 0 0.3rem; font-size: 0.9rem; text-transform: lowercase;
  color: var(--mg-text-muted); }
.mg-sg-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(15rem, 1fr));
  gap: 0.5rem; }
/* EACH SPECIMEN IS TRAPPED IN ITS OWN BOX.
   Sixteen manager classes are position:fixed/absolute or full-viewport - the
   overlays, the editor root, the sheet, the command palette. Rendered loose in
   a grid they cover the whole page, which is exactly what the first version of
   this guide did: it went grey, and two labels showed through.
   `transform` creates a containing block for FIXED descendants as well as
   absolute ones, so the cell contains them; `overflow:hidden` clips what is
   sized to the viewport. The specimen still renders live - it is contained,
   not faked. */
.mg-sg-item { border: 1px solid var(--mg-border-light); border-radius: 3px;
  padding: 0.4rem; position: relative; overflow: hidden; transform: translateZ(0);
  min-height: 3.2rem; max-height: 9rem; contain: layout paint; }
/* An overlay's own backdrop would still paint its cell solid, so inside a
   specimen it is shown at low opacity - enough to see the colour and the
   shape without hiding the label that names it. */
.mg-sg-item [class*="overlay"], .mg-sg-item .mg-sheet,
.mg-sg-item .mg-editor-root, .mg-sg-item .mg-modal { opacity: 0.35; }
.mg-sg-name { display: block; font-size: 0.72rem; color: var(--mg-text-muted);
  margin-bottom: 0.25rem; }
</style>
