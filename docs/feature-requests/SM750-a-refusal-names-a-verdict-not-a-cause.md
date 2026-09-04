---
id: SM750
title: "SM750: a write refusal records a verdict where the log needs a cause and a remedy"
subtitle: "raw-content-refused, invalid arguments, Invalid path. Each says a rule fired and none says which rule, what about the input broke it, or what to do instead - while one older entry in the same log states cause and remedy in a single line, and is the standard the others should meet."
brand: plain
standard-margins: true
status: candidate
---

# What was measured

A partner agent was asked to establish why writes were failing on a live site
and read the audit trail to do it. The trail recorded the failures. It did not
let a reader work out the cause:

| Action | `detail` |
| --- | --- |
| `edit /vision.md` | `raw-content-refused` |
| `replace_text` on a `layout.tt` | `invalid arguments` |
| `edit` on a theme file | `Invalid path` |

The actual cause of the first was a legacy 0.7.13 page carrying `api: true` and
`content_type: text/html` with a full HTML body - a raw page the 0.12.x guard
now refuses. **None of that is recoverable from the four words in the log.** It
was resolved by fetching the page over WebDAV and recognising the shape by
hand, which is not a step the audit trail should require.

# The standard is already in the same log

One older entry gets it right, and it is the argument for the rest:

> `Cannot write file: Permission denied (the file is not writable by the
> web-server user - run: lazysite check --fix)`

Cause and remedy in one line, needing no external investigation. That is not an
aspiration - it is a string this engine already emits, in the same field, to
the same reader.

# Why these three are hard to act on

**`raw-content-refused` names a verdict.** Not which rule fired, not what about
the content was raw - front matter `api:`/`raw:`? a hand-authored `<!doctype>`
body? a disallowed `content_type`? - and not what the author should do instead.
Three different faults produce one word.

**`invalid arguments` and `Invalid path` do not echo the offending input.** A
reader cannot see which argument or which path was rejected, so the message is
compatible with every possible mistake.

# The fourth instance of one class

This is a pattern rather than three strings. Filed this week alone:

- **SM712**: a capability refusal named the action, not the capability needed.
- **SM730**: a blocked upload named the rule after being asked to.
- **SM749**: the active-theme refusal offers two escapes and never says what to
  do instead.
- **This**, across the write path generally.

The house rule is written and keeps being rediscovered: **a refusal a caller
cannot act on sends them to ask a person.** What is missing is anything that
enforces it, which is why each instance has had to be found in the field.

# What is asked for

**A refusal carries cause and remedy**, in the string returned to the caller
AND in the audit `detail`. For the measured case: name the front-matter key
that put the page in raw mode, and say that ordinary pages are Markdown with
presentation in the layout or theme.

**An argument refusal echoes the argument**, or the path, so a reader can see
which input was wrong. Subject to SM739's rule - no host paths, no driver
vocabulary - which the caller's own path does not breach, since they sent it.

**The mechanism already exists.** SM711 half 2 added `audit_detail`: a refusal
builds a short scannable form for the trail while `error` stays the operator's
sentence, and the dispatcher prefers it. That is exactly the filing's own
suggestion 3 - a terse log that a reader can still resolve - and it is built.
What remains is to use it at these sites.

# Could a lint have caught it

Not the wording. But the SHAPE is checkable, and this is the fourth instance,
so it is worth the check: a caller-facing refusal that names only a verdict -
a bare `kind`, a two-word string with no verb - is a candidate for review. It
would have flagged `raw-content-refused` the day it was written.

`t/lint/112` already checks the inverse for these strings: that they do NOT
carry a path, a driver prefix or an echoed command. The two rules are the same
family and belong side by side - what a refusal must not say, and what it must.

# Provenance

Partner agent on a live site, 2026-09-04, measured from outside over HTTP with
no engine-source access. The filing is explicit about what it does not
establish: whether the refusal is raised on the incoming payload or the stored
state, and whether the connector error already carries more than the audit
detail preserves. Both are open and neither changes the ask.
