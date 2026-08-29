---
id: SM697
title: Manager pages emit classes the stylesheet never defines
raised: 2026-08-29
raised-by: release manager
area: manager-ui
status: partial
status-note: "PARTIAL. Reported as formatting problems on Plugin Config; measuring it found the same defect on seven more pages. TWENTY mg- classes are emitted with no rule in manager.css - six are legitimate querySelector handles, FOURTEEN are purely visual and therefore real formatting bugs. Plugin Config's eight are FIXED in 0.11.8; the remaining twelve are enumerated in t/lint/95 as known debt so a NEW one fails immediately while the backlog is paid. This is SM686 a second time: an element carrying a class nothing defines renders as unstyled inline content, nothing errors, and the source looks correct - only the rendered page says otherwise."
---

# What was reported

Formatting problems on the Plugin Config page.

# What it turned out to be

Eight classes emitted by that page's script had **no rule in `manager.css` at
all**: `mg-form-entry`, `mg-form-entry-header`, `mg-form-name`,
`mg-handler-edit-form`, `mg-handler-submissions`, `mg-submissions-panel`,
`mg-submissions-table`, `mg-sub-cb`.

So the Form Connections list ran together as a paragraph, the submissions table
had no table styling, and the panels that open under a handler sat flush against
the row above - reading as part of the previous handler rather than as this
one's detail.

# The same defect, on seven more pages

Measured across every manager page: **twenty** `mg-` classes are emitted with no
rule. Six are read back with `querySelector`/`closest` and are legitimately
unstyled - a handle, not an appearance. **Fourteen are purely visual**, which
makes them real formatting bugs:

| Page | Classes with no rule |
| --- | --- |
| `backups.md` | `mg-apply-panel` |
| `config.md` | `mg-config-preset`, `mg-readonly-value`, `mg-field-note` |
| `domains.md` | `mg-dom-tools`, `mg-dom-chip`, `mg-dom-open` |
| `files.md` | `mg-recent-dot`, `mg-protect-lock`, `mg-file-select` |
| `groups.md` | `mg-recent-dot` |
| `stats.md` | `mg-split-bar` |
| `users.md` | `mg-recent-dot`, `mg-onb-warn` |

# Why it keeps happening

This is [[SM686]] a second time - there, the capability grid's hint marker
carried `mg-cap-what`, which had no rule, so a `?` sat in the label text reading
as punctuation rather than as a control.

The defect survives review because **nothing is wrong with the code**. The class
is spelled correctly, the markup is well formed, no error is raised, and the
page looks written. Only the rendered page says otherwise, and a reviewer
reading a diff is not looking at the rendered page. The same blind spot produced
[[SM689]] (markup discarded between the source and the browser) and [[SM687]] (a
panel built on a verb that refuses).

# What is done, and what is not

**Done in 0.11.8**: Plugin Config's eight rules, written from what the markup is
plainly trying to be - a list with separated entries, a table with a checkbox
column that is checkbox-width, and panels with enough separation to belong to
the row they opened from.

**Done**: `t/lint/95` refuses any NEW `mg-` class with no rule. The twelve
remaining visual classes are enumerated in it as known debt with two guards: the
list may not grow, and an entry that has quietly been fixed must be removed
rather than left as a waiver protecting nothing.

**Not done**: those twelve. They want writing against the rendered pages rather
than guessed at from class names - `mg-split-bar` and `mg-recent-dot` in
particular are appearance decisions, and inventing them blind would produce
twelve arbitrary choices that somebody then has to unpick.

# Related

[[SM686]] (the same defect, one class), [[SM689]] (the other way a page can be
right in source and wrong in the browser), [[SM694]] and SM635.

# Not started
