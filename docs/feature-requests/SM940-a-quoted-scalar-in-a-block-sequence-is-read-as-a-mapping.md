---
id: SM940
title: "SM940: a quoted scalar in a block sequence is read as a mapping"
subtitle: "`- 'https://github.com/X'` under `sections:` parses to `{ \"'https\" => \"//github.com/X'\" }`. The sequence branch of `_yaml_block` strips the `- ` and recurses straight into the mapping test, which splits on the first colon before anything consults the quotes. The flow form is correct, because that path tracks quote state. Nothing warns: the layout receives maps where it expected strings and the page merely renders wrong."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-02
raised-by: the sites agent (stuartjmackintosh.com), reproduced here against 0.15.1
area: renderer
status-note: "SHIPPED (448bc121). `_yaml_quoted_scalar_line` answers whether the OPENING quote closes at end of line, and it is consulted between the sequence branch and the mapping test, and again in the mapping loop so a quoted scalar at mapping indent is never accumulated as a bogus key. SABOTAGE-VERIFIED BOTH WAYS: with the fix removed the reporter's case and the block/flow agreement both fail; and the NAIVE discriminator ("starts and ends with a quote") was compared directly against the shipped one - it calls `'a': 'b'` a scalar where the shipped one calls it a mapping, which is the assertion that stops the obvious fix shipping. ORIGINALLY REPORTED against 0.14.4 and REPRODUCED HERE against the current tree, which is the part worth carrying: this is not a version gap. The reporter's own grade A stands - their probe diffs the engine's own subs against YAML::XS on a live page's front matter. The fix is an ordering change in one sub with one definition and no pinned copy, but the obvious spelling of it is wrong and this filing records why: a line that merely STARTS and ENDS with a quote includes `'a': 'b'`, a legitimate quoted-key mapping, so the test has to be that the opening quote CLOSES at the end of the line. Sized S. Not yet built."
---

# What was reported, and what I measured

The sites agent filed this against engine 0.14.4. Reports against a released
version are checked against the current tree before they are scheduled, because
the answer is sometimes "already fixed". This one is not.

Reproduced on **0.15.1**, the tree as it stands, with the reporter's own values and
the engine's own subs lifted out of `lazysite-processor.pl`:

| Front matter under `sections:` | Parses to |
| --- | --- |
| `- 'https://github.com/StuartJMackintosh'` (block) | `{ "'https" => "//github.com/StuartJMackintosh'" }` |
| `sameAs: [ 'https://github.com/...' ]` (flow) | `'https://github.com/...'` - **correct** |
| `- alpha` (block, unquoted) | `'alpha'` - **correct** |

So a list of two strings becomes a list of two single-key hashes, keyed on the
fragment before the first colon. The author's quotes are what make it happen.

# Why

`_yaml_block`'s sequence branch (`lazysite-processor.pl:4082`) strips the `- ` and
pushes the remainder as a token to recurse on:

    ( my $rest = $toks->[$$i][1] ) =~ s/^-\s*//;
    push @sub, [ $ind + 2, $rest ] if length $rest;

That recursion reaches the mapping test at `:4102`, which exempts the flow forms and
nothing else:

    if ( $first !~ /^[\[{]/ && $first =~ /^(.+?)\s*:\s*(.*)$/ ) {    # mapping

`'https://github.com/X'` satisfies it, with key `'https` - quote included - and value
`//github.com/X'`. The quotes are never consulted, and a quote is precisely what an
author adds to protect a value containing a colon.

The flow form is correct for the reason the reporter gives: `_yaml_split_flow`
(`:4041`) tracks quote state character by character, so it never splits inside a
quoted run. The two paths disagree, and the one an author is more likely to write is
the one that loses.

# It is silent, and that is the cost

No warning, no render error. The layout is handed maps where it expected strings; a
`FOREACH` over them emits empty values or stringified hashes. The page renders and
the only symptom is structured data quietly missing.

The reporter caught it only because they diff every page's `sections:` block against
`YAML::XS` using the engine's own subs - their probe printed DIVERGES for the block
form and MATCH for the flow form. Without that, it ships.

# The fix, and the trap in the obvious spelling

The reporter's recommendation is right in substance: try the scalar reading before the
mapping test. The obvious spelling of "wholly quoted" is wrong, though, and this is
the part worth having written down before anyone builds it.

A test of "starts with a quote and ends with the same quote" also matches:

    'a': 'b'

which is a legitimate quoted-key mapping, and reading it as a scalar would be a new
defect in exchange for this one. The discriminator is **whether the opening quote
closes at the end of the line**:

| Line | Opening quote closes at | Reading |
| --- | --- | --- |
| `'https://github.com/X'` | the last character | scalar |
| `'a': 'b'` | before the `:` | mapping |

So the shape is a small helper that answers that question, consulted in `_yaml_block`
between the sequence branch and the mapping test, and again in the mapping loop's
`last unless` at `:4107` so that a quoted scalar is never accumulated as a bogus key.
`_yaml_scalar` (`:4030`) already strips matched quotes correctly and needs no change.

# Scope

`_yaml_block` and its helpers have **one definition**, in `lazysite-processor.pl` -
checked across `lib/`, `plugins/`, `tools/` and `t/`. There is no pinned copy to keep
in parity, so ADR 0001's pinning discipline does not apply here.

The parser's own header comment at `:4025` promises "nested sequences ... and
quoted/bareword scalars". This is the case where those two meet, and the filing is
against the promise rather than against an absence.

# What must be tested

- The reported case: a block sequence of quoted URLs under a nested key, against the
  shape the reporter filed.
- **A quoted-key mapping still parses as a mapping** - `'a': 'b'` - because that is
  what the obvious fix breaks.
- Double quotes as well as single, and a quoted value containing no colon at all.
- The flow form, which is correct today and must stay correct.

# Also in the report, and NOT a defect

`layout-delete` on 0.14.4 takes `path=<name>` and refuses `layout=<name>`. SM911 LD2
added `layout=` for exactly this reason, so on the current tree both work: this is a
**version gap**, recorded here so that the next reader on a 0.14.x site does not
conclude the action is unreachable. Nothing to build.
