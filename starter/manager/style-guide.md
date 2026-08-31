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
<div class="mg-sg-item"><div class="mg-toast mg-toast-success mg-toast-in">Row added</div></div>
<div class="mg-sg-item"><div class="mg-toast mg-toast-error mg-toast-in">Could not save</div></div>
<button class="mg-btn" onclick="sgToast('success')">Show a success toast</button>
<button class="mg-btn" onclick="sgToast('error')">Show an error toast</button>
<span class="mg-muted">A toast is fixed to the corner of the viewport. The two
cells name and colour it; the buttons show it where it really appears, and it
dismisses itself.</span>
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
  <div class="mg-expand-body">
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

<h2 class="mg-sg-h">Settings &mdash; the dense form</h2>
<p class="mg-sg-note">SM-DS2, drawn by the design side for fifteen-field pages. One
schema group per card, the group's help as the card subtitle, and
<code>.mg-form-dense</code> re-flowing the SAME <code>.mg-field</code> markup into a
label rail with the control and its help beside it. Fifteen fields scan down the left
edge instead of scrolling a flat column. Below 720px it stacks back to label-above,
which is the idiom the manager already had.</p>
<div class="mg-sg-demo">
<div class="mg-card" style="margin-bottom: 0;">
  <div class="mg-card-header">
    <span class="mg-card-title">Publishing</span>
    <span class="mg-card-subtitle">how pages leave the site: addresses, feeds, and the build that produces them</span>
  </div>
  <div class="mg-card-body">
    <div class="mg-form-dense">
      <div class="mg-field">
        <label>Base URL</label>
        <input type="url" value="https://example.org">
        <div class="mg-muted">Absolute links, feeds and sitemaps are written against this.</div>
      </div>
      <div class="mg-field">
        <label>Feed length</label>
        <select><option>20 entries</option><option>50 entries</option></select>
        <div class="mg-muted">Applies to RSS and JSON feeds alike; archives are unaffected.</div>
      </div>
      <div class="mg-field">
        <label>Canonical scheme</label>
        <span class="mg-readonly-value">https &mdash; forced by the proxy</span>
      </div>
      <div class="mg-field">
        <label>On publish</label>
        <div class="mg-checks">
          <label class="mg-chk"><input type="checkbox" checked> Ping search engines</label>
          <label class="mg-chk"><input type="checkbox"> Rebuild related pages</label>
        </div>
        <div class="mg-muted">Both run after the build finishes, never during it.</div>
      </div>
    </div>
  </div>
</div>
    </section>

    <section data-screen-label="Groups list" style="margin-bottom: 36px;">
</div>

<h2 class="mg-sg-h">Groups &mdash; the dense sectioned list</h2>
<p class="mg-sg-note">SM-DS2. The sectioned structure kept and re-inked: the section
head joins the <code>.mg-sec</code> vocabulary, the count is <code>.mg-subcount</code>,
rows are ordinary <code>.mg-row</code>, and <code>.mg-rollup</code> gains an outward
marker with overflow ellipsis &mdash; so a group belonging to seven bundles cannot
wreck its row. No new classes.</p>
<div class="mg-sg-demo">
<details class="mg-group-section" open>
  <summary><span class="mg-group-section-head">Roles</span><span class="mg-subcount">3 groups</span></summary>
  <div class="mg-row">
    <span class="mg-row-name">@editors</span>
    <span class="mg-rollup"><a href="#">@staff</a>, <a href="#">@all</a></span>
    <span class="mg-row-meta">8 members</span>
    <span class="mg-row-actions"><button class="mg-btn mg-btn-sm">Configure</button></span>
  </div>
  <div class="mg-row">
    <span class="mg-row-name">@reviewers</span>
    <span class="mg-rollup"><a href="#">@staff</a></span>
    <span class="mg-row-meta">3 members</span>
    <span class="mg-row-actions"><button class="mg-btn mg-btn-sm">Configure</button></span>
  </div>
  <div class="mg-row">
    <span class="mg-row-name">@admins</span>
    <span class="mg-rollup"><a href="#">@staff</a>, <a href="#">@oncall</a></span>
    <span class="mg-row-meta">2 members</span>
    <span class="mg-row-actions"><button class="mg-btn mg-btn-sm">Configure</button></span>
  </div>
</details>
<details class="mg-group-section" style="margin-bottom: 0;">
  <summary><span class="mg-group-section-head">Bundles</span><span class="mg-subcount">2 groups &middot; collapsed</span></summary>
</details>
    </section>

    <section data-screen-label="Legacy vocabulary" style="margin-bottom: 36px;">
</div>

<h2 class="mg-sg-h">Modal</h2>
<p class="mg-sg-note">For a subject that is not more detail about a row - its own application, with its own controls. SM680: a panel opening below a long list is not seen.</p>
<div class="mg-sg-demo">
<button class="mg-btn" onclick="sgOpen('sg-modal')">Open the modal</button>
<span class="mg-muted">It covers the page, as it does in use. Esc, the overlay
or Cancel closes it.</span>
</div>
<div class="mg-modal" id="sg-modal" hidden>
  <div class="mg-modal-overlay" onclick="sgClose('sg-modal')"></div>
  <div class="mg-modal-in">
    <div class="mg-modal-msg">Type the table name to confirm.</div>
    <input class="mg-modal-input" value="">
    <div class="mg-modal-actions"><button class="mg-btn" onclick="sgClose('sg-modal')">Cancel</button> <button class="mg-btn mg-btn-danger" onclick="sgClose('sg-modal')">Drop</button></div>
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
      <div class="mg-muted">What it does, and what happens if it is wrong.</div>
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

<h2 class="mg-sg-h">The collapsed vocabulary (SM-DS1)</h2>
<p class="mg-sg-note">The design pass folded several near-duplicate families into one
each. These are the survivors, registered so the pages have something to be converted
<em>to</em>.</p>
<div class="mg-sg-demo mg-sg-family">
  <div><span class="mg-sg-tag">.mg-list / .mg-row / .mg-expand / .mg-expand-body</span>
    <div class="mg-list">
      <div class="mg-row">
        <span class="mg-row-name">an-item</span>
        <span class="mg-row-meta">9 rows &middot; published</span>
        <span class="mg-row-actions"><button class="mg-btn mg-btn-sm">Read</button>
          <a href="#" class="mg-chev" onclick="return false;">&#9662;</a></span>
      </div>
      <div class="mg-expand"><div class="mg-expand-body">the row expander &mdash; one idiom, next sibling of its row. <strong>Two elements:</strong> <code>.mg-expand</code> is what the script toggles and closes siblings of; <code>.mg-expand-body</code> is the card inside it. Collapsing them into one name emptied every expander in 0.11.8.</div></div>
    </div>
  </div>
  <div><span class="mg-sg-tag">.mg-note</span>
    <div class="mg-note mg-note-info">info &mdash; something worth knowing</div>
    <div class="mg-note mg-note-warn">warn &mdash; done, but it will not work yet</div>
    <div class="mg-note mg-note-danger">danger &mdash; this will lose something</div>
  </div>
  <div><span class="mg-sg-tag">.mg-field / .mg-inp-sm</span>
    <div class="mg-field"><label>Label above the control</label>
      <input class="mg-inp" value="a value"></div>
    <div class="mg-field"><label>Small</label>
      <input class="mg-inp mg-inp-sm" value="compact"></div>
  </div>
  <div><span class="mg-sg-tag">.mg-btn-change</span>
    <button class="mg-btn mg-btn-primary">Save</button>
    <button class="mg-btn mg-btn-change">Apply</button>
    <span class="mg-muted">steel confirms, copper changes, red destroys</span>
  </div>
  <div><span class="mg-sg-tag">.mg-tag-warn / -change, .mg-status-warn</span>
    <span class="mg-tag mg-tag-warn">warn</span>
    <span class="mg-tag mg-tag-change">change</span>
    <div class="mg-status mg-status-warn">neither success nor error</div>
  </div>
  <div><span class="mg-sg-tag">.mg-nav-burger / .mg-scrim</span>
    <button class="mg-nav-burger">&#9776;</button>
    <div class="mg-scrim"></div>
    <span class="mg-muted">drawer toggle and tap-to-close scrim</span>
  </div>
</div>

<h2 class="mg-sg-h">Button labels &mdash; the vocabulary</h2>
<p class="mg-sg-note">A style guide governs words as well as shapes. The manager
currently uses <strong>107 distinct button labels</strong>, and several say the same
thing three ways &mdash; an operator learning one page has to relearn the next. These are
the words to use; anything else needs a reason.</p>
<div class="mg-sg-demo mg-sg-family">
  <div><span class="mg-sg-tag">commit</span>
    <button class="mg-btn mg-btn-primary">Save</button>
    <span class="mg-muted">Not <em>Update</em>, not <em>Apply</em>. One word for
    &ldquo;write what I have entered&rdquo;. <em>Apply</em> is reserved for
    putting a prepared thing into effect (a package, a preset) &mdash; a
    different act from saving a form.</span>
  </div>
  <div><span class="mg-sg-tag">abandon</span>
    <button class="mg-btn">Cancel</button>
    <span class="mg-muted"><em>Cancel</em> when work would be lost, <em>Close</em>
    when nothing would. An operator reads the difference as a warning, so using
    them interchangeably removes a signal rather than adding a synonym.</span>
  </div>
  <div><span class="mg-sg-tag">destroy</span>
    <button class="mg-btn mg-btn-danger">Delete</button>
    <span class="mg-muted">Not <em>Remove</em>, not <em>Clear</em>. <em>Remove</em>
    is for taking something out of a list it can be put back into;
    <em>Clear</em> is for emptying a field. Only <em>Delete</em> destroys.</span>
  </div>
  <div><span class="mg-sg-tag">decide</span>
    <button class="mg-btn mg-btn-primary">Grant</button>
    <button class="mg-btn">Deny</button>
    <span class="mg-muted">A button that WRITES an authority is a decision, and
    must read as one. <em>Dismiss</em> was doing this job on the Groups page:
    it denied a pending capability while reading like closing a notice, so an
    operator could decide without knowing they had. Pair the affirmative with
    its actual opposite, never with a word for going away.</span>
  </div>
  <div><span class="mg-sg-tag">install</span>
    <button class="mg-btn">Install</button>
    <button class="mg-btn mg-btn-change">Update</button>
    <span class="mg-muted"><em>Update</em> is banned as a synonym for
    <em>Save</em> and is the right word HERE: bringing an installed package to
    the catalogue's version is a different act from installing a new one, and
    the pair tells the operator which they are about to do. Found by auditing
    the labels against this list - the vocabulary was incomplete, not the
    button wrong.</span>
  </div>
  <div><span class="mg-sg-tag">object</span>
    <button class="mg-btn">Add a row</button>
    <span class="mg-muted">Name the object when the page holds more than one kind
    of thing (<em>Add a row</em>, <em>Declare a table</em>), and use the bare verb
    when it cannot be ambiguous. A page of nothing but backups does not need
    <em>Create content backup</em> on every button.</span>
  </div>
  <div><span class="mg-sg-tag">refuse</span>
    <span class="mg-muted">A destructive label is a warning, never the guard.
    <code>.mg-btn-danger</code> plus a confirmation; colour alone has never
    stopped anybody.</span>
  </div>
</div>

<h2 class="mg-sg-h">Every remaining component, by family</h2>
<p class="mg-sg-note">The rest of the manager vocabulary, composed rather than listed. Each family is shown nested the way its pages build it, with every class labelled, so a stylesheet can be written against the structure rather than against a list of names. A class that renders as a bare label here has no rule.</p>
<h3 class="mg-sg-fam">mg-file <span class="mg-sg-count">12</span></h3>
<p class="mg-sg-note">Used by <code>files.md</code>. Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-file-actions"><span class="mg-sg-tag">.mg-file-actions</span><div class="mg-file-actions-left"><span class="mg-sg-tag">.mg-file-actions-left</span></div>
<div class="mg-file-actions-right"><span class="mg-sg-tag">.mg-file-actions-right</span></div>
<div class="mg-file-actions-row"><span class="mg-sg-tag">.mg-file-actions-row</span></div>
<div class="mg-file-filter-row"><span class="mg-sg-tag">.mg-file-filter-row</span></div></div>
<div class="mg-file-dl"><span class="mg-sg-tag">.mg-file-dl</span></div>
<div class="mg-file-filter"><span class="mg-sg-tag">.mg-file-filter</span></div>
<div class="mg-file-icon"><span class="mg-sg-tag">.mg-file-icon</span></div>
<div class="mg-list"><span class="mg-sg-tag">.mg-list</span></div>
<div class="mg-file-select"><span class="mg-sg-tag">.mg-file-select</span></div>
<div class="mg-file-size"><span class="mg-sg-tag">.mg-file-size</span></div>
<div class="mg-file-table"><span class="mg-sg-tag">.mg-file-table</span></div>
</div>
<h3 class="mg-sg-fam">mg-plugin <span class="mg-sg-count">11</span></h3>
<p class="mg-sg-note">Used by <code>plugins.md</code>. Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-plugin-card"><span class="mg-sg-tag">.mg-plugin-card</span><div class="mg-plugin-row-config"><span class="mg-sg-tag">.mg-plugin-row-config</span></div>
<div class="mg-muted"><span class="mg-sg-tag">.mg-muted</span></div>
<div class="mg-plugin-row-name"><span class="mg-sg-tag">.mg-plugin-row-name</span></div></div>
<div class="mg-plugin-ctl"><span class="mg-sg-tag">.mg-plugin-ctl</span></div>
<div class="mg-plugin-desc"><span class="mg-sg-tag">.mg-plugin-desc</span></div>
<div class="mg-plugin-end"><span class="mg-sg-tag">.mg-plugin-end</span></div>
<div class="mg-plugin-main"><span class="mg-sg-tag">.mg-plugin-main</span></div>
<div class="mg-plugin-registry"><span class="mg-sg-tag">.mg-plugin-registry</span></div>
<div class="mg-plugin-row"><span class="mg-sg-tag">.mg-plugin-row</span></div>
<div class="mg-plugin-title"><span class="mg-sg-tag">.mg-plugin-title</span></div>
</div>
<h3 class="mg-sg-fam">mg-acc <span class="mg-sg-count">10</span></h3>
<p class="mg-sg-note">Used by <code>users.md</code>. Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-acc"><span class="mg-sg-tag">.mg-acc</span><div class="mg-acc-body"><span class="mg-sg-tag">.mg-acc-body</span></div>
<div class="mg-acc-kids"><span class="mg-sg-tag">.mg-acc-kids</span></div>
<div class="mg-acc-leaf"><span class="mg-sg-tag">.mg-acc-leaf</span></div>
<div class="mg-acc-line"><span class="mg-sg-tag">.mg-acc-line</span></div>
<div class="mg-acc-list"><span class="mg-sg-tag">.mg-acc-list</span></div>
<div class="mg-acc-name"><span class="mg-sg-tag">.mg-acc-name</span></div>
<div class="mg-acc-note"><span class="mg-sg-tag">.mg-acc-note</span></div>
<div class="mg-acc-spacer"><span class="mg-sg-tag">.mg-acc-spacer</span></div>
<div class="mg-acc-tags"><span class="mg-sg-tag">.mg-acc-tags</span></div></div>
</div>
<h3 class="mg-sg-fam">mg-editor <span class="mg-sg-count">9</span></h3>
<p class="mg-sg-note">Used by <code>edit.md</code>. Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-editor-dirty"><span class="mg-sg-tag">.mg-editor-dirty</span></div>
<div class="mg-editor-divider"><span class="mg-sg-tag">.mg-editor-divider</span></div>
<div class="mg-editor-main"><span class="mg-sg-tag">.mg-editor-main</span></div>
<div class="mg-editor-pane"><span class="mg-sg-tag">.mg-editor-pane</span></div>
<div class="mg-editor-path"><span class="mg-sg-tag">.mg-editor-path</span></div>
<div class="mg-editor-root"><span class="mg-sg-tag">.mg-editor-root</span></div>
<div class="mg-editor-saved"><span class="mg-sg-tag">.mg-editor-saved</span></div>
<div class="mg-editor-statusbar"><span class="mg-sg-tag">.mg-editor-statusbar</span></div>
<div class="mg-editor-toolbar"><span class="mg-sg-tag">.mg-editor-toolbar</span></div>
</div>
<h3 class="mg-sg-fam">mg-notif <span class="mg-sg-count">9</span></h3>
<p class="mg-sg-note">Used by <code>the layout</code>. Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-notif"><span class="mg-sg-tag">.mg-notif</span><div class="mg-notif-badge"><span class="mg-sg-tag">.mg-notif-badge</span></div>
<div class="mg-notif-btn"><span class="mg-sg-tag">.mg-notif-btn</span></div>
<div class="mg-notif-empty"><span class="mg-sg-tag">.mg-notif-empty</span></div>
<div class="mg-notif-item"><span class="mg-sg-tag">.mg-notif-item</span></div>
<div class="mg-notif-msg"><span class="mg-sg-tag">.mg-notif-msg</span></div>
<div class="mg-notif-panel"><span class="mg-sg-tag">.mg-notif-panel</span></div>
<div class="mg-notif-time"><span class="mg-sg-tag">.mg-notif-time</span></div>
<div class="mg-notif-unread"><span class="mg-sg-tag">.mg-notif-unread</span></div></div>
</div>
<h3 class="mg-sg-fam">mg-onb <span class="mg-sg-count">8</span></h3>
<p class="mg-sg-note">Used by <code>users.md</code>. Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-onb"><span class="mg-sg-tag">.mg-onb</span><div class="mg-onb-card"><span class="mg-sg-tag">.mg-onb-card</span><div class="mg-onb-card-go"><span class="mg-sg-tag">.mg-onb-card-go</span></div></div>
<div class="mg-onb-head"><span class="mg-sg-tag">.mg-onb-head</span></div>
<div class="mg-onb-list"><span class="mg-sg-tag">.mg-onb-list</span></div>
<div class="mg-onb-ok"><span class="mg-sg-tag">.mg-onb-ok</span></div>
<div class="mg-onb-wait"><span class="mg-sg-tag">.mg-onb-wait</span></div>
<div class="mg-onb-warn"><span class="mg-sg-tag">.mg-onb-warn</span></div></div>
</div>
<h3 class="mg-sg-fam">mg-palette <span class="mg-sg-count">8</span></h3>
<p class="mg-sg-note">Used by <code>the layout</code>. Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-palette"><span class="mg-sg-tag">.mg-palette</span><div class="mg-palette-btn"><span class="mg-sg-tag">.mg-palette-btn</span></div>
<div class="mg-palette-empty"><span class="mg-sg-tag">.mg-palette-empty</span></div>
<div class="mg-palette-input"><span class="mg-sg-tag">.mg-palette-input</span></div>
<div class="mg-palette-item"><span class="mg-sg-tag">.mg-palette-item</span></div>
<div class="mg-palette-list"><span class="mg-sg-tag">.mg-palette-list</span></div>
<div class="mg-palette-overlay"><span class="mg-sg-tag">.mg-palette-overlay</span></div>
<div class="mg-palette-url"><span class="mg-sg-tag">.mg-palette-url</span></div></div>
</div>
<h3 class="mg-sg-fam">mg-group <span class="mg-sg-count">2</span></h3>
<p class="mg-sg-note">Used by <code>groups.md</code>. A long list is sectioned by what a thing IS, and each entry says what it rolls up into rather than being repeated under every parent.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-group-section"><span class="mg-sg-tag">.mg-group-section</span>
<div class="mg-group-section-head"><span class="mg-sg-tag">.mg-group-section-head</span></div></div>
</div>
<h3 class="mg-sg-fam">mg-rollup <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Names the containers a thing belongs to, on its own summary line.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-rollup"><span class="mg-sg-tag">.mg-rollup</span> &#8593; cap-content, ch-ui</div>
</div>
<h3 class="mg-sg-fam">mg-handler <span class="mg-sg-count">9</span></h3>
<p class="mg-sg-note">Used by <code>appearance.md</code>. Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-handler-group"><span class="mg-sg-tag">.mg-handler-group</span><div class="mg-handler-group-header"><span class="mg-sg-tag">.mg-handler-group-header</span></div>
<div class="mg-handler-group-label"><span class="mg-sg-tag">.mg-handler-group-label</span></div>
<div class="mg-handler-item-actions"><span class="mg-sg-tag">.mg-handler-item-actions</span></div>
<div class="mg-handler-item-header"><span class="mg-sg-tag">.mg-handler-item-header</span></div></div>
<div class="mg-handler-item"><span class="mg-sg-tag">.mg-handler-item</span></div>
<div class="mg-handler-name"><span class="mg-sg-tag">.mg-handler-name</span></div>
<div class="mg-handler-edit-form"><span class="mg-sg-tag">.mg-handler-edit-form</span></div>
<div class="mg-handler-submissions"><span class="mg-sg-tag">.mg-handler-submissions</span></div>
</div>
<h3 class="mg-sg-fam">mg-sheet <span class="mg-sg-count">7</span></h3>
<p class="mg-sg-note">Used by <code>domains.md</code>. Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-sheet"><span class="mg-sg-tag">.mg-sheet</span><div class="mg-sheet-body"><span class="mg-sg-tag">.mg-sheet-body</span></div>
<div class="mg-sheet-close"><span class="mg-sg-tag">.mg-sheet-close</span></div>
<div class="mg-sheet-head"><span class="mg-sg-tag">.mg-sheet-head</span></div>
<div class="mg-sheet-open"><span class="mg-sg-tag">.mg-sheet-open</span></div>
<div class="mg-sheet-panel"><span class="mg-sg-tag">.mg-sheet-panel</span></div>
<div class="mg-sheet-sub"><span class="mg-sg-tag">.mg-sheet-sub</span></div></div>
</div>
<h3 class="mg-sg-fam">mg-stat <span class="mg-sg-count">7</span></h3>
<p class="mg-sg-note">Used by <code>stats.md</code>. Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-stat-block"><span class="mg-sg-tag">.mg-stat-block</span></div>
<div class="mg-stat-col"><span class="mg-sg-tag">.mg-stat-col</span></div>
<div class="mg-stat-cols"><span class="mg-sg-tag">.mg-stat-cols</span></div>
<div class="mg-stat-label"><span class="mg-sg-tag">.mg-stat-label</span></div>
<div class="mg-stat-tile"><span class="mg-sg-tag">.mg-stat-tile</span></div>
<div class="mg-stat-tiles"><span class="mg-sg-tag">.mg-stat-tiles</span></div>
<div class="mg-stat-value"><span class="mg-sg-tag">.mg-stat-value</span></div>
</div>
<h3 class="mg-sg-fam">mg-apply <span class="mg-sg-count">6</span></h3>
<p class="mg-sg-note">Used by <code>backups.md</code>. Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-apply-block"><span class="mg-sg-tag">.mg-apply-block</span></div>
<div class="mg-apply-keep"><span class="mg-sg-tag">.mg-apply-keep</span></div>
<div class="mg-apply-ok"><span class="mg-sg-tag">.mg-apply-ok</span></div>
<div class="mg-apply-panel"><span class="mg-sg-tag">.mg-apply-panel</span></div>
<div class="mg-apply-preview"><span class="mg-sg-tag">.mg-apply-preview</span></div>
<div class="mg-apply-warn"><span class="mg-sg-tag">.mg-apply-warn</span></div>
</div>
<h3 class="mg-sg-fam">mg-nav <span class="mg-sg-count">6</span></h3>
<p class="mg-sg-note">Used by <code>nav.md</code>. Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-nav"><span class="mg-sg-tag">.mg-nav</span><div class="mg-nav-group"><span class="mg-sg-tag">.mg-nav-group</span></div>
<div class="mg-nav-handle"><span class="mg-sg-tag">.mg-nav-handle</span></div>
<div class="mg-nav-item"><span class="mg-sg-tag">.mg-nav-item</span></div>
<div class="mg-nav-label"><span class="mg-sg-tag">.mg-nav-label</span></div>
<div class="mg-nav-url"><span class="mg-sg-tag">.mg-nav-url</span></div></div>
</div>
<h3 class="mg-sg-fam">mg-bar <span class="mg-sg-count">5</span></h3>
<p class="mg-sg-note">Used by <code>stats.md</code>. Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-bar"><span class="mg-sg-tag">.mg-bar</span><div class="mg-bar-fill"><span class="mg-sg-tag">.mg-bar-fill</span></div>
<div class="mg-bar-label"><span class="mg-sg-tag">.mg-bar-label</span></div>
<div class="mg-bar-row"><span class="mg-sg-tag">.mg-bar-row</span></div>
<div class="mg-bar-val"><span class="mg-sg-tag">.mg-bar-val</span></div></div>
</div>
<h3 class="mg-sg-fam">mg-code <span class="mg-sg-count">4</span></h3>
<p class="mg-sg-note">Used by <code>users.md</code>. Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-code"><span class="mg-sg-tag">.mg-code</span><div class="mg-code-box"><span class="mg-sg-tag">.mg-code-box</span></div>
<div class="mg-code-stale"><span class="mg-sg-tag">.mg-code-stale</span></div>
<div class="mg-code-token"><span class="mg-sg-tag">.mg-code-token</span></div></div>
</div>
<h3 class="mg-sg-fam">mg-wizard <span class="mg-sg-count">4</span></h3>
<p class="mg-sg-note">Used by <code>plugin-config.md</code>. Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-wizard"><span class="mg-sg-tag">.mg-wizard</span><div class="mg-wizard-actions"><span class="mg-sg-tag">.mg-wizard-actions</span><div class="mg-wizard-section-label"><span class="mg-sg-tag">.mg-wizard-section-label</span></div></div>
<div class="mg-wizard-title"><span class="mg-sg-tag">.mg-wizard-title</span></div></div>
</div>
<h3 class="mg-sg-fam">mg-dom <span class="mg-sg-count">3</span></h3>
<p class="mg-sg-note">Used by <code>domains.md</code>. Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-dom-chip"><span class="mg-sg-tag">.mg-dom-chip</span></div>
<div class="mg-dom-open"><span class="mg-sg-tag">.mg-dom-open</span></div>
<div class="mg-dom-tools"><span class="mg-sg-tag">.mg-dom-tools</span></div>
</div>
<h3 class="mg-sg-fam">mg-header <span class="mg-sg-count">3</span></h3>
<p class="mg-sg-note">Used by <code>the layout</code>. Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-header"><span class="mg-sg-tag">.mg-header</span><div class="mg-header-inner"><span class="mg-sg-tag">.mg-header-inner</span></div>
<div class="mg-header-tools"><span class="mg-sg-tag">.mg-header-tools</span></div></div>
</div>
<h3 class="mg-sg-fam">mg-perms <span class="mg-sg-count">4</span></h3>
<p class="mg-sg-note">Used by <code>files.md</code>. Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-perms-cell"><span class="mg-sg-tag">.mg-perms-cell</span></div>
<div class="mg-perms-head"><span class="mg-sg-tag">.mg-perms-head</span></div>
<div class="mg-perms-title"><span class="mg-sg-tag">.mg-perms-title</span></div>
<div class="mg-acl-body"><span class="mg-sg-tag">.mg-acl-body</span> the access rule, separated from the row's own actions above it</div>
</div>
<h3 class="mg-sg-fam">mg-preview <span class="mg-sg-count">3</span></h3>
<p class="mg-sg-note">Used by <code>edit.md</code>. Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-preview-frame"><span class="mg-sg-tag">.mg-preview-frame</span></div>
<div class="mg-preview-pane"><span class="mg-sg-tag">.mg-preview-pane</span></div>
<div class="mg-preview-toolbar"><span class="mg-sg-tag">.mg-preview-toolbar</span></div>
</div>
<h3 class="mg-sg-fam">mg-tokens <span class="mg-sg-count">3</span></h3>
<p class="mg-sg-note">Used by <code>domains.md</code>. Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-tokens"><span class="mg-sg-tag">.mg-tokens</span><div class="mg-tokens-empty"><span class="mg-sg-tag">.mg-tokens-empty</span></div>
<div class="mg-tokens-pick"><span class="mg-sg-tag">.mg-tokens-pick</span></div></div>
</div>
<h3 class="mg-sg-fam">mg-warning <span class="mg-sg-count">3</span></h3>
<p class="mg-sg-note">Used by <code>the layout</code>. Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-warning-bar"><span class="mg-sg-tag">.mg-warning-bar</span><div class="mg-warning-bar-close"><span class="mg-sg-tag">.mg-warning-bar-close</span></div></div>
<div class="mg-warning-error"><span class="mg-sg-tag">.mg-warning-error</span></div>
</div>
<h3 class="mg-sg-fam">mg-alias <span class="mg-sg-count">2</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-alias-302"><span class="mg-sg-tag">.mg-alias-302</span></div>
<div class="mg-alias-badge"><span class="mg-sg-tag">.mg-alias-badge</span></div>
</div>
<h3 class="mg-sg-fam">mg-box <span class="mg-sg-count">2</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-box"><span class="mg-sg-tag">.mg-box</span><div class="mg-box-danger"><span class="mg-sg-tag">.mg-box-danger</span></div></div>
</div>
<h3 class="mg-sg-fam">mg-cm <span class="mg-sg-count">2</span></h3>
<p class="mg-sg-note">Used by <code>edit.md</code>. Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-cm-content"><span class="mg-sg-tag">.mg-cm-content</span></div>
<div class="mg-cm-yaml"><span class="mg-sg-tag">.mg-cm-yaml</span></div>
</div>
<h3 class="mg-sg-fam">mg-col <span class="mg-sg-count">2</span></h3>
<p class="mg-sg-note">Used by <code>files.md</code>. Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-col-exp"><span class="mg-sg-tag">.mg-col-exp</span></div>
<div class="mg-col-mod"><span class="mg-sg-tag">.mg-col-mod</span></div>
</div>
<h3 class="mg-sg-fam">mg-connect <span class="mg-sg-count">2</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-muted"><span class="mg-sg-tag">.mg-muted</span></div>
<div class="mg-connect-pick"><span class="mg-sg-tag">.mg-connect-pick</span></div>
</div>
<h3 class="mg-sg-fam">mg-cred <span class="mg-sg-count">2</span></h3>
<p class="mg-sg-note">Used by <code>users.md</code>. Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-cred-reveal"><span class="mg-sg-tag">.mg-cred-reveal</span></div>
<div class="mg-cred-value"><span class="mg-sg-tag">.mg-cred-value</span></div>
</div>
<h3 class="mg-sg-fam">mg-diff <span class="mg-sg-count">2</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-diff-minus"><span class="mg-sg-tag">.mg-diff-minus</span></div>
<div class="mg-diff-plus"><span class="mg-sg-tag">.mg-diff-plus</span></div>
</div>
<h3 class="mg-sg-fam">mg-fm <span class="mg-sg-count">2</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-fm-fields"><span class="mg-sg-tag">.mg-fm-fields</span></div>
<div class="mg-fm-section"><span class="mg-sg-tag">.mg-fm-section</span></div>
</div>
<h3 class="mg-sg-fam">mg-holder <span class="mg-sg-count">2</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-holder-count"><span class="mg-sg-tag">.mg-holder-count</span></div>
<div class="mg-holder-line"><span class="mg-sg-tag">.mg-holder-line</span></div>
</div>
<h3 class="mg-sg-fam">mg-jsonl <span class="mg-sg-count">2</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-jsonl-more"><span class="mg-sg-tag">.mg-jsonl-more</span></div>
<div class="mg-jsonl-table"><span class="mg-sg-tag">.mg-jsonl-table</span></div>
</div>
<h3 class="mg-sg-fam">mg-line <span class="mg-sg-count">2</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-line"><span class="mg-sg-tag">.mg-line</span><div class="mg-line-lbl"><span class="mg-sg-tag">.mg-line-lbl</span></div></div>
</div>
<h3 class="mg-sg-fam">mg-lock <span class="mg-sg-count">2</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-lock"><span class="mg-sg-tag">.mg-lock</span><div class="mg-lock-dot"><span class="mg-sg-tag">.mg-lock-dot</span></div></div>
</div>
<h3 class="mg-sg-fam">mg-pager <span class="mg-sg-count">2</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-pager"><span class="mg-sg-tag">.mg-pager</span><div class="mg-pager-info"><span class="mg-sg-tag">.mg-pager-info</span></div></div>
</div>
<h3 class="mg-sg-fam">mg-protect <span class="mg-sg-count">2</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-protect-here"><span class="mg-sg-tag">.mg-protect-here</span></div>
<div class="mg-protect-lock"><span class="mg-sg-tag">.mg-protect-lock</span></div>
</div>
<h3 class="mg-sg-fam">mg-token <span class="mg-sg-count">2</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-token"><span class="mg-sg-tag">.mg-token</span><div class="mg-token-x"><span class="mg-sg-tag">.mg-token-x</span></div></div>
</div>
<h3 class="mg-sg-fam">mg-bars <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-bars"><span class="mg-sg-tag">.mg-bars</span></div>
</div>
<h3 class="mg-sg-fam">mg-bc <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-bc-root"><span class="mg-sg-tag">.mg-bc-root</span></div>
</div>
<h3 class="mg-sg-fam">mg-body <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-body"><span class="mg-sg-tag">.mg-body</span></div>
</div>
<h3 class="mg-sg-fam">mg-brand <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-brand"><span class="mg-sg-tag">.mg-brand</span></div>
</div>
<h3 class="mg-sg-fam">mg-breadcrumb <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-breadcrumb"><span class="mg-sg-tag">.mg-breadcrumb</span></div>
</div>
<h3 class="mg-sg-fam">mg-cap <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-cap-dormant"><span class="mg-sg-tag">.mg-cap-dormant</span></div>
</div>
<h3 class="mg-sg-fam">mg-checks <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-checks"><span class="mg-sg-tag">.mg-checks</span></div>
</div>
<h3 class="mg-sg-fam">mg-configbtn <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-configbtn"><span class="mg-sg-tag">.mg-configbtn</span></div>
</div>
<h3 class="mg-sg-fam">mg-dirty <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-dirty-note"><span class="mg-sg-tag">.mg-dirty-note</span></div>
</div>
<h3 class="mg-sg-fam">mg-domain <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-domain-note"><span class="mg-sg-tag">.mg-domain-note</span></div>
</div>
<h3 class="mg-sg-fam">mg-empty <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-empty"><span class="mg-sg-tag">.mg-empty</span></div>
</div>
<h3 class="mg-sg-fam">mg-err <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-err"><span class="mg-sg-tag">.mg-err</span></div>
</div>
<h3 class="mg-sg-fam">mg-foot <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-foot"><span class="mg-sg-tag">.mg-foot</span></div>
</div>
<h3 class="mg-sg-fam">mg-form <span class="mg-sg-count">4</span></h3>
<p class="mg-sg-note">Used by <code>plugin-config.md</code>. Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-form-entry"><span class="mg-sg-tag">.mg-form-entry</span><div class="mg-form-entry-header"><span class="mg-sg-tag">.mg-form-entry-header</span>
<div class="mg-form-name"><span class="mg-sg-tag">.mg-form-name</span></div></div></div>
<div class="mg-form-row"><span class="mg-sg-tag">.mg-form-row</span></div>
</div>
<h3 class="mg-sg-fam">mg-help <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-help"><span class="mg-sg-tag">.mg-help</span></div>
</div>
<h3 class="mg-sg-fam">mg-info <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-info"><span class="mg-sg-tag">.mg-info</span></div>
</div>
<h3 class="mg-sg-fam">mg-inline <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-inline-msg"><span class="mg-sg-tag">.mg-inline-msg</span></div>
</div>
<h3 class="mg-sg-fam">mg-inp <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-inp-wide"><span class="mg-sg-tag">.mg-inp-wide</span></div>
</div>
<h3 class="mg-sg-fam">mg-json <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-json-pre"><span class="mg-sg-tag">.mg-json-pre</span></div>
</div>
<h3 class="mg-sg-fam">mg-main <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-main"><span class="mg-sg-tag">.mg-main</span></div>
</div>
<h3 class="mg-sg-fam">mg-muted <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-muted"><span class="mg-sg-tag">.mg-muted</span></div>
</div>
<h3 class="mg-sg-fam">mg-new <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-new-group-row"><span class="mg-sg-tag">.mg-new-group-row</span></div>
</div>
<h3 class="mg-sg-fam">mg-no <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-no-password-warn"><span class="mg-sg-tag">.mg-no-password-warn</span></div>
</div>
<h3 class="mg-sg-fam">mg-ok <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-ok"><span class="mg-sg-tag">.mg-ok</span></div>
</div>
<h3 class="mg-sg-fam">mg-owner <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-owner-name"><span class="mg-sg-tag">.mg-owner-name</span></div>
</div>
<h3 class="mg-sg-fam">mg-page <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-page-title"><span class="mg-sg-tag">.mg-page-title</span></div>
</div>
<h3 class="mg-sg-fam">mg-prov <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-prov"><span class="mg-sg-tag">.mg-prov</span></div>
</div>
<h3 class="mg-sg-fam">mg-qr <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-qr"><span class="mg-sg-tag">.mg-qr</span></div>
</div>
<h3 class="mg-sg-fam">mg-readonly <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-readonly"><span class="mg-sg-tag">.mg-readonly</span></div>
</div>
<h3 class="mg-sg-fam">mg-recent <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-recent-dot"><span class="mg-sg-tag">.mg-recent-dot</span></div>
</div>
<h3 class="mg-sg-fam">mg-rwflag <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Used by <code>files.md</code>. Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-rwflag-g"><span class="mg-sg-tag">.mg-rwflag-g</span></div>
</div>
<h3 class="mg-sg-fam">mg-sec <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-sec"><span class="mg-sg-tag">.mg-sec</span></div>
</div>
<h3 class="mg-sg-fam">mg-section <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-section-label"><span class="mg-sg-tag">.mg-section-label</span></div>
</div>
<h3 class="mg-sg-fam">mg-shell <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-shell"><span class="mg-sg-tag">.mg-shell</span></div>
</div>
<h3 class="mg-sg-fam">mg-sidebar <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-sidebar"><span class="mg-sg-tag">.mg-sidebar</span></div>
</div>
<h3 class="mg-sg-fam">mg-signout <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-signout"><span class="mg-sg-tag">.mg-signout</span></div>
</div>
<h3 class="mg-sg-fam">mg-sort <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-sort-ind"><span class="mg-sg-tag">.mg-sort-ind</span></div>
</div>
<h3 class="mg-sg-fam">mg-sortable <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-sortable"><span class="mg-sg-tag">.mg-sortable</span></div>
</div>
<h3 class="mg-sg-fam">mg-split <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-split-bar"><span class="mg-sg-tag">.mg-split-bar</span></div>
</div>
<h3 class="mg-sg-fam">mg-sub <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Used by <code>plugin-config.md</code>. Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-sub-cb"><span class="mg-sg-tag">.mg-sub-cb</span></div>
</div>
<h3 class="mg-sg-fam">mg-subcount <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-subcount"><span class="mg-sg-tag">.mg-subcount</span></div>
</div>
<h3 class="mg-sg-fam">mg-submissions <span class="mg-sg-count">2</span></h3>
<p class="mg-sg-note">Used by <code>plugin-config.md</code>. Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-submissions-panel"><span class="mg-sg-tag">.mg-submissions-panel</span>
<table class="mg-submissions-table"><tbody><tr><td><span class="mg-sg-tag">.mg-submissions-table</span></td></tr></tbody></table></div>
</div>
<h3 class="mg-sg-fam">mg-table <span class="mg-sg-count">2</span></h3>
<p class="mg-sg-note">Wrap a table in <code>.mg-table-wrap</code> so a wide one scrolls inside its own box instead of pushing the row's buttons off the right-hand edge &mdash; which is what a long user-agent did to the Sessions table.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-table-wrap"><span class="mg-sg-tag">.mg-table-wrap</span>
<table class="mg-table"><tbody><tr><td><span class="mg-sg-tag">.mg-table</span></td></tr></tbody></table></div>
</div>
<h3 class="mg-sg-fam">mg-theme <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-theme-toggle"><span class="mg-sg-tag">.mg-theme-toggle</span></div>
</div>
<h3 class="mg-sg-fam">mg-toggle <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-toggle"><span class="mg-sg-tag">.mg-toggle</span></div>
</div>
<h3 class="mg-sg-fam">mg-undo <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-undo-bar"><span class="mg-sg-tag">.mg-undo-bar</span></div>
</div>
<h3 class="mg-sg-fam">mg-user <span class="mg-sg-count">1</span></h3>
<p class="mg-sg-note">Nested as the pages compose it: the outer class wraps the parts named after it.</p>
<div class="mg-sg-demo mg-sg-family">
<div class="mg-user"><span class="mg-sg-tag">.mg-user</span></div>
</div>

<script>
// THE OVERLAY SPECIMENS ARE TRIGGERED, not pinned.
//
// A guide has to show every component, and sixteen of them are position:fixed.
// The family cells contain theirs (.mg-sg-item below), but the modal and the
// toasts were rendered loose: the modal covered the whole page with nothing to
// close it, and two toasts sat over the corner of every section. Reported from
// the live guide - "a popup which sits over the other content, and cant be
// closed".
//
// Shown on demand instead, which also demonstrates the thing a static specimen
// cannot: how it behaves. The modal closes on Esc, on its overlay, and on
// either button - the three ways the real one closes.
function sgOpen(id) {
  var el = document.getElementById(id);
  if (el) { el.hidden = false; document.body.classList.add('mg-sheet-open'); }
}
function sgClose(id) {
  var el = document.getElementById(id);
  if (el) { el.hidden = true; document.body.classList.remove('mg-sheet-open'); }
}
document.addEventListener('keydown', function (e) {
  if (e.key !== 'Escape') return;
  var open = document.querySelectorAll('.mg-modal:not([hidden]), .mg-sheet:not([hidden])');
  for (var i = 0; i < open.length; i++) sgClose(open[i].id);
});
function sgToast(kind) {
  var t = document.createElement('div');
  t.className = 'mg-toast mg-toast-' + kind + ' mg-toast-in';
  t.textContent = kind === 'error' ? 'Could not save' : 'Row added';
  document.body.appendChild(t);
  setTimeout(function () { if (t.parentNode) t.parentNode.removeChild(t); }, 2600);
}

// SM698: PREVIEW MODE. `?style=<name>` renders this guide in a candidate sheet
// so an operator can see a style before committing to it.
//
// THE CANDIDATE MUST BE THE ONLY SHEET. Adding it alongside the active one
// would let a component the candidate does not style inherit the active
// style's rule and look finished - which is precisely the defect this guide
// exists to expose (SM686, SM697). A preview that hides gaps is worse than no
// preview, because it is believed. So the active sheet is REMOVED first.
//
// A closed set here as well: the value comes from a query string and reaches a
// <link href>. The server refuses an unknown name; so does this.
(function () {
  var m = /[?&]style=([a-z]+)/.exec(window.location.search || '');
  if (!m) return;
  var want = m[1];
  if (['classic', 'accessible', 'modern'].indexOf(want) < 0) return;

  var links = document.querySelectorAll('link[rel="stylesheet"][href*="/manager/assets/manager-"]');
  for (var i = 0; i < links.length; i++) links[i].parentNode.removeChild(links[i]);

  var l = document.createElement('link');
  l.rel = 'stylesheet';
  l.href = '/manager/assets/manager-' + want + '.css';
  document.head.appendChild(l);

  // Say which style is on screen. Without it a preview is indistinguishable
  // from the manager having changed under the operator.
  document.addEventListener('DOMContentLoaded', function () {
    var b = document.createElement('div');
    b.className = 'mg-status';
    b.textContent = 'Preview: the ' + want + ' style. Nothing has been changed.';
    document.body.insertBefore(b, document.body.firstChild);
  });
})();
</script>

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
/* Family composition: each class is labelled in place, and nesting is shown by
   indentation rather than by a diagram - the structure IS the specification.

   CONTAINED, for the same reason the grid cells are. Sixteen manager classes
   are position:fixed/absolute or full-viewport - the overlays, the editor root,
   the sheet, the command palette. Twice now this page has gone grey because a
   demo rendered one of them loose: once when the vocabulary was a grid without
   containment, and again when the grid was replaced by these family blocks and
   the guard was not carried over.

   `transform` creates a containing block for FIXED descendants as well as
   absolute ones; `overflow:hidden` clips what is sized to the viewport;
   `contain` stops layout escaping. The specimen still renders live. */
.mg-sg-family { display: block; position: relative; overflow: hidden;
  transform: translateZ(0); contain: layout paint; }
.mg-sg-family > div { padding: 0.35rem 0.5rem; margin: 0.25rem 0;
  border-left: 2px solid var(--mg-border); position: relative; overflow: hidden;
  transform: translateZ(0); contain: layout paint; max-height: 14rem; }
/* An overlay painting its block solid would hide the labels naming it. */
.mg-sg-family [class*="overlay"], .mg-sg-family .mg-sheet,
.mg-sg-family .mg-editor-root, .mg-sg-family .mg-modal,
.mg-sg-family .mg-palette, .mg-sg-family .mg-notif-panel,
.mg-sg-family .mg-header, .mg-sg-family .mg-warning-bar { opacity: 0.4; }
.mg-sg-tag { display: inline-block; font-size: 0.68rem; font-family: ui-monospace,
  SFMono-Regular, Menlo, monospace; color: var(--mg-text-muted); margin-right: 0.4rem; }
.mg-sg-count { font-size: 0.7rem; color: var(--mg-text-muted); font-weight: normal; }
.mg-sg-name { display: block; font-size: 0.72rem; color: var(--mg-text-muted);
  margin-bottom: 0.25rem; }
</style>
