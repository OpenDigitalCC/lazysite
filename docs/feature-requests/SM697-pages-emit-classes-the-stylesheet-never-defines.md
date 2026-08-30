---
id: SM697
title: Manager pages emit classes the stylesheet never defines
raised: 2026-08-29
raised-by: release manager
area: manager-ui
status: shipped
status-note: "SHIPPED. Reported as formatting problems on Plugin Config; measuring found the same defect on seven more pages - TWENTY mg- classes emitted with no rule, six of them legitimate querySelector handles and fourteen real formatting bugs. Plugin Config's eight were fixed in 0.11.8, and the design sheets that landed in the same release defined the remaining twelve in all three variants, so the debt list is EMPTY and its ceiling is zero. THE GUARD ITSELF HAD GONE SILENT and that is the more serious half: t/lint/95 opened `manager.css` and skipped when absent, 0.11.8 renamed that file to manager-classic.css, and from that release the suite reported `1..0 # SKIP` while counting as a passing suite in every gate - a check that disables itself when its subject moves reports the same green tick either way. It now reads every shipped sheet, BAILS rather than skips when none is found, and names the variant a class is missing from. t/lint/96 carried the same skip and now bails too, and asserts the three sheets define one shared vocabulary - which is what makes reading `classic` alone legitimate."
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
