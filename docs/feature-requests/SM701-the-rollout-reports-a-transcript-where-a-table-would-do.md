---
id: SM701
title: The fleet rollout reports a transcript where a table would do
raised: 2026-08-30
raised-by: release manager
area: installers
status: shipped
status-note: "SHIPPED (unreleased; lands in 0.11.9). The rollout printed each candidate up to FOUR times - a discovery list, again with its channel, again in an out-of-scope block, again in an excluded block - then streamed the whole install transcript per site, then repair and probe per site. It now prints ONE table of every candidate carrying version, channel and scope; then only warnings and failures, each attributed to its site; then a summary table of what happened. `--verbose` restores the transcript, and a site that FAILS still prints everything captured, because a summary saying 'failed' without saying why moves the operator's work into a second run. FOUND WHILE DOING IT, and the more serious half: the scope loop leaves errexit ON, so the deploy loop's `cmd; rc=$?` exited the script before the assignment ran - the first site that failed to install ABORTED THE ROLLOUT, FAILED could never fill, and the SM344 'ROLLOUT FAILED, a retry is meaningful' verdict could never print. Latent because installs succeed. The call is now guarded the way the scope loop already guards its own."
---

# The request

> install/deploy is now very noisy, reporting an ever longer collection of
> information. either now or for next release, trim down the information, to
> focus on the one table listing the discovered candidates, their version,
> channel set, and if in scope of the update, then only list warns and fails,
> with updated summary table at the end.

# What it printed

A candidate appeared in as many as four places, none of them complete:

1. `lazysite sites on this host: N` and a line per domain with its version.
2. A line per domain with its channel and whether it was in scope.
3. An `OUT OF SCOPE` block repeating the domains, with five lines of standing
   explanation.
4. An `EXCLUDED` block repeating the marker-only domains.

Then, per site, a `################ domain ################` banner and the
entire output of the per-site deploy; then the whole output of `repair` for
every site; then the whole output of `probe` for every site. Two further blocks
of standing advice printed on every run that did not pass `--reapply-acls` or
`--proxy`.

Nothing in that is wrong. It accreted one useful thing at a time, and each
addition was defensible on the day. The result is that the lines an operator
must act on are typographically identical to several thousand they must not.

# What it prints now

**One table**, after the channel check, so each candidate is one row carrying
everything known about it:

    ==> lazysite fleet update to 0.11.9

      DOMAIN            USER    VERSION  CHANNEL  SCOPE
      a.example.com     alice   0.11.8   edge     in scope
      b.example.com     bob     0.11.1   stable   out of scope
      c.example.com     carol   0.11.1   -        excluded (not on lazysite-app)

      3 candidate(s): 1 in scope, 1 out of scope, 1 excluded

**Then only warnings and failures**, each tagged with the site it came from - an
unattributed line is not actionable on a fleet. **Then a summary table** with
the same domains and what actually happened to each.

`--list` still changes nothing and now reaches the table, because the channel
check reads `lazysite.conf` and the manifest and writes nothing.

## What is never suppressed

A site whose deploy exits non-zero prints **everything captured**, regardless of
`--verbose`. A summary that says "failed" without saying why does not save the
operator a run; it costs them one.

# The defect found while doing it

`set -u` is set at the top and `set -e` is not. But the scope loop (SM345) ends
each iteration with `set -e`, so from its first pass onwards **errexit is on for
the rest of the script**. The deploy loop then read:

    bash "$DEPLOY" "$u" "$d" "$STAGE"; rc=$?

Under errexit a failing command exits **before** `rc=$?` runs. So the first site
that failed to install aborted the whole rollout: `FAILED` never filled, the
per-site loop never continued to the remaining sites, and SM344's verdict -
`ROLLOUT FAILED: N site(s) failed to install` with its "a retry is meaningful"
advice - could never print. The failure path was the one nobody exercised,
because installs succeed.

It is now guarded with the explicit `set +e` / `set -e` pair the scope loop
already uses around its own call.

**The same bug, once, in the new code.** The first draft of the quiet wrapper
ended with a bare `set -e`, which turned errexit ON even when the caller had
turned it off - so returning a non-zero status killed the script at the call
site. It saves and restores the caller's state instead. It was invisible in the
source and obvious the moment the function was executed, which is why the tests
run the helpers rather than reading them.

# How it is proved

`t/tools/43-the-rollout-report-is-a-table-not-a-transcript.t` extracts the
reporting helpers and RUNS them: a candidate row carries all four facts, a clean
site prints nothing, a warning is surfaced and attributed, a failure keeps its
whole output and its status, and the script survives that failure. Five
sabotages were checked and each fails the suite.

**What is NOT proved here.** The script needs root and a Hestia host, so the
end-to-end rollout is unexercised in this repository. What is tested is the
reporting layer and the wiring; the first real rollout is what confirms the
whole path. The change is presentation plus one guarded call - no phase, no
ordering, no exit status and no site selection is altered.

# Related

[[SM344]] (the two non-zero verdicts this restores the ability to reach),
[[SM345]] (the scope loop whose `set -e` is the errexit source),
[[SM324]] (functions defined above their callers, why the helpers sit where
they do).
