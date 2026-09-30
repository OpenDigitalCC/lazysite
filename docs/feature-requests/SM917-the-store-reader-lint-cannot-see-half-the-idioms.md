---
id: SM917
title: "SM917: the store-reader lint cannot see the other way to swallow a failed open, and does not read half the files"
subtitle: "t/lint/121 refuses a store reader that turns an unopenable file into an empty answer, and it has caught that defect three times (SM760, SM766, SM768). TWO gaps, measured 2026-09-30. Its matcher requires `or` on the open line, so `if ( open ... )` with no else is invisible - 14 such read-opens inside the files it walks. And it walks only the files a store NAMES in its hand-kept `modules` list, so 20 (store, file) pairs are unread in any idiom - including seven files that read `auth`. Closing both brings 96 read-opens into scope needing a decision."
brand: plain
standard-margins: true
status: candidate
status-note: "RULED 2026-09-30: WIDEN AND FIX ALL, no baseline and no carried debt - the suite goes red until every site is triaged. TAKEN ON A WRONG NUMBER, and re-scoped the same day: the ruling was given against my figure of 51, which I had measured over subtest 1's file set instead of subtest 2's. The corrected measurement is in this document and it is LARGER - two gaps rather than one, and 96 read-opens rather than 51, of which lazysite-processor.pl is 38 and lazysite-dav.pl 9. The re-scoped decision is back with the release manager because 96 sites across the serving path is a different question from 51. ALREADY RULED SEPARATELY AND NOT WAITING ON THAT: the two audit paths where an unreadable file reads as a clean bill - MCP's audit_site ACL-key report and the processor's auth/.secret - are to be fixed first and independently."
raised: 2026-09-30
raised-by: engine agent, while moving the notice reader into a module for SM918
area: testing
---

# How this was found

Not by reading the lint. By moving one reader and asking whether the lint would
have caught what the reader was doing.

SM918 needed the notice-store reader in a module so MCP and the control API could
share it. The reader was, verbatim:

    if ( open my $fh, '<', _notices_path() ) {
        ...push notices...
    }

No else. A store that exists and cannot be opened produced an empty list and
`unread => 0` - a bell that is quiet because nobody looked. That is exactly the
defect t/lint/121 exists to refuse, and t/lint/121 was passing.

# CORRECTION 2026-09-30: my first measurement was against the wrong population

The figures first recorded here - 51 invisible against 120 visible - were taken
over `lib/` plus the five CGIs. **That is subtest 1's file set, not subtest 2's.**
Subtest 1 checks the CATALOGUE is complete; subtest 2 is the reader contract, and
it walks only the files named in each store's `modules` list:

    for my $s ( grep { $_->{store} } stores() ) {
        for my $rel ( @{ $s->{modules} } ) {

So the number I put in front of a ruling was about the wrong set of files. It is
corrected below, and the correction makes the finding LARGER rather than smaller,
which is the only reason this document is worth re-reading rather than quietly
editing. Recording it because a filing that silently changes its own evidence is
worse than one that was wrong once: see the house rule about a negative finding
needing a discriminating measure, and this is the same rule turned on myself.

# There are TWO gaps, not one

## G1 - the idiom

`_read_opens` (t/lint/121 line 88-89) selects its candidates like this:

    next unless $l =~ /\bopen\s*\(?\s*my\s+\$\w+\s*,\s*'<[^']*'\s*,/;
    next unless $l =~ /\bor\b/;

The second line is the whole problem. It is there because the lint was written
against the shape SM760 found - `open ... or return {}` - and extended in SM768
to read the `or do { ... }` block form. Both have an `or`. A read-open used as
the CONDITION of an `if` has none, and does the same damage with no keyword the
matcher looks for.

Inside the 16 files subtest 2 currently walks: **42 read-opens it can see, 14 it
cannot.**

## G2 - the modules list, and this is the bigger one

Subtest 2 reads a file only if a store NAMES it in `modules`, and that list is
hand-kept in `Lazysite::Stores`. A file that reads a store and is not named there
is not checked in ANY idiom.

SM768's own comment says *"A lint that names the stores it protects protects the
stores somebody remembered."* The same sentence applies one level down, and
nobody had turned it on the modules list:

```datatable
columns: Store | Files that read it and are NOT on its list
widths: 4cm | X
bold: 1
tone: medium
---
`auth` | lazysite-manager-api.pl, lazysite-processor.pl, Capabilities.pm, Daemon/Service/Scheduler.pm, DomainRewrites.pm, Git.pm, Manager/Common.pm
`forms` | lazysite-dav.pl, lazysite-manager-api.pl, lazysite-mcp.pl, lazysite-processor.pl, Capabilities.pm, Daemon/Jobs.pm, Git.pm, Manager/Common.pm, Manager/Plugins.pm, tools/lazysite-users.pl
`logs` | lazysite-processor.pl, Git.pm, tools/lazysite-users.pl
```

**20 (store, file) pairs unchecked.** `auth` is the one to look at twice: seven
files read it and are not on its list, and it is the store where a silent empty
answer is worst.

This is also why the two audit paths named below are invisible. It is not the
idiom - it is that neither file is on any store's list.

# What "fix it all" actually costs

Closing G2 pulls 8 more files into scope, and each brings its own read-opens.
Counting every read-open that has neither `cannot_read` nor a `# not a store`
marker, across all 24 files that would then be in scope:

```datatable
columns: Shape | Count | Why it is unchecked today
widths: 7cm | 2.5cm | X
bold: 1
tone: medium
---
`if ( open ... )` | 33 | the idiom (G1), wherever the file is
`open ... or ...` | 63 | the file is on no store's list (G2)
**total to triage** | **96** | --
```

`lazysite-processor.pl` alone accounts for 38 of them, and `lazysite-dav.pl` 9 -
the two files where a wrong classification is most expensive, because both sit on
the serving path.

Probes, all reusing the lint's own candidate regex so the counts are drawn the
same way it draws them: `tmp/remeasure-lint121-scope.pl`,
`tmp/probe-store-modules-completeness.pl`, `tmp/measure-true-sm917-scope.pl`.

# Not all 96 are defects, and that is the work

The count is an upper bound on exposure, not a defect list. Many read files that
are not stores at all - a `$tmp` the process just wrote in lazysite-dav.pl, a
`.fingerprint` under the docroot - where an unreadable file has no fourth state
worth reporting and the honest outcome is a `# not a store` marker. The catalogue
decides, and it has to decide per site.

Two are worth naming now, because they are audit and advisory paths where an
empty answer reads as a clean bill:

  - `lazysite-mcp.pl` reads `auth/acls.json` in `audit_site` to report ACL keys
    that match nothing at the docroot. Unreadable means no unmatched keys, which
    reads as "your access rules are fine". It is not a privilege bypass - nothing
    about enforcement changes - but it is a false clean bill in an audit, which is
    the SM907 shape.
  - `lazysite-processor.pl` reads `auth/.secret`.

# What was ruled, and why it is back

**Ruled 2026-09-30: widen and fix all of it, with no baseline.** No ceiling, no
shrinking set - the gate goes red and stays red until every site is triaged, so
there is no carried debt and no list to forget.

That ruling was taken on 51. The number was wrong, and 96 across
lazysite-processor.pl and lazysite-dav.pl is a different proposition from 51
across `lib/` - not because the principle changes, but because those two files
are the serving path, and a `# not a store` marker written onto a real store there
blinds the gate on purpose at the worst possible place. So the re-scoped decision
goes back rather than being assumed, and the options are now:

  1. ALL 96, both gaps, one piece of work. What was ruled, at the real size.
  2. BOTH GAPS BUT G2 STORE BY STORE - close `auth` first (7 files, the worst
     store to be blind in), then `forms`, then `logs`. Each is a commit that
     ends green; the gate is never red for longer than one store's triage.
  3. G1 NOW, G2 AS ITS OWN FILING. The idiom is 14 sites and an afternoon; the
     modules list is a different defect with a different fix, and arguably wants
     its own number rather than riding on this one.

# What is NOT claimed

That any of the 96 beyond the two named audit paths is live-wrong. Each needs the
catalogue consulted and the path classified, and asserting otherwise from a regex
count would be the reference-name-as-evidence mistake. The only readers measured
wrong, reproduced and repaired so far are the notice store's, under SM918.

Nor is it claimed that closing G2 is only bookkeeping. Adding a file to a store's
`modules` list is the act that submits its read-opens to the contract, and 63 of
the 96 are read-opens in the `or` form that the matcher has always understood and
has simply never been pointed at.
