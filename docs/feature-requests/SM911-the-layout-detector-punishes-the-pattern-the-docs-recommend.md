---
id: SM911
title: "SM911: layout-activate warns that a layout does not render the nav when it does"
subtitle: "Activating a site-local layout reported renders nav 0, meta_title 0, meta_desc 0 and warned that nav.conf would have no effect on pages using it. All three are false, disproved by the rendered output of that same layout in that same activation: five nav items from nav.conf with one aria-current, a resolved title and a resolved description. The detector is a literal scan for `[% nav %]`, so it misses `[% FOREACH item IN nav %]` - the only way to render a multi-item nav - and it misses the local-variable assignment that `page_meta_title || page_title` requires, which the layouts briefing itself tells authors to write."
brand: plain
standard-margins: true
status: candidate
status-note: "RAISED 2026-09-27 from the sites agent's inbox report, reproduced on a live 0.14.4 site and disproved from the served page in the same activation. Nothing built. The false negative is expensive in a specific way: it tells an author their nav work is inert at the moment they have just done it correctly, so they either hunt a bug that does not exist or add a literal [% nav %] beside the loop to silence it. The reporter's suggested test is to match the variable as a word inside any TT tag rather than the exact three-token string, which accepts the loop, the assignment and the bare form while still catching a layout that never mentions the variable; an alternative worth weighing is reporting 'not detected' rather than asserting the negative in prose. Three further findings arrived with it, listed as their own rows - one of them, layout-delete, is an action that appears unreachable from a token client."
raised: 2026-09-27
raised-by: sites agent (inbox, 2026-09-27 19:00)
area: layouts, api
---

# The rows

| Ref | Cx | What |
|-----|----|------|
| LD1 | S | The nav and meta detectors match the variable as a word inside any TT tag, not as a literal three-token string. `[% FOREACH item IN nav %]` and `head_title = page_meta_title || page_title` both count, because the first is the only way to render a multi-item nav and the second is what the briefing's own `<head>` contract tells authors to write. A layout that never mentions the variable is still caught. The shipped `odcc` layout on another estate site uses the same loop form, so the warning presumably fires there too. |
| LD2 | S | `layout-delete` accepts no spelling of the parameter its error asks for. Eight were tried - `layout`, `name`, `layout_name`, `id`, `dir`, `slug`, and two body forms - and every one answered "Layout name required", while the sibling actions `layouts-available` and `layout-activate` both take `layout=` and work. From a token client the action appears unreachable. Whatever the accepted spelling is, the message should name it, per the house rule that a missing parameter is named as missing. |
| LD3 | XS | `ai-briefing-layouts.md` and `layouts.md` describe `theme_css` as a pre-rendered `<style>:root{...}</style>` block. Since SM352 it emits a stylesheet LINK with its own fingerprint, which is better - cacheable, separately versioned - and the docs describe the old shape. An author who wraps it in a `<style>` tag on the strength of the current wording gets a link nested inside a style element. The reporter went looking for a token in the page source, found nothing, and briefly concluded the token layer had not reached the browser. |
| LD4 | XS | `MKCOL` on a collection that already exists answers 405 for `/assets/` and 403 for `/lazysite/layouts/`. Both mean "already there" and only one is RFC 4918's answer. The likely cause named in the report is the scope check running before the existence check. |

# Why LD1 is the one to do first

The warning is well-intentioned and the fault it looks for is real: a layout with
no nav at all is a genuine trap. But it fires on the correct pattern, and the
author most likely to hit it is the one who has just written a working nav loop
and saved `nav.conf`. On the reported deploy the warning was only known to be
wrong because the layout had already been rendered offline and the live page
checked afterwards.

# Not verified here

This agent has not re-measured any of the four. The grade is the reporter's:
reproduced on a named live 0.14.4 site, with the served page quoted as the
disproof.
