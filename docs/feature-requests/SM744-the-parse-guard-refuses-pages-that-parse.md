---
id: SM744
title: "SM744: the parse guard refuses pages that parse"
subtitle: "SM708 strips four-space-indented lines as code blocks before parsing. A multi-line TT directive whose continuation lines are indented loses its middle - including its closing %] - so the guard reports a parse error on a page the renderer serves perfectly. Five of the seven refusals across every tree we can reach are false, and the two that are not are CHANGELOGs."
brand: plain
standard-margins: true
status: shipped
---

# The defect

`page_parse_issues` prepares a body for parsing by removing what the processor
protects:

```perl
if ( $line =~ /^[ \t]{0,3}(?:```|~~~)/ ) { $in_fence = !$in_fence; next }
next if $in_fence;
next if $line =~ /^(?: {4}|\t)/;    # indented code block
```

The third rule is the problem. **It has no idea whether it is inside a template
directive.**

A multi-line TT comment written the way anyone would write one:

```
[%# Programmes grouped by category, each ordered by position. The `internal` tier
    is filtered out here so it never appears in the public catalogue (DESIGN:
    internal is hidden from the catalogue). Tier + supervision + draft state show
    as badges. Robust for many programmes across many categories. %]
[%- FOREACH cat IN categories -%]
```

Lines two to four are indented four spaces, so the guard deletes them - **and the
closing `%]` goes with them.** What reaches Template is `[%# Programmes...` left
open, which then swallows the `[%- FOREACH -%]` that follows. The loop never
opens, and the matching `[%- END -%]` thirty lines later is reported as
`unexpected token (END)`.

The page is fine. The renderer parses it without complaint. Only the guard's
mutilated copy fails.

# Proof

Same body, parsed twice - once with the guard's stripping, once without the
indented-code rule:

```
AS THE GUARD DOES (drops indented lines)
    REFUSED: parse error - input text line 36: unexpected token (END) [% END %]

WITHOUT the indented-code rule
    PARSES
```

# The scale, measured

Across every tree reachable from `/srv/projects` - 495 markdown files carrying
`[%`, engine tests and libraries excluded - the guard refuses **7**. Classified
by re-parsing each without the indented-code rule:

| | Count | Which |
| --- | --- | --- |
| **False refusals** - the page parses | **5** | `xi/marketing/lazysite/site/contact.md`, and four pages of the learning app (`build/index.md`, `live-snapshot2/catalogue.md`, `logout-ux/catalogue.md`, `p5/index.md`) |
| Genuine parse failures | 2 | `lazysite/CHANGELOG.md`, and a copy of it in a scratch rig |

**Every one of the false refusals is a real site page. Neither of the genuine
failures is a page at all** - both are CHANGELOGs, which are repository documents
and are never saved through the manager.

So on the evidence available, the guard's entire observed effect on real content
is to refuse saves it should allow.

# What it costs

The refusal is a **415 on WebDAV PUT** (SM729) and a refusal in the manager
(SM708). A page in this state cannot be edited through any supported route -
including, pointedly, to remove the construct the guard objects to, since the
construct is not the problem.

Four of the five are pages of a live application. Its author cannot save an edit
to them.

# What shipped

The second option. An indented line is now treated as a Markdown code block
only where one may begin - **after a blank line** - which a directive's
continuation line never follows. The stripper needs to know no template syntax
to tell the two apart.

A blank line does not close an indented block, because Markdown lets one resume
across a blank; only an unindented, non-blank line does.

Re-running the measurement against the fixed module, over the same 495 files:

| | Before | After |
| --- | --- | --- |
| False refusals | 5 | **0** |
| Genuine parse failures | 2 | 2 |

Both survivors are still the CHANGELOGs, still correctly refused.

`t/unit/manager/150` carries the case, and deliberately carries more than the
one bug: that a real indented example is still stripped however unbalanced (the
behaviour the old rule existed for, and which `ai-briefing-layouts` ships), that
an indented block survives a blank line inside it, and that SM708's original
refusal still fires. That last fixture is borrowed verbatim from
`t/unit/manager/140` rather than invented - the first draft invented its own
JavaScript, which the **shipped** guard did not refuse either, so it would have
asserted nothing.

# The correction

The rule wants to skip Markdown code blocks. It should not fire inside an open
template directive. Two ways, and the second is better:

**Track directive state.** Do not drop an indented line while a `[%` is open.
Cheap, and fixes exactly this case.

**Strip indented blocks the way Markdown defines them** - an indented code block
begins after a blank line. A continuation line of a directive never follows a
blank line, so the ambiguity disappears without any template awareness at all.

The fence rule and the inline-backtick rule are both fine and should stay. The
backtick rule did edit a directive here - it removed `` `internal` `` from inside
the comment - but harmlessly, because it cannot cross a line and so cannot eat a
`%]` that sits on a different one. Worth a test that says so, since it is true by
accident of the regex rather than by design.

# What this does to SM741

**It largely dissolves it.** SM741 asked whether the guard should refuse a save
that leaves an already-unparseable page no worse. On the measured evidence that
question is close to hypothetical: no served page in reach is genuinely
unparseable. The pages that cannot be saved cannot be saved because the guard is
wrong about them.

Fix this first. Then ask SM741's question again against whatever is left, which
may be nothing.

# Could a lint have caught it

Not a lint - a fixture. The guard's tests describe pages where the code-block
rule and the directive never meet. **A fixture whose TT spans lines, indented, is
the whole defect**, and it is one test.

This is the same shape as SM738's composed-document fixtures, which used parts
with no front matter and so passed eleven sabotage tests against a case the
feature was not for. Twice now the tests have described a tidier document than
the ones people write.

# Provenance

Found while checking SM741's incidence for the 0.12.0 stable pass. The field
agent had characterised the refusal on edge and could not reach real content to
count it; the count is what exposed this.
