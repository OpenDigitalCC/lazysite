---
id: SM917
title: "SM917: the store-reader lint cannot see the other way to swallow a failed open, and does not read half the files"
subtitle: "t/lint/121 refuses a store reader that turns an unopenable file into an empty answer, and it has caught that defect three times (SM760, SM766, SM768). Its matcher required `or` on the open line, so `if ( open ... ) { }` with no else - where the failure branch is the MISSING else - was invisible for three releases: 14 such read-opens, 12 needing work, and two of those were losing data rather than reporting nothing. A second gap, that the lint reads only files a store NAMES in a hand-kept list, turned out to be two readers rather than the twenty first claimed here, and is closed by asking about the PATH instead of the file. Both of this filing's original counts were mine and both were wrong - the first correction made it larger, the second smaller; the record of both is in the body."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-09-30 in three commits, and the plan was five. WHAT WAS REAL: G1, the idiom. t/lint/121's matcher required `or` on the open line, so `if ( open ... ) { }` with no else - where the failure branch is the MISSING else - was invisible for three releases. Fourteen such read-opens inside the files it walks; twelve needed work, and TWO WERE LOSING DATA rather than reporting nothing: the visitor-trail export read the day it was appending to and an unreadable day made the atomic write REPLACE that day with only the new rows, and _ensure_conf_key's read IS its idempotency check so an unreadable conf appended a second entry for a key that already had one - SM915's shape one file over. Both refuse now. Also the site conf read five ways, two secrets whose mint-on-empty fallback invalidates every token issued against the first, and three -f stat guards removed. WHAT I MEASURED WRONG, TWICE, IN THIS DOCUMENT. First: the 51/120 figures were taken over subtest 1's file set rather than subtest 2's, and correcting that made the finding bigger - two gaps, 96 read-opens. The ruling had already been given on the wrong number, so it was re-taken. Second, and it goes the other way: 'G2: 20 (store, file) pairs unread in any idiom' counted files that MENTION a store directory anywhere - comments, error strings, paths built for writing - not unreported store reads. The real number is TWO, both of them the audit paths step 1 had already repaired. So G2's exposure was two readers, not twenty. THE STRUCTURAL FIX for G2 is a new subtest: any read-open whose path names a store obeys the rule in EVERY file, not only in listed ones - which needed the three spellings of the engine directory normalised first, because it is written \"$LAZYSITE_DIR/auth/...\" and the first version looked for the literal 'lazysite/' and matched nothing. The modules list stays for helper-based reads, where no literal exists. AND THE PER-FILE LIST DOES NOT SCALE: listing lazysite-processor.pl for `auth` put 61 read-opens under the rule, of which ONE was an auth read and 23 were content - that approach was tried, measured and withdrawn the same day. STEPS 4 AND 5 ARE EMPTY and deliberately not performed: with two store reads in the tree and both fixed, `forms` and `logs` have nothing in them, and two empty commits to match a plan would be theatre."
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

## SECOND CORRECTION 2026-09-30: G2 was much smaller than I said, and this one shrinks it

The first correction made this filing bigger. This one makes it smaller, and both
were my errors in the same document, so both stay on the record.

I wrote "20 (store, file) pairs unread in any idiom", which reads as twenty
unchecked store READS. It is not what the probe counted. It counted files that
MENTION `lazysite/<store>` anywhere in their source and are absent from that
store's modules list - and a mention includes a comment, an error string, and a
path built in order to WRITE. Counted as pairs it was 20; as files it is 11.

The question that matters is narrower: how many unreported store READ-OPENS sit in
files the modules list does not name? Measured with
`tmp/what-g2-actually-was.pl`:

```datatable
columns: What was counted | Count
widths: 11cm | X
bold: 1
tone: medium
---
files that mention a store dir and are not listed | 11 (20 as store/file pairs)
**unreported store READ-OPENS in any unlisted file** | **2**
```

Both of the two are the ones step 1 had already repaired - lazysite-mcp.pl's
`auth/acls.json` and lazysite-processor.pl's `auth/.secret`. So G2's real exposure
was two readers, not twenty, and it is closed.

**G1 was the real finding.** Fourteen conditional read-opens, twelve needing work,
and two of those were losing data rather than reporting nothing: the visitor-trail
export turning an append into a truncation, and `_ensure_conf_key` appending a
second entry for a key it could not see. That half of this filing stands exactly
as written.

**And the sequencing collapses.** The ruling was five commits, one per store after
the idiom. With two store reads in total and both already fixed, steps 4 and 5 -
`forms` and `logs` - have nothing in them. Saying so is better than performing two
empty commits to match a plan.

## G2 as originally described - the modules list

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
