---
title: "SM309 - front-door mode is unverifiable from outside, and accepts 'false' as yes"
subtitle: "The largest behavioural change in 0.10.9 has less observability than the smaller one 0.10.7 added an observable for, and the single environment variable that switches it on treats any non-empty value except '0' as true"
brand: plain
status: shipped
status-note: "SHIPPED on claude/sm305-principal-picker-and-polish. lazysite check gained report_front_door_mode, which reads /etc/lazysite/pools/*.conf and matches on DOCROOT rather than the instance name - the instance name is conventionally the domain and nothing enforces that, so a check keyed on the name could report another site's setting. It reports ON, OFF, and a bad value as FAIL, and stays silent on a site with no pool conf (plain CGI, where the mode does not apply). lazysite-pool.pl now accepts 1/true/yes/on and 0/false/no/off case-insensitively and REFUSES anything else by name, validated beside the other configuration checks rather than at the point of use - the launcher binds and chowns its socket first, so a bad value was previously unreported until after those side effects and never reported at all on a host where the bind failed. VERIFIED by t/unit/tools/40, shown to fail before the fix (3 of 6 subtests). FILED 2026-08-15 from a partner-agent field test of 0.10.9 on edge (inbox/0.10.9-validation-2026-08-15.md section 6, archived). Ten anonymous samples before and after showed no measurable change - network dominates at that distance and cannot resolve a 71 ms server-side difference either way - and there is no way to establish whether the mode is even active. Two defects in one operator step, filed together because they are the same step."
---

# SM309 - one operator action, no confirmation, and a permissive switch

## Part 1: nothing reports whether front-door mode is active

SM294 moved the front door under the FastCGI pool in 0.10.9. Whether it is
running is decided by `LAZYSITE_FRONT_DOOR` in the pool configuration, which is
an operator step. Nothing anywhere reports whether that step was taken.

`X-Lazysite-Front` exists only in `installers/hestia/lazysite-proxy.tpl`, which
is the SM283 proxy template and is not installed on the host measured. So on any
instance without that template - which is the instance the field test ran
against, and the one the SM283 sweep is still pending on - the mode is
indistinguishable from its absence.

**This is the situation 0.10.7 added an observable for**, and the runbook records
why: three rebuilds and a template install produced byte-identical responses with
no way to tell them apart. SM294 is a larger behavioural change than that one and
has less observability than it.

The fix belongs where an operator already looks. `lazysite check` reports on the
pool; front-door mode is a property of the pool and should be a line in that
report, sourced from the running configuration rather than from what the
installer intended to write. A response header is the second-best answer, because
it requires the proxy template to be installed to be readable, which is the
condition that made this invisible in the first place.

## Part 2: `FRONT_DOOR=false` switches it on

`tools/lazysite-pool.pl:152`:

```perl
if ( length( $ENV{FRONT_DOOR} // '' ) && $ENV{FRONT_DOOR} ne '0' ) {
```

Any non-empty value other than `0` enables the mode, so `false`, `no` and `off`
all mean yes.

This is the class 0.10.9 fixed on the MCP surface, where an unrecognised value
for a declared boolean is now refused outright rather than coerced - the fixture
E finding, where `draft` with an unrecognised value read as *clear* and published
protected content while returning `ok:1`. Refusing rather than coercing removed
the whole class there. This is the one place an operator writes such a value by
hand, into a file, with no validation and no feedback, and it is the place the
same treatment is most warranted.

Accept the conventional set on both sides (`1`/`true`/`yes`/`on` and
`0`/`false`/`no`/`off`, case-insensitively), and **refuse anything else with a
message naming the value and the accepted spellings** rather than silently
picking a side. Silently defaulting to off would be a second version of the same
defect - a control that reports nothing while doing something other than what was
written.

## Why both in one filing

They are one operator action. Today an operator can write `FRONT_DOOR=false`,
get front-door mode, and have no way to discover it. Either defect alone is
awkward; together they make the setting unauditable. Fixing the observability
without fixing the parser leaves a check that faithfully reports a value the
operator did not intend; fixing the parser without the observability leaves the
operator still unable to confirm the outcome.

## Verification

- `lazysite check` reports front-door mode as on or off, read from the running
  pool configuration, and its answer is shown to differ between an instance with
  the setting and one without.
- `FRONT_DOOR=false`, `no` and `off` leave the mode off; `true`, `yes`, `on` and
  `1` turn it on.
- An unrecognised value is refused with a message naming it - shown to fail
  before the fix, where it currently enables the mode.
- The existing `0` and `1` spellings are unchanged, since they are what any
  existing deployment has written.

## Related

SM294 (the change this makes verifiable), SM283 (whose proxy template carries the
only current observable), SM278 (unrecognised argument values refused rather than
coerced), and the 0.10.7 runbook note on byte-identical responses.
