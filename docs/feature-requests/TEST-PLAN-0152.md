---
title: "Test plan - 0.15.2 on edge"
subtitle: "What a green gate does not say about this release. Eleven release-specific checks that only a deployed host can run, in the order that finds the most first, and the standing tiers."
brand: plain
standard-margins: true
---

# What this plan is for

0.15.2 was gated at 1,016 files and 15,673 tests; the instrumented suite passed,
and the manifest, SBOM and man pages were checked before the build. The suite
cannot see three things this release depends on.

**What an operator sees in a browser.** The bell's read state, the Handlers
page's notice line and control, and the new single-submission page are browser
code, and the suite checks their source, not their behaviour.

**What a real install does to a real host.** SM933's fixes are about the group
and mode the installer leaves on a Hestia docroot; the suite builds fixtures in
the test user's own group, which is exactly the case where the fault cannot
happen.

**What arrives from a visitor.** SM904 (non-ASCII submissions) and SM934 (server
side field rules) are about what a browser actually sends; the tests send what
the tests decide to send.

# The order

1. Record the version the check panel REPORTS, not the tarball's.
2. **R3 first** - it repairs a defect live sites have today: submissions with an
   accented letter were stored and never shown.
3. R1 and R2, the bell, together.
4. R4, the notice control, on a form whose site has XMPP configured.
5. R5 and R6, which need a fresh test domain - provision only on edge.
6. R7 to R11 in any order.

# Release-specific checks

## R1 - the bell's read state is said, not inferred (SM938 D3)

With at least three notices in the bell: open the panel and close it.

*You should see:* the badge count unchanged - opening no longer marks anything
read. Unread notices are bold and say "- unread". Follow one notice's link:
only that notice becomes read. Press **Mark all read**: the badge goes to zero.
**Dismiss** one notice: it leaves the panel and does not come back on reload.

It is a FAIL if opening clears the badge, if following one link marks others
read, or if a dismissed notice reappears. Then sign in as a second operator: their
bell must be untouched by the first operator's reading and dismissing.

## R2 - a submission notice opens the submission (SM938 D5)

Submit a form whose handler keeps submissions in a file. Open the bell and follow
the new notice.

*You should see:* `/manager/submission?file=...&id=...` showing that one
submission - the visitor's fields, then when and from where it arrived - with a
button to all submissions in the store. Delete that submission from the table and
follow the notice again: the page says it may have been deleted since the notice
was sent. A form that only emails (no file handler) still links to the Handlers
page.

It is a FAIL if the page shows a different submission, renders any submitted text
as markup (submit `<b>x</b>` in a field and check it appears literally), or opens
for an account without the read-submissions grant.

## R3 - a submission with an accented letter is shown (SM904)

Submit a form with `José` in one field and an emoji in another.

*You should see:* the row in the submissions table, with both values as typed.
Before this build it was stored and counted "malformed" - invisible. Delete it by
its row: it goes. If quarantine catches a test row with non-ASCII text, confirm it:
the text must be unchanged (before, it came back double-encoded, `JosÃ©`).

It is a FAIL if the row is missing, shows mojibake, or cannot be deleted.

## R4 - the Handlers page says where a notice goes, and sets it (SM938 D2/D4)

Manager -> Handlers -> a form row.

*You should see:* "announces to bell, xmpp" (or what this site routes) in the row.
Expand it: a Notifications section naming, for each place it does NOT reach, the
one setting that stops it. Set **This form's notice** to Off and Save, submit: no
notice. Set Full, submit: the XMPP message carries the submitted fields. Set On:
one line again. Changing only the handler ticks and saving must not rewrite the
form's `notify:` line.

It is a FAIL if the stated reason is not the actual one (switch the XMPP extension
off and the reason should name the extension, not the account), or if Off still
notifies.

## R5 - a fresh install says whether the site works (SM933)

Provision a fresh test domain on edge.

*You should see:* the install ending with the health check's verdict; a site that
would 500 exits non-zero naming its fault instead of reporting success. Every path
it created is in the docroot's group, including the private store beside the
docroot. `lazysite/.install-state.json` carries a `dirs_left` map.

It is a FAIL if the install reports success on a site that does not serve, or if
anything it created is in the site user's own group on Hestia.

## R6 - `--no-starter` (SM939)

Provision a second test domain with `--no-starter`.

*You should see:* no `/docs/` and no demo pages, while `/forgot`, `/logout` and the
manager work; the summary says the starter content was skipped. Run an upgrade
without the flag: the docs must still not appear.

## R7 - field rules hold without the browser (SM934)

Post to a form with a required field empty, bypassing the browser (curl, or the
browser's devtools to drop `required`).

*You should see:* the submission refused, naming the field and the rule. Nothing
stored.

## R8 - the rate limit is a rolling hour (SM935)

On a form with a low limit, submit up to it just before the top of an hour and
again just after. *You should see:* the second batch refused - before, the hour
boundary reset the count.

## R9 - a deleted page's rule does not reach the next page at that path (SM936)

Give a page a read rule, delete the page, create a new page at the same path.
*You should see:* the new page without the old rule.

## R10 - the visitor report's new shape (SM941)

Read Stats and `analyse_visitors`. *You should see:* `unattributed` (an upper
bound, and the page says so) where `human` was, `no_agent` as its own class,
`totals.human_visits` gone, counting basis 4. Anything that reads the report -
dashboards, agents - needs the new names.

## R11 - feeds newest first, and bounded (SM942)

Fetch a site's feed. *You should see:* items newest first and no more than the
configured cap (50 by default), with `lastBuildDate`.

# Standing tiers

Tier A before any promotion to beta or stable, as for every edge build.
