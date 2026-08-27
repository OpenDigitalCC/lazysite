---
title: "SM463: the Edit link on a gated page carries a server filesystem path"
subtitle: "The private store is named after the docroot, so a bare prefix strip left -lazysite-private/... in the link. That travelled into browser history, bookmarks, Referer headers and screenshots - and opened a blank editor."
brand: plain
standard-margins: true
status: shipped
status-note: "FILED AND SHIPPED 2026-08-21, in 0.10.22 (a426d1b). BACKFILLED after t/lint/26 was widened to see qualified bullets. THE CAUSE: page_source stripped $DOCROOT off the source path with no boundary. Gating MOVES content to <docroot>-lazysite-private (SM286), which BEGINS with the docroot, so for a gated page the strip matched as a bare string prefix and left '-lazysite-private/intranet/tasks/index.md'. ONE FAULT, TWO SYMPTOMS: the admin bar put that into /manager/edit?path=..., so a server filesystem path travelled into browser history, bookmarks, Referer headers and screenshots; and the same spelling fails validate_path, which joins it back onto $DOCROOT, so the link opened a blank editor. FIXED by using _content_rel, which requires '$DOCROOT/' WITH the slash before falling back to the private root. THE SHAPE IS SEC-2026-07 (H3) AGAIN - a sibling whose name is a superset of the boundary - WITH ONE DIFFERENCE THAT MATTERS: there the colliding name depended on somebody creating public_html.bak, so the bad case was possible. Here the software creates the colliding name itself, so the bad case exists on every site that gates anything. THE TEST IS STRUCTURAL rather than a render: the render subtests in that harness return a bare status line for fixtures that render correctly outside it, and asserting on the source would have been a source-grep. It drives _content_rel over both trees and asserts the link key for a gated page equals the key for the same page ungated - the property that was violated. Sabotage-verified: restoring the bare strip fails it. SM460 later found the SAME bare-prefix fault in a second place, the scan's URL derivation."
---

# One fault, two symptoms

```datatable
columns: Symptom | Consequence
widths: 6cm | X
bold: 1
tone: medium
---
`-lazysite-private/...` in the URL | a server filesystem path in history, bookmarks, `Referer`, screenshots
The same link fails `validate_path` | the editor opens blank
```

The second symptom is what gets reported; the first is the one that matters
and leaves no trace in the manager.

# Why this shape keeps recurring

`index($path, $DOCROOT) == 0` is true for a sibling whose name merely *starts
with* the docroot. SEC-2026-07 (H3) was the same fault, and there the
colliding name depended on somebody having created `public_html.bak`.

Here the software creates the colliding name itself. There is no
misconfiguration to blame and no site to exempt: every site that gates
anything has a directory whose name is a superset of its docroot's.
