---
id: SM868
title: "SM868: a prefilled form value was escaped twice, so every name with an ampersand displayed as entity text"
subtitle: "`parse_query_string` escapes `& < > \" '` as it stores a parameter, because the same hash IS the `query.*`/`params.*` stash. SM856's prefill sink escaped it again. `Smith & Sons` reached the browser as `Smith &amp;amp; Sons`. Nothing was exposed - over-escaping is safe - which is exactly why my own tests could not see it."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-09-12 for 0.13.15. The sink escapes the RAW source only: a `value:` literal from the form definition is escaped, a query value is passed through, and both the attribute and textarea sinks follow the same rule. t/unit/processor/80 drives the real query path through run_processor with a value containing `&` and a hostile payload, asserts once-not-twice in both sinks, and pins the invariant the sink now depends on by asserting that parse_query_string escapes. Verified by sabotage. The robust version - one raw source, escaped once at each sink - is [[SM869]], deliberately deferred."
raised: 2026-09-12
raised-by: site agent (1314E-04)
area: forms
---

# What was found, the day the feature shipped

```text
visitor arrives at   /1314e-prefill?code=Smith %26 Sons
in the served HTML   value="Smith &amp;amp; Sons"
browser displays     Smith &amp; Sons
should display       Smith & Sons
```

The site agent's words: *"The feature works and the trust model is right. The
escaping is not."* Every prefilled value containing `&`, `<`, `>`, `"` or `'`
displayed as entity text. A registration code is usually alphanumeric and passes
a casual test; a name, an organisation or an address does not, and
`Smith & Sons` is not an exotic input for the case this was built for.

# Why

`parse_query_string` (`lazysite-processor.pl:1998`) escapes as it stores:

```perl
# HTML-escape value before storing so TT renders it safely.
```

It has to. That hash is handed to `render_content` as both `query => $query` and
`params => $query`, so it **is** the stash, and SM709 settled that a family is
escaped at the single point it enters - so a page interpolating it without a
`| html` filter is safe, which is what the shipped example does.

SM856 then added a second consumer with the opposite need: an attribute and a
textarea, both of which escape their own input. Two layers, one value.

# Why the tests I wrote could not catch it

This is the part worth keeping.

**Over-escaping is safe.** My assertions were that the value arrived in the field
and that a hostile payload did not execute. Both hold when the value is escaped
twice. A security-shaped test cannot distinguish correct from over-corrected.

**And the fixture could not fail.** Every value I used was of the form
`ODX-4417`. Alphanumerics are a **fixed point** of HTML escaping: escape them
once, twice or ten times and the output is identical. I chose a test value that
could not change under the transform I was trying to observe.

**The old hostile-value fixture was worse than useless - it hid the bug.** It did
`local %RENDER_QUERY = ( c => 'a" onfocus="alert(1)' )`, a **raw** payload in a
hash that production only ever fills from `parse_query_string`. So the sink was
escaping a value that only that test supplied unescaped, and the assertion passed
*because* of the double escape. A fixture that disagrees with the reader will
eventually certify the defect.

The site agent found it by looking at what a person reads, with a value that
changes under escaping. That is the whole difference.

# The fix

Escape the raw source only:

```perl
my $v = $from_query ? $value : _esc_attr($value);
```

`parse_query_string`'s character set covers both contexts, so a query value needs
nothing further in either the attribute or the textarea.

**This is a workaround and [[SM869]] is the answer.** The sink can no longer
verify its own safety: it emits a visitor-controlled value into an attribute
unescaped, and what makes that safe is a substitution in another function written
for another consumer. SM869 records the real fix - one raw source, escaped once
at each sink - and why it was not done in a release being cut to a deadline: step
one moves an escape that currently protects every page and layout, so getting it
wrong is an XSS regression rather than a cosmetic one.

Mitigation now in place: `t/unit/processor/80` asserts that
`parse_query_string` escapes, sited beside the sink's own tests rather than the
parser's, so the dependency is visible from the place that depends on it.

# Held by

`t/unit/processor/80-a-form-field-carries-a-value.t`, extended:

- the real query path through `run_processor` with `code=Smith%20%26%20Sons`,
  asserting `value="Smith &amp; Sons"` and no `&amp;amp;`;
- the hostile payload, also through the real path, asserting escaped exactly once;
- a `value:` literal containing `&`, which **is** raw and must still be escaped -
  the discriminating half, so a fix that simply removed escaping would fail;
- the textarea sink;
- the invariant, asserted directly.

Verified by putting the double escape back: five assertions across two subtests
fail, including the end-to-end one.

# Related

[[SM869]] (the refactor this defers to), SM856 (the feature), SM709 (escape once
at the point of entry - the principle both halves are trying to honour), SM844
(the same shape: a value escaped by the layer that produces it and again by the
layer that places it), [[feedback_fixture_agrees_with_reader]],
[[feedback_verify_the_gate_tests_what_you_think]].
