---
id: SM1421
title: "SM1421: lazysite check and repair print what they mean, and nothing else"
subtitle: "The 0.16.9 repair on edge printed two untie warnings over sound stores, a backtick in a message, and a tally that hid the changes it applied."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-10
raised-by: "release manager, the 0.16.9 repair on edge"
area: check
status-note: "SHIPPED (PENDING): the upload-rate and login-rate counter checks drop the tie object before untie, so STDERR stays empty; \"front end`s\" reads \"front end's\"; a site left awaiting a decision after changes were applied reads \"awaiting your decision (2 changes applied)\". t/tools/562-564."
---

# What happened

The repair of 0.16.9 on edge printed "untie attempted while 1 inner references still
exist" twice, a message with a backtick where an apostrophe belongs, and, after
"--fix applied 2 change(s)", the line "0 clean, 0 repaired, 1 awaiting your decision".

# What changed

- The two counter checks in `tools/lazysite-check.pl` held the object `tie` returns
  while they untied. They drop it first. No other `untie` in `tools/` or `lib/` holds one.
- The engine-tree message reads "front end's deny rules". A test pins that no message
  in the check or the CLI puts a backtick between two letters.
- A site with a warning left counted as awaiting a decision by design (SM626), and
  still does. The line now adds "(N changes applied)" when the repair applied changes
  to such a site, from the check's own "--fix applied N change(s)" line, which the
  repair now reads as well as shows.
