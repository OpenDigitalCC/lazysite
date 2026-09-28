---
title: "Test plan - 0.15.0 on edge"
subtitle: "What a green gate does not say about this release. Thirteen release-specific checks that only a deployed host can run, the three standing tiers, and the discriminating measure each one needs to count as a pass."
brand: plain
standard-margins: true
---

# What this plan is for

0.15.0 was gated at 950 files and 14,875 tests, and that number is silent about
every behaviour in this release that lives on a host. The release's own theme
makes the gap sharper than usual: **most of what shipped is about what happens
when a store cannot be read or written**, and the suite reaches that by making a
temporary file unreadable in a temporary tree. The field report that started the
work was about a real file, owned by a real account, unwritable by the real
server user - a shape the suite cannot construct because it has no second
identity.

So this plan is not a re-run of the suite in a browser. Every row below is a
case where the code is complete, green, and unverified against a host.

Refs are this plan's. The source ref is given so each row traces back to the
filing and the changelog entry that shipped it.

# The order, and why the first row is a smoke test

1. Deploy 0.15.0 to edge.
2. **T6 first**, before anything else. It is the row most likely to fail
   outright, and if it fails nothing else on the list can be walked.
3. The incident thread (T1-T5), because it is why this release exists.
4. Uploads (T7-T9), the live halves already named in filings (T10-T13).
5. Tier A before any promotion to stable.

# The deploy is itself the first measurement

`dist/lazysite-0.15.0.tar.gz` (sha256 `06961ae6...`) is the artefact, and the
install verbs are the three SM899 separated: `install`, `upgrade`, `reinstall`.
The edge site is an upgrade. Two things in this release only appear on a **fresh**
install and one of them is T5, so the plan needs a fresh docroot somewhere on
edge as well as the upgrade of the existing one - a throwaway site is enough.

Record the version the check panel reports after the upgrade, not the version of
the tarball that was unpacked. They have disagreed before, and `action_version`
now reports an unreadable install state rather than a version it could not read.

# Release-specific checks

## T6 - the deployed CGI finds the table it now depends on (SM662)

**Do this first.** The control API's capability gate used to be a literal inside
`lazysite-manager-api.pl`. It is now `%GATE` in
`lib/Lazysite/ControlApi/Actions.pm`, and the CGI asks the module for it at run
time. That is a new run-time dependency on a file an upgrade must have replaced.

| | |
| --- | --- |
| Do | Call any control-API action over the token channel. |
| Measure | It answers. A **500 from every action** is what a stale `lib/` tree looks like, and it would be total. |
| Then | From a token whose account holds a narrow set of capabilities, call three actions: one gated on a capability the account **holds**, one gated on a capability it does **not**, and one that is **cookie-only**. |
| Measure | The held one works. The unheld one refuses **naming the capability**. The cookie-only one refuses for **absence from the gate** - a different message from a missing capability, and conflating the two is exactly the drift this row exists to catch. |

The suite proved the two tables agreed before the move and that all 156 actions
resolve identically after it (`t/lint/98-the-control-api-copy-agrees-with-the-gate.t`).
What it cannot prove is that the host loads the module.

## T1 - the audit trail says which of six states it is in (SM907 AT2)

| | |
| --- | --- |
| Do | With the trail appendable, read the audit surface and write down the state word. Then reproduce the field shape: the trail owned by another account, mode 0664, **not writable by the server user**. Read it again. |
| Measure | The state word **changes** - appendable to unwritable - and the second reading carries a `why` and a `repair`. |
| Fail | An unwritable trail renders a healthy-looking empty list; or the state word is the same both times. |

One reading proves nothing. A hard-coded state and a computed state are
indistinguishable from a single observation, which is why both readings are the
check.

## T2 - an unopenable trail is refused, not answered empty (SM907 AT2)

| | |
| --- | --- |
| Do | Make the trail unreadable (mode 000 is enough). Call the audit action over the token channel. |
| Measure | A refusal with `kind` `store-uninspectable` and `reason` `open`. |
| Fail | HTTP 200 with zero rows. That is the four-state-boolean failure this release is named after: *cannot read* rendered as *nothing happened*. |

## T3 - an unreadable group store stops offering roles and stops inventing labels (SM906 + remainder)

This is the reported host's exact shape, so a pass closes the field report.

| | |
| --- | --- |
| Do | With the group settings store readable, open the Add User picker and write down every group offered. Set the store to mode 000. Reload. |
| Measure | The backend groups that were **absent** (`cap-content`, `ch-ui` on the reported host) are **still absent**. Unknown is not yes. |
| And | The users page **says the store is unreadable** rather than presenting a raw group name as somebody's chosen label. |
| Fail | Any group appears that was not offered when the store was readable. |

Covered server-side by `t/tools/88-an-unreadable-group-store-is-not-an-empty-one.t`,
sabotaged both ways. What is unverified is that the page asks.

## T4 - the check names the consequence, and the log readers admit what they could not open (SM907 AT4, AT6)

| | |
| --- | --- |
| Do | With the audit log unwritable, run the shipped check on edge. Then make one rotated log unreadable and read the stats export. |
| Measure | The audit line says **events are being lost as they happen** - not that the manager cannot save it, which no manager does. |
| And | The export carries `logs_unreadable` naming the file that would not open. |
| Fail | A count that is merely short, with nothing saying why. A quiet site and a site whose logs will not open must not look alike. |

The main access-log read already refused and named the fault before this release;
the secondary readers - a tail, the rotated logs, the form-event files - were the
silent ones (`t/tools/90-a-log-that-will-not-open-is-not-a-quiet-site.t`).

## T5 - a fresh install gives a forms `.example` 0640 (SM907 AT5)

| | |
| --- | --- |
| Do | Install 0.15.0 to a **fresh** docroot and stat the forms examples. |
| Measure | 0640, and `smtp.conf.example` in particular - it shipped 0644, and the copy an operator fills in with an SMTP password inherited that mode. This was the **second** failure the field check reported. |
| Note | An upgrade does not re-mode an existing file. Only a fresh install measures this, which is why the deploy section asks for a throwaway site. |

## T7 - an uploaded photograph reaches a service (SM905 U1)

| | |
| --- | --- |
| Do | A native form with a file input, bound to a connector handler with `attach_files` on, pointed at a destination that echoes what it receives. Submit a photograph under the ceiling. |
| Measure | The destination receives filename, type, size and base64 data, **and the bytes round-trip** - compare a digest of what was sent against what arrived. |
| Fail | An arrival that is merely non-empty. Non-empty does not distinguish a whole photograph from part of one, and that distinction is the entire design of the ceiling. |

## T8 - the ceiling refuses rather than truncating (SM905 U1)

| | |
| --- | --- |
| Do | Submit a phone photograph against the default `attach_max_kb` of 1024, which is deliberately below one. |
| Measure | A refusal naming the size, the ceiling and the setting that raises it - **and nothing at the destination.** |
| Fail | Anything arriving at all. A partial delivery is worse than none, because the destination cannot tell it was given part of a photograph. |

## T9 - `capture` opens the camera (SM905 U3)

| | |
| --- | --- |
| Do | A form field declaring `capture:environment`, opened on a **phone**. |
| Measure | The camera opens rather than a file picker. |
| Note | A desktop browser ignores the attribute, so a desktop pass proves nothing about this row. The rendered attribute is suite-covered (`t/unit/forms/21-a-file-field-can-ask-for-the-camera.t`); the device behaviour is not. |
| Watch | `Permissions-Policy` is the likeliest blocker. `camera=()` stops `getUserMedia` everywhere; a file input with `capture` is not `getUserMedia` and should be unaffected. If it is affected, that is SM710's row and a finding worth filing. |

## T10 - sweep what each site actually serves for a third-party origin (SM888 C1, live half)

`t/lint/151-no-third-party-origin-in-a-shipped-stylesheet.t` now covers
everything lazysite ships. It cannot cover a theme an operator installed, and the
live breach was **line 1 of a theme stylesheet** - which a scan of the rendered
page certifies as compliant.

| | |
| --- | --- |
| Do | For each site: fetch the rendered page **and every stylesheet it links**, one level down into `@import`. |
| Measure | No `@import` and no `url()` naming another origin. |
| Fail | Any. Five sites did this for months and no upgrade reported it, which is the finding the reporter actually filed: the silence was the defect and the fonts were the symptom. |

## T11 - MKCOL on an existing collection answers one thing (SM911 LD4)

| | |
| --- | --- |
| Do | MKCOL `/assets/` and `/lazysite/layouts/` over WebDAV, where both already exist. |
| Measure | Both answer **405**, which is RFC 4918's answer for "already there". |
| Reported | 405 for one and 403 for the other, the likely cause being the scope check running before the existence check. |
| Note | Never reproduced here - it needs a WebDAV client against a real host. Edge is where it becomes possible, and the row stays open in SM911 until it is. |

## T12 - activating a layout with a nav loop no longer warns (SM911 LD1)

| | |
| --- | --- |
| Do | Activate a layout whose nav is `[% FOREACH item IN nav %]` and whose title is `page_meta_title \|\| page_title`, against a `nav.conf` with five items. Read the activation report **and** the served page. |
| Measure | Non-zero nav and meta counts, **and** five nav items in the served page. |
| Fail | Either half alone. A report that agrees with itself is not evidence; the reported defect was precisely a report saying zero about a page that rendered five. |

## T13 - the published copy and the brief agree (SM910)

| | |
| --- | --- |
| Do | Fetch `/.well-known/ai-partner` on edge and call `whoami` with a partner key. Compare the two. |
| Measure | `services` are explicit booleans; the document's own note says its list describes the **site** and only `whoami` confirms a grant. |
| And | PUT `lazysite/nav.conf` over WebDAV holding `manage_nav` and **not** `manage_config`. It is accepted - that is the capability the endpoint enforces, and the capability both documents now name (`t/tools/89-the-brief-and-the-published-copy-answer-different-questions.t`). |

# The standing tiers

Defined in `docs/MANUAL-CHECKS.md`. Each round goes in
`docs/manual-check-register.md` against the version walked.

| Tier | What it gates | State going into 0.15.0 |
| --- | --- | --- |
| A (A1-A4) | **STABLE**, not the cut and not beta - release-manager decision of 2026-08-20 | **Never recorded at any version.** The register says so in its own words. Four checks, about twenty minutes, in a browser as an operator; a tester-facing version is `docs/MANUAL-CHECKS-WALKTHROUGH.md`. |
| B (B4-B8) | The minor bump | B4, B6, B7, B8 passed on 0.14.4. **B5 could not be run** - there is no path-scoped manager account on edge, `ai-ui-tester` being deliberately unscoped. The 0.13.16 pass is the last measurement. |
| C (C10-C12) | Nothing - opportunistic | C9 retired 2026-09-22 (the counts it named went with SM635's card). |

The manager guide was walked end to end on 0.14.4 and its drift corrected in
SM902. 0.15.0 changed layout activation and the partner brief, so the affected
chunks are worth a re-read rather than the whole guide again.

# What each row needs to be walked

| Surface | Rows |
| --- | --- |
| Token channel, from here | T2, T6, T7, T8, T10, T11, T12, T13 |
| A shell on the host | T1, T3, T4, T5 (each needs a file's owner or mode changed, which is the whole point of them) |
| A browser | T1 and T3's second half, Tier A, Tier B, Tier C |
| A phone | T9 |

T1, T3, T4 and T5 change file ownership or modes on a deployed site. Edge is the
site where that is allowed to happen; none of these belongs on a live one.

# Where the results go

One row per check per version in `docs/manual-check-register.md`, naming who
walked it. **A partial pass is recorded as a partial pass** - "steps 1 to 3,
stopped at 4" is a useful record and "done" is not, if it was not. A finding
becomes a filing; the register says what was looked at, never what was wrong.

# What this plan does not cover

`docs/MANUAL-CHECKS.md` lists areas out of the suite's reach that 0.15.0 did not
touch: the vhost templates, multi-domain serving, the FastCGI pool, delivery by
email and chat, and the front end that answers first. They are unverified on this
version in the sense that they are unverified on every version, and nothing in
this release moved them. Naming them is how this plan stays honest about its own
scope.

# Related

[[SM907]] (the audit trail's six states, and the tail that closed it),
[[SM906]] (an unreadable auth store), [[SM662]] (one table decides),
[[SM905]] (an uploaded file reaches a service), [[SM888]] (the field backlog,
C1's live half), [[SM910]], [[SM911]] (LD4 still open),
[[SM710]] (Permissions-Policy, which T9 may run into),
[[feedback_a_boolean_has_four_states]],
[[feedback_negative_finding_needs_a_discriminating_measure]],
[[feedback_prove_against_the_real_server]].
