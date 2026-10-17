---
id: SM1143
title: "SM1143: the note-on-focus test waits for what it checks"
subtitle: "t/unit/manager/349 reruns a browser that returned nothing and polls for the note, so it is deterministic under load."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: "lazysite developer agent, from the 2026-10-17 integration runs"
area: tests
status-note: "SHIPPED on n633: t/unit/manager/349-a-note-shows-on-focus.t only; no CSS change."
---

# What happened

`t/unit/manager/349-a-note-shows-on-focus.t` (SM1104) failed twice on
2026-10-17 in the integration precheck, which runs many test files in parallel,
both times on the same two assertions and only for the modern style:

    #   Failed test 'modern: focusing the mark shows its note'
    #   Failed test 'modern: and at the right edge too'

Run alone it passed every time (4 of 4 on main and on a branch).

The stylesheets are not at fault: manager-modern.css has no transition or
other timing on the note, and the three sheets draw it with the same rule.
Reproduced by running the unchanged test 96 ways at once on 8 cores: 94 of 96
failed classic's two assertions, 86 modern's and 76 accessible's, never the
"idle mark shows nothing" one. The browser returned no document at all (the
test's 60 s `timeout` killed it, or it dumped before the page script ran), the
test decoded that as an empty result, "idle shows nothing" passed on the empty
string, and the two focus assertions failed. Which style loses is whichever
browser is starved that time.

# What shipped

The test now runs the browser again (up to four times, 120 s each) until the
page reports it ran to the end, and asserts that as its own check ("the browser
ran the page to the end"), so a browser that returned nothing is named as that
instead of as a missing note. The page script waits for what the test asserts:
after the load event (which follows the stylesheet) it focuses the mark and
reads the computed `::after` content again every 50 ms until the note shows or
200 reads have passed, then does the same for the right-edge mark. What is
asserted is unchanged, and a sheet whose `:focus-visible` rule is missing still
fails (checked by removing the modern rule).
