---
id: SM869
title: "SM869: one query hash serves the TT stash and the form sink, and they need opposite things - so the sink escapes by source rather than uniformly"
subtitle: "`parse_query_string` escapes each value as it stores it, because the same hash becomes `query.*`/`params.*` in the template stash and an author interpolating it without a filter must be safe. The SM856 prefill sink reads that same hash and places values into an attribute, where they arrive pre-escaped. SM868 fixed the resulting double-escape by escaping only the raw source. That is correct and it is a dependency at a distance: the sink's safety now rests on an invariant held 2,300 lines away."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-12
raised-by: engine (from the SM868 fix, at the release manager's direction)
area: processor
---

# What exists now, after SM868

`parse_query_string` (`lazysite-processor.pl:1981`) HTML-escapes `& < > " '` as
it stores each value, with the reason in place:

```perl
# HTML-escape value before storing so TT renders it safely.
$val =~ s/&/&amp;/g;   # ... etc
```

That is right for its first consumer. The hash is handed to `render_content` as
both `query => $query` and `params => $query`, so it *is* the stash, and SM709
settled the principle: escape at the single point a family enters the stash, so
every layout and page emits it safely even when it interpolates without a
`| html` filter - which is what the shipped example does, and what an author
copying it will do.

SM856 then added a second consumer with the opposite need. `_render_form` reads
the same values and places them into an `<input value="...">` attribute and into
`<textarea>` content - sinks that escape their own input. Escaping happened
twice, and `Smith & Sons` reached the browser as `Smith &amp; Sons`.

SM868's fix escapes **by source**:

```perl
my $v = $from_query ? $value : _esc_attr($value);
```

A `value:` literal comes from the form definition raw and is escaped; a query
value is passed through. Both sinks (attribute and textarea) follow the same
rule, and `parse_query_string`'s character set covers both contexts.

# Why that is a workaround and not the answer

**The sink can no longer verify its own safety.** It emits a visitor-controlled
value into an attribute without escaping it, and the only thing making that safe
is a substitution in a different function, in a different part of the file,
written for a different consumer. If `parse_query_string` ever stopped escaping -
moved the escape into the stash build, say, which is where SM709's own principle
would put it - the sink would silently start emitting raw visitor input into an
attribute. Nothing local to the sink could detect it, and no test of the sink
alone would fail.

**It is a two-state input with no marker.** `$from_query` is computed three lines
above its use and is correct today. A third source - a value from a data row, a
session, a handler default - would arrive in whichever state its author happened
to produce, and the next person to add one has to know which branch to join.
That is the shape of the defect SM868 just fixed, preserved rather than removed.

**Mitigation in place**: `t/unit/processor/80` asserts that
`parse_query_string` escapes, deliberately sited beside the sink's own tests
rather than with the parser's, so the dependency is visible from the place that
depends on it. The comment at the sink names the reason. That converts a hidden
assumption into a checked one; it does not remove it.

# What the fix looks like

**One raw source, escaped once at each sink.** The prefill path should read
values that have never been escaped, and every sink should escape for its own
context - attribute, text, URL - which is the rule everywhere else in this file
(`_esc_attr` vs `_esc_html` exist precisely because the context decides).

The obstacle is that a single hash currently carries both duties, so the work is
to separate them:

1. `parse_query_string` returns **raw** values, and also the escaped map the
   stash needs - or returns raw only, and the escape moves to where `query` and
   `params` are put into the stash (`render_content`, near the `auth_*` escape
   SM709 added for exactly this reason). The second is tidier and is what SM709's
   principle actually asks for.
2. `%RENDER_QUERY` - which the prefill sink is the **only** reader of - carries
   the raw values.
3. The sink escapes unconditionally, and `$from_query` disappears.

**The cheap sequencing risk is that step 1 moves an escape that currently
protects every page and layout.** Getting it wrong is an XSS regression on the
render path rather than a cosmetic one, so it wants its own release and its own
adversarial ref - not a slot in a release being cut to a deadline. That is why it
was not done in 0.13.15: the release manager's direction was to file it with the
workaround and the risk recorded, and take it next.

**What would catch a mistake**: a test that renders a page interpolating
`[% query.c %]` with a hostile value and asserts the output is escaped, which is
the assertion protecting the stash side today only implicitly. Write that FIRST,
against the current code, so it passes before the refactor and is the thing that
fails if the escape lands in the wrong place.

# Why it matters beyond tidiness

The double-escape shipped and reached a live instance, in a feature built for the
expo, and was found by a person reading a page rather than by 13,975 tests. The
reason is recorded in SM868: over-escaping is SAFE, so a security-shaped
assertion cannot see it, and the fixture used `ODX-0001` - alphanumerics are a
fixed point of HTML escaping, so the test value could not change under the
transform it was meant to detect. A sink whose escaping depends on where its
input came from will keep producing that class of defect, because the failure is
invisible to the tests one naturally writes for it.

# Related

[[SM868]] (the double-escape, and the by-source fix this replaces), SM856 (the
feature that added the second consumer), SM709 (escape once, at the point a
family enters the stash - the principle this restores),
[[feedback_fixture_agrees_with_reader]] (the old hostile-value fixture put a raw
value where production puts an escaped one, which is what hid it),
[[feedback_verify_the_gate_tests_what_you_think]].
