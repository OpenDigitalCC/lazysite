---
title: "Test plan - 0.15.1 on edge"
subtitle: "What a green gate does not say about this release. Eight release-specific checks that only a deployed host can run, the three standing tiers, and - unusually - a list of things this build does wrong on purpose, because three defects were filed during the release and a tester will meet all three."
brand: plain
standard-margins: true
---

# What this plan is for

0.15.1 was gated at 972 files and 15,077 tests, and the instrumented suite passed
at 972 / 15,072. That number is silent about three kinds of thing in this release.

**One behaviour has NO automated test at all, and that is recorded rather than
hidden.** SM919 pins two table cells with `position: sticky`. That is a rendering
behaviour: the classes and rules it needs are checked in both directions by
t/lint/96, and a test asserting the CSS text would assert the spelling rather than
the effect. R1 and R2 are the only verification it will ever get.

**Most of the rest is about what happens when a file cannot be read**, and the
suite reaches that by chmod-ing a temporary file in a temporary tree. The faults
this release repaired were found on real hosts, against files owned by real
accounts and unreadable by the real server user - a shape the suite cannot build
because it has no second identity.

**And two of the repairs prevent DATA LOSS.** R7 is the most valuable row on this
plan for that reason: before this build, an unreadable file turned an append into a
truncation in one place and appended a duplicate key in another.

Every row below is a case where the code is complete, green, and unverified
against a host.

# The order

1. 0.15.1 is deployed to edge already - repair clean, probe clean, nothing
   exposed. Record the version the check panel REPORTS, not the tarball's.
2. **R1 first.** It is the row with no other safety net, and it needs nothing set
   up but a form with several fields.
3. R7 next, because it is the data-loss pair.
4. R3 to R6, the four-state rows, which all need a deliberately unreadable file.
5. R8, which is two commands.
6. Tier A before any promotion to beta or stable. **A1 and A2 were rewritten in
   0.15.1's predecessor and have never been walked - their first run is also their
   first verification**, so a surprise there is as likely to be the check as the
   code.

Everything that makes a file unreadable is **edge only**, and every such row ends
by restoring the mode. Note the mode before you change it.

# Release-specific checks

## R1 - the row's two controls stay reachable at any scroll position (SM919)

**Do this first.** Manager -> Extension Config -> a form handler's **Submissions**,
on a form with enough fields to make the table wider than the window. A contact
form with eight fields does it on a laptop; if no such form exists on edge, make
one - the width is the whole point.

Scroll the table **fully to the right**.

*You should see:* the tick box still at the left edge and Delete still at the right
edge, with the form's data having scrolled between them. Now tick a row and delete
it **without scrolling back**. That is the defect this fixes: before, the two were
at opposite ends of the data rather than of the window.

Also check the window itself: it should be a large box of the **same size every
time**, about 90% of the display. Previously it capped at 1000px and sized itself
to its contents, so it opened differently for each form.

It is a FAIL if either control scrolls out of view, if a pinned cell is
transparent and shows data sliding underneath it, if hovering a row no longer
highlights the pinned cells along with the rest of it, or if the box is not the
same size for two different forms.

## R2 - the style guide demonstrates it (SM919)

Manager -> **Style guide**, find `mg-submissions`, and scroll the demo table
sideways.

*You should see:* the same pinning, in a demo with eight columns and two rows, one
marked quarantined. Before 0.15.1 that demo was a table containing **one cell**, so
this state could not be seen on the page whose whole purpose is showing what a diff
cannot.

This row exists because it is the thing a future walk can catch a regression in.
If the demo is one cell again, the guide has lost the only representation of this
behaviour.

## R3 - an agent can read the bell, and only with the capability (SM918)

Needs a partner token. Two of them if possible: one whose grant includes
`notifications`, one whose does not.

*You should see:* `read_notices` in `tools/list` for the first and **absent** for
the second. Call it, and compare what it returns against the bell in the manager
header - same notices, newest first.

`last_seen` is **0** and `unread` equals the total, for every agent, always. That
is correct and documented: marking-seen is an operator action with no MCP twin,
because a read cursor per partner is the first half of an inbox. It is a FAIL if
those two fields ever say anything else, not a FAIL that they say this.

## R4 - an unreadable notice store is not a quiet bell (SM918)

Edge only. `chmod 000 lazysite/logs/notices.jsonl`.

*You should see:* the read report `store_unreadable` with a sentence saying the
empty list means nothing was checked rather than that nothing is wrong - over MCP
and on the control API, because both go through one reader now. And the engine log
carries a WARN naming the **file, the errno and the unix user**.

Restore the mode. It is a FAIL if either surface reports an empty bell, and a FAIL
if the log line is missing any of those three fields.

## R5 - an unreadable ACL store is not a clean bill (SM917)

Edge only. `chmod 000 lazysite/auth/acls.json`, then run `audit_site` over MCP.

*You should see:* `acl_keys_unreadable` present, naming the errno, AND
`acl_keys_matching_nothing` **empty**. Those two together are the point: the empty
list used to be the whole answer, and it renders as "your access rules are fine".
The engine log should carry the `cannot_read` line too - the agent gets the state,
the sysop gets the log, and before this build the sysop got nothing.

Restore the mode.

## R6 - an unreadable auth secret says so (SM917)

Edge only. Note the mode of `lazysite/auth/.secret`, `chmod 000`, then request any
page as a visitor.

*You should see:* a WARN in the engine log naming the file, errno and unix user.
The page still serves and visitor counting continues - the fallback is deliberate.
What was wrong before is that the fallback happened **silently**, which re-keyed
every visitor token, so returning visitors began counting as new ones and it looked
like traffic rather than a fault.

Restore the mode. It is a FAIL only if nothing is logged.

## R7 - the two that were losing data (SM917 step 2)

The most valuable row here. Edge only, and do these one at a time.

**(a) the visitor-trail export.** Find a day file under the stats trail directory
that already has content, note how many trails it holds, `chmod 000` it, and run
the visitor export.

*You should see:* that day **skipped and reported**, and when you restore the mode,
the day's existing trails **still there**. Before this build the export read the
day to append to it, got nothing, and wrote the file with only the new rows - the
append became a truncation.

**(b) the conf key writer.** Pick a key `_ensure_conf_key` manages, confirm it is
present in `lazysite/lazysite.conf` **once**, `chmod 000` the conf, and trigger the
path that would set it.

*You should see:* a refusal and a log line, and after restoring the mode, that key
still present **exactly once**. Before, the read that makes the write idempotent
found nothing and a second entry was appended for a key that already had one.

It is a FAIL if either file loses content. Count before and after; do not judge by
eye.

## R8 - the perf gauge is the same on a host as it is here (SM916)

Two commands on edge: `perl tools/bench.pl` twice, and compare
`work_cold_log_bytes`.

*You should see:* the **identical** number both times. That gauge used to move
between runs because its fixture wrote float timestamps, so it read the clock and
not the code - which refused about nine cuts in ten. A host is a different clock,
which is the only reason this is worth doing away from the build machine.

# THINGS THIS BUILD DOES WRONG, AND WHICH ARE ALREADY FILED

Read this section before walking anything. Three defects were reported during this
release and are **not fixed in it**. A tester will meet all three, and re-reporting
them costs a day.

**SM921 - every `tel` field accepts anything.** Type a single letter into a phone
field and it will be accepted. The shipped default pattern is a valid Perl regex
and an invalid HTML one: browsers compile the attribute with the `v` flag, under
which bare parentheses and a bare hyphen inside a character class are a syntax
error, and the spec's answer to a pattern that will not compile is to ignore it
entirely. Separately, an author's own `pattern:` is truncated at its first space.
**Do not file this again. Do not trust any `tel` validation in this build.**

**SM922 - the link audit reports things that are not links.** If you run it,
roughly three entries in ten are real. It reads JavaScript string literals and
Markdown syntax examples as links, resolves relative paths against the site root
rather than the page's directory, resolves system pages without the fallback chain
so `/login` is reported broken while it answers 200, resolves draft sections
anonymously so protected pages look missing, and **scans its own previous report**,
so the count moves between runs with no change to the site. Two real broken links
in shipped docs (`/docs/views`) are in there and are still unfixed.

**SM920 - `theme-activate` can silently activate the wrong theme.** If you supply
both `path` and `theme`, `path` wins, the theme you asked for is discarded, and the
call answers `ok:true` while serving the old theme. **Use one parameter.** Verify
what is served by reading the stylesheet URL from the page, not by trusting the
response.

Also still open from the 0.15.0 walk and not addressed here: the Domains group
picker saves nothing and records nothing; Undo does not restore; the protection
card shows Gated for a draft section; and the stats error-log tail guards with `-r`
before calling its reader.

And two warnings the deploy reported which are **not** from this release: twelve
data tables that name no domain on a nine-domain instance, and an account called
`manager` which the warning itself says predates SM659.

# How to report

One line per row: **PASS**, **FAIL** or **SKIPPED** with the reason. For a FAIL,
what you did and what you saw, in that order - and for R7 the counts before and
after, because "it looked fine" and "the file still has 14 trails" are different
claims.

A surprise that is not covered by any *You should see* line above is worth writing
down even so. Tier A's A1 and A2 have never been walked, so there especially, a
mismatch may be the check rather than the engine.
