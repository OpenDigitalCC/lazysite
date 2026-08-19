---
title: "SM394: the trails have a reader"
subtitle: "SM393 recorded the ordered trails and nothing could read them. The agent that asked for them has no host access and sees only what analyse_visitors returns, so the data accumulated for an operator on the box and for nobody else. This is the read side: a trails selector, a discovery list, a declared response cap and an honest empty answer."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-08-19. analyse_visitors gains trails=YYYY-MM-DD across both channels (MCP tool and control API), and index gains trail_days. The day list is read from the DIRECTORY rather than the index file, because trails expire where the rollups do not and an index entry would outlive the file it names. The reply is capped at 200 visits and states the size of the day as well as the size of the answer, so a partial sample cannot be mistaken for a whole one. A day with no trails says whether it was never recorded or has expired instead of falling through to the rollups' generic 'no stats for that day/month'. t/lint/58 caught the Actions.pm drift on its own, which is the pin working. Documented in the agent briefing, which also had to AMEND its 'no time-on-page' claim: a step gap is a lower bound on the dwell for the page being LEFT, there is none for the exit page, and it must never be reported as how long somebody spent reading."
---

# Why this is its own change

[[SM393]] landed the recording, and said in its own filing that the requester
could not read what it wrote. That was the right order - the recording cannot
be backfilled and the analysis can - but it left a feature whose requester
could not observe it, which is indistinguishable from one that does not work.

# What was added

`--trails YYYY-MM-DD` on the plugin, and `trails` on both channels that reach
it: the MCP tool and the control API. Both validate to the same strict shape
and pass the value as an exec argument, as the SM213 selectors already did, so
it never reaches a shell.

`index` gains `trail_days`.

# Four decisions worth recording

Discovery comes from the directory, not the index
: Trails expire on a 30-day default and the rollups never do. A `trail_days`
  built from the index file would keep naming days whose files had already
  gone, sending callers after data that no longer exists. It reads the
  directory instead, so the list cannot outlive what it describes.

The response cap is declared, not silent
: The file holds up to 2000 visits; returning all of them in one body is a
  payload nobody asked for. But a truncated list that looks complete is worse
  than a short one, so the reply always carries `visits` (what the day holds)
  alongside `returned` and `truncated`. The briefing tells the agent to say so
  when reporting from a capped sample.

An empty day says WHICH kind of empty
: Falling through to the rollups' "No stats for that day/month yet" would be
  wrong twice - trails are neither a day rollup nor a month one, and a day
  whose trails have expired is a different fact from one that was never
  recorded. The refusal names trails, says it could be either, and points at
  `trail_days`.

The briefing's "no time-on-page" claim had to be amended
: It said the platform can report nothing needing JavaScript or cookies, and
  listed time-on-page among them. A step gap is a server-side interval between
  two requests: a **lower bound** on the dwell for the page being LEFT, blind
  to a page read in a background tab, and absent entirely for the exit page -
  which is where a visit usually ends. The briefing now says to report it as
  "at least N seconds before moving on" and never as reading time. Left alone
  it would have become a true statement sitting next to a field that quietly
  contradicted it.

# Still not here

The manager **Stats** page has no trails view. An operator on the box can read
the files and an agent can now call the selector; the human UI is the third
surface and is its own piece of work.

# Verification

`t/unit/plugins/15-the-trails-selector-answers-a-caller.t`, 22 assertions,
against six sabotages - each confirmed to apply and still compile before its
failure was counted: unwiring the selector so it falls through to the window
view; truncating without declaring it; not truncating at all; building
`trail_days` from the index file instead of the directory; restoring the
generic rollup error for a missing day; and dropping the day-shape guard.

`t/lint/58` failed on the Actions.pm parameter list before it was updated,
without being asked to. That is the SM350 pin doing exactly what it was built
for, and it is worth recording as a test that earned its keep.
