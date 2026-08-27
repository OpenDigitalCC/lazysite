---
title: "SM322 - The mirror count never reaches the path that needed it"
subtitle: "SM241 made domain_set mirror. SM315 made activation report the mirror. The two do not meet, so binding a theme to a domain still returns ok:1 with no indication whether anything was published - on the one path whose silent failure both filings were written about."
brand: plain
status: shipped
status-note: "SHIPPED in 0.10.11. domain_set captures the mirror result instead of discarding it, returns assets_mirrored, and warns on zero with the SAME wording the instance path uses - asserted, so an agent that learns the phrase on one surface need not learn a second. Filed by the site agent from the 0.10.10 validation, having hit the failure it describes while building on edge2. FILED 2026-08-16 from a partner-agent pass on edge/0.10.10, and from having hit the underlying failure while building a real site on a secondary domain of that instance. Small: capture a return value that is already computed and already shaped for this. The report text, the zero-warning and the misplaced-asset sentence all exist and are tested - only the per-domain caller drops them."
---

# SM322 - two fixes that do not meet

## What happens

`activate_theme` and `activate_layout` **with a `host`** return no
`assets_mirrored` field and no warning when nothing was published.

Measured on edge running 0.10.10, binding a theme to a registered domain:

```json
{"value":"kestrel","scope":"domain:edge2.explore.lazysite.io",
 "key":"theme","ok":1,"host":"edge2.explore.lazysite.io"}
```

The same operation without a `host` reports the count, because it takes a
different route.

## Why the two paths differ

The split is deliberate and documented, in `lazysite-mcp.pl`:

> SM238: with a host, this is a per-domain BINDING, not an instance activation -
> so it routes through `domain_set`

That routing is correct. What follows it is the gap.

[[SM241]] gave `domain_set` the mirror, in the 0.10.2 line, for exactly the
failure this filing is about. Its comment in `Domains.pm` still describes the
incident that prompted it:

> That is what happened to a secondary domain whose theme source was in the
> right place and whose public mirror was never written.

[[SM315]] then made activation *report* the mirror, in 0.10.10, on the reasoning
that a count of zero is the whole point - a theme that mirrors nothing is a site
about to render unstyled, and at the HTTP level that is indistinguishable from a
working one.

Both are right. They land in different functions:

```perl
# Themes.pm - the instance-wide path, SM315
if ( ref $mirror eq 'HASH' ) {
    $res->{assets_mirrored} = $mirror->{mirrored};
    if ( !$mirror->{mirrored} ) { push @{ $res->{warnings} ||= [] }, ... }
```

```perl
# Domains.pm - the per-domain path, SM241
_mirror_theme_assets( $l, $t );
...
return { ok => 1, host => $host, key => $key, value => $value };
```

`_mirror_theme_assets` returns `{ mirrored, dest, expected, reason, misplaced }`
in both places. The per-domain caller discards it and returns a fixed hash.

## Why this is the path that most needed it

**It is the one whose silent failure both filings describe.** SM241 was reported
from a secondary domain serving a 404 stylesheet. SM315 was reported from
authoring a layout for a site build. Both are per-domain operations on a
multi-domain instance, and neither now gets the report.

**It is the normal operation.** On an instance serving one site, activating
instance-wide is the same thing. On an instance serving several - which is what
[[SM151]] built and what the tool descriptions push callers towards - binding to
a host is the only correct action, and `activate_theme`'s own description says
so: *"WITHOUT `host` this is INSTANCE-WIDE ... on a multi-domain instance that
is almost never what you want."*

So the tool correctly steers a caller onto the path with no reporting.

**The failure is invisible everywhere else.** That is the whole argument of
SM315 and it applies unchanged here: the upload succeeds, the binding is
recorded, `ok:1` comes back, every page returns 200, and the site renders with
no stylesheet at all.

I hit this on edge2 while building a site in August. Activation returned `ok:1`,
every page returned 200, and the result was completely unstyled. It took a
screenshot to find, which is exactly the outcome SM315 exists to prevent.

## The fix

Capture what is already computed.

```perl
my $mirror = _mirror_theme_assets( $l, $t );
```

then carry `assets_mirrored` and the zero-warning onto the returned hash, the
way `action_theme_activate` already does. The message text, the misplaced-asset
sentence and the distinction between "no assets" and "a stylesheet in the wrong
directory" are all written and tested; only this caller drops them.

Two details worth keeping:

The mirror is best-effort here, and should stay that way
: `Domains.pm` wraps it in an `eval` and logs a warning on failure, because the
  binding is recorded either way. Reporting a count must not change that - a
  failed mirror should produce a warning on a successful binding, not a failed
  binding.

The count is taken by walking the destination
: SM315 chose that deliberately over counting what was attempted. The
  per-domain path gets the same guarantee for free by using the same return.

## Verification

- `activate_theme` and `activate_layout` with a `host` return
  `assets_mirrored`.
- Binding a theme whose assets are in the wrong directory returns `ok:1`, a
  count of zero, and the sentence naming where assets belong.
- Binding a correct theme is otherwise unchanged, and the binding still succeeds
  when the mirror fails.
- The instance-wide path is unchanged.
- A test drives the per-domain path specifically. `t/unit/manager/77` covers the
  instance-wide one; this needs its own, because the two functions are what
  diverged.

## Related

[[SM241]] (gave the per-domain path its mirror), [[SM315]] (gave activation its
report), [[SM238]] (the routing split the two sit either side of), [[SM151]]
(multi-domain, which is what makes the per-domain path the normal one), and
`inbox/0.10.10-validation-2026-08-16.md`, the pass this came from.
