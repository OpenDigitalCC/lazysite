---
id: SM917
title: "SM917: the store-reader lint cannot see the other way to swallow a failed open"
subtitle: "t/lint/121 refuses a store reader that turns an unopenable file into an empty answer, and it has caught that defect three times (SM760, SM766, SM768). Its matcher requires `or` on the open line, so it sees `open ... or return {}` and `open ... or do {...}` and is blind to the other idiom that does the same thing: `if ( open my $fh, '<', $path ) { ...read... }` with no else. Measured 2026-09-30 across the exact files the lint scans: 120 read-opens it can see, 51 it cannot."
brand: plain
standard-margins: true
status: candidate
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

# Why it was invisible

`_read_opens` (t/lint/121 line 88-89) selects its candidates like this:

    next unless $l =~ /\bopen\s*\(?\s*my\s+\$\w+\s*,\s*'<[^']*'\s*,/;
    next unless $l =~ /\bor\b/;

The second line is the whole problem. It is there because the lint was written
against the shape SM760 found - `open ... or return {}` - and extended in SM768
to read the `or do { ... }` block form. Both have an `or`. A read-open used as
the CONDITION of an `if` has none, and does the same damage with no keyword the
matcher looks for.

# The measurement

Over the exact file set subtest 2 walks - everything under `lib/` plus
lazysite-manager-api.pl, lazysite-mcp.pl, lazysite-auth.pl,
lazysite-processor.pl and lazysite-dav.pl:

```datatable
columns: Read-open shape | Count | The lint
widths: 9cm | 3cm | X
bold: 1
tone: medium
---
`open ... or return` / `or do {` | 120 | sees these
`if ( open ... )` / `unless ( open ... )` | 51 | **cannot see these**
```

So roughly 30% of the read-opens in the protected files are outside the gate's
reach. `tmp/probe-lint121-blindspot.pl` is the probe; it reuses the lint's own
candidate regex so the two counts are drawn the same way.

# Not all 51 are defects, and that is the work

The count is an upper bound on exposure, not a defect list. Several of the 51
read files that are not stores at all - a `$tmp` file the process just wrote in
lazysite-dav.pl, a `.fingerprint` under the docroot - where an unreadable file
genuinely has no fourth state worth reporting. The catalogue in
`Lazysite::Stores` is what decides, and that decision has to be made per site.

Two are worth naming now, because they are audit and advisory paths where an
empty answer reads as a clean bill:

  - `lazysite-mcp.pl:2623` reads `auth/acls.json` to report ACL keys that match
    nothing at the docroot. Unreadable means no unmatched keys, which reads as
    "your access rules are fine". It is not a privilege bypass - nothing about
    enforcement changes - but it is a false clean bill in an audit, which is the
    SM907 shape.
  - `lazysite-processor.pl:9667` reads `auth/.secret`.

# What this filing wants ruled

Three choices, and they are not equivalent:

  1. WIDEN THE MATCHER so the `if ( open ... )` form is a candidate too, then
     work the resulting list down. This is the honest option and it will fail
     loudly on day one with a list of 51 to triage - which is the point, but it
     is a release's worth of triage rather than an afternoon.
  2. WIDEN THE MATCHER WITH A CEILING, the idiom t/lint/118 and t/lint/157
     already use here: hold today's count as a named set that can only shrink,
     so nothing new joins it and the existing ones are worked off over time.
  3. Rule that the conditional form is acceptable where the reader has a
     documented reason, and require the `# not a store` marker the lint already
     understands. Cheapest, and it puts the decision at each site.

Option 2 is what this filing recommends, on the precedent that it is how this
repo has twice before turned a large existing population into a shrinking one
without blocking a release. SM918 fixed the one reader it touched rather than
waiting for this ruling, so the notice store is not in the population.

# What is NOT claimed

That any of the other 50 is live-wrong. Each needs the catalogue consulted and
the path classified, and doing that from a regex count would be the
reference-name-as-evidence mistake. The only reader measured wrong, reproduced
and repaired is the notice store's, under SM918.
