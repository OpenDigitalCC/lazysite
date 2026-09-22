---
id: SM898
title: "SM898: an include lifts governed content into a public page"
subtitle: "0.14.3 test plan W5b, measured on the test site as an anonymous visitor: a draft section's partial and a read-restricted section's partial, each 404 when fetched directly, each printed in full into a public page carrying one `::: include` line. Introduced by SM888 A3 (0.14.3), which let an include reach the private store and asked nothing about who was reading."
brand: plain
standard-margins: true
status: partial
raised: 2026-09-22
raised-by: sites agent
area: security
status-note: "FIXED on claude/n148a, pending review and a field re-walk of W5b, which is why partial. THE FINDING, MEASURED (sites agent, edge.explore, 0.14.3, fresh browser, no cookie): acl-set /zz-w5p/ draft; /zz-w5p/partial.html and /zz-w5p/page both 404 to the public; /zz-w5-outside2.md containing `::: include /zz-w5p/partial.html` answered 200 with the partial's text in the body. Same for a read-listed section. REPRODUCED here before fixing: t/integration/104 written first, and its two 'outside' subtests failed on the shipped code with the governed text in an anonymous body. THE CAUSE: A3 widened the include's confinement from the content root to the root's twin in the private store, and the only thing it kept refusing - the only thing its test asserted - was the lazysite/ management tree; nothing anywhere asked whether governed content may leave its section, because before A3 the store was simply out of reach. THE RULE: governed content is includable only from a page under the SAME governing ACL entry. Identity-free by design - the refusal renders the same for every reader, so a cached public page cannot carry one reader's view to another - and a tighter rule nested inside a section is a different entry and refused for the same reason. _acl_governing_key recovers the winning entry's key by identity against the map rather than repeating the longest-match logic. Three sabotages fail the test: the rule removed, the rule loosened to 'any governed page', the key never found. A3's own case (a governed page including its own partial) is kept and asserted. NOT CLAIMED: that 0.14.2 refused the outside case. For MOVED content it did, by accident of location - the store was outside `_path_under`'s root; for draft content that never moved, it very likely did not, and this filing does not say either way. WHAT THE SITES AGENT SHOULD RE-WALK: W5b exactly as written, both protection kinds, after the next cut."
---

# What the field measured

Test plan W5b, on the test site, engine 0.14.3, all set-up over WebDAV and the
control API, then read as an **anonymous visitor** - a fresh headless browser
with no cookie:

```text
acl-set path=/zz-w5p/ body {"draft":1}
/zz-w5p/partial.html      <p>W5b protected partial</p>
/zz-w5p/page.md           includes /zz-w5p/partial.html   (inside)
/zz-w5-outside2.md        includes /zz-w5p/partial.html   (outside; never
                          rendered by anyone but the anonymous visitor)

anonymous GET /zz-w5p/page          -> 404   (draft, correct)
anonymous GET /zz-w5p/partial.html  -> 404   (draft, correct)
signed-in GET /zz-w5p/page          -> renders the partial (inside: PASS)
anonymous GET /zz-w5-outside2       -> 200, body contains
    "W5b protected partial"                  (outside: FAIL)
```

The same shape with `{"read":["agent-ai"]}` in place of the draft flag: the
partial 404 to the public, the outside page 200 with the partial's text.

The sites agent's reading, which is the right one: the engine's reason for
answering 404 on held-back content is that nothing should confirm the content
exists. One include line undid that, and on a multi-author site the person
who can write that line is exactly the sub-user whose grant stops at their own
folder.

# Reproduced, then fixed

`t/integration/104` was written first and run against the shipped code. Its
two "outside" subtests failed with the governed partial's text in an
anonymous body - the finding, in the suite. Then the fix.

# The cause

SM888 A3 ([[SM888]], 0.14.3): a page in a protected section could not include
its own partials, because gating moves content into a private store beside
the docroot and the include guard confined includes to the docroot. A3 widened
the guard to `_path_under_content`, which accepts the content root **or its
twin in the store**.

It kept refusing the `lazysite/` management tree, and `t/integration/103`
asserted that first, as the discipline requires. But that is the only thing
the assertion tested. Nothing anywhere asked whether governed content may
*leave its section*, because before A3 the store was out of reach and the
question never arose. A3 made the content reachable and the guard that should
have stood behind it did not exist.

# The rule

**Governed content is includable only from a page under the same governing
ACL entry.**

- A page inside the section is gated by that entry already, so it may include
  the section's own partials - A3's case, kept and asserted.
- A page anywhere else may not, **whoever is asking**.
- A tighter rule nested inside a section is a different entry, therefore a
  different audience, and is refused for the same reason.

Identity-free on purpose. The refusal renders the same for every reader, so a
cached public page cannot carry one reader's view to another; the engine
already refuses to cache governed pages, and this rule never makes an
ungoverned page's render depend on who asked.

`_acl_governing_key($abs)` returns the winning entry's key. It recovers it by
identity against the parsed map rather than by repeating `_acl_entry_for`'s
longest-match logic: two copies of "which rule wins" is how the two halves of
a rule come to disagree ([[SM268]] H10 was one such copy).

# How it is held

`t/integration/104`, driven without signing in - the rule never asks who is
reading, so a governed-but-readable section with a tighter rule nested inside
it shows both halves. Three sabotages, each failing the file: the rule
removed (the 0.14.3 behaviour), the rule loosened to "any governed page may
include any governed partial", the key never found.

# What is not claimed

- **That 0.14.2 refused the outside case.** For moved content it did, by
  accident of location. For draft content that never moved it very likely did
  not. Either way it fails on 0.14.3 and the fix is the same.
- **A field re-walk.** W5b as written, both protection kinds, after the next
  cut - that closes this.

# Related

[[SM888]] (A3, the widening), [[SM181]] (why a draft section answers 404),
[[SM286]] (why protected content lives in a store beside the docroot),
[[SM268]] (H10: the one copy of the matching logic).
