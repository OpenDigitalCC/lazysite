---
id: SM934
title: "SM934: a form's declared field rules are enforced by nothing on the server"
subtitle: "`required`, `email`, `max:N` and `pattern:` are rendered as HTML attributes and checked by the browser alone. The submission handler validates uploads and refuses an entirely blank post; between those two there is no per-field validation at all, so a direct POST stores whatever it likes in a field declared otherwise. Found by a scanner doing exactly that."
brand: plain
standard-margins: true
status: candidate
raised: 2026-10-02
raised-by: the sites agent asked which half the gap was in (opendigital.cc); measured here against the handler
area: forms
status-note: "RULED 2026-10-02: ENFORCE AND REFUSE, WITH A NAMED REASON. The declaration becomes a contract rather than a hint. MEASURED FIRST, and the measurement is what makes this a filing rather than a suspicion: `plugins/form-handler.pl` validates uploads (`validate_uploads`, against the form's `upload` settings) and refuses a submission where every visible field is blank and no file arrived. THERE IS NOTHING ELSE. No `required` check, no `email` check, no `max:N` length check, no `pattern:` check. All four are rendered into the HTML and enforced by the browser, so they hold for a visitor using a form and not at all for a direct POST - which is the traffic that needs them. THE HAZARD THE BUILD MUST DESIGN FOR, because it is SM921 inverted rather than anything new: SM921's shipped `tel` pattern was a valid Perl regex and an INVALID HTML one, and the specification's answer to a pattern a browser cannot compile is to IGNORE THE ATTRIBUTE IN FULL - so the field validated nothing and no console message said so. If the server now compiles that same string as a Perl regex and refuses on it, the server and the browser disagree about what the rule means, and the visitor is refused for a rule their browser accepted. Worse, if `cannot compile` is treated as `nothing matches`, one bad character turns a form from accepting everything into accepting nobody, silently. So: a pattern that does not compile is treated as ABSENT at submit time, exactly as the browser treats it, and the condition is reported where an author will see it - never converted into a refusal. `required` binds only on fields the form declares, so a visitor is never refused for a field they were not shown. And the refusal names the field and the rule, because `invalid submission` sends somebody to the wrong place, which is SM923's cap-message lesson."
---

# Measured

`plugins/form-handler.pl`, on the submission path, performs exactly two content
checks:

1. **uploads** - `validate_uploads( $files, $conf->{upload} )`, and a refusal if the
   form does not accept files at all;
2. **not entirely blank** - at least one non-`_` field matching `\S`, or a file.
   Its own comment says why: "HTML5 `required` stops this in a browser, so it is
   almost always an automated/blank POST".

Between those, nothing. The field rules an author writes in a `:::form` block -
`required`, `email`, `max:N`, `pattern:` - reach the rendered HTML and stop there.

**Grade: read from the handler (A).** The occasion for reading it was a report; the
finding is the code.

# How it surfaced

A scanner sent five submissions to a live contact form inside two seconds: a
baseline, a bare quote, `' OR '1'='1'-- -`, another baseline, then a quote in a
second field. A textbook automated SQL-injection sweep.

**It did not work, and the filing it came from says so plainly**: the payload is
sitting in the submission store as a literal string, which is the correct outcome and
says the storage path escapes properly. That report "is not a vulnerability report
against the data layer".

What it did show is that **`'` and `' OR '1'='1'-- -` were both stored in a field
declared `email`**. A browser with `type=email` refuses them, so this was a direct
POST - and the reporter could not tell whether the gap was the form's own definition
or the engine, because `lazysite/forms/` is a denied path for every grant. It is the
engine.

# What it costs

- **A declared rule that the engine ignores.** The author writes `email`, the
  manager renders it, the docs describe it, and a POST ignores all three. This
  project has a name for that shape.
- **Stores and tables take what they are given.** A value far longer than `max:N`, a
  non-address in an `email` field, a missing `required` field - all stored, and the
  table handler's own field map is the only thing that drops unexpected keys (SM923).
- **An `email` field whose value cannot be mailed.** Anything built on the
  assumption that the column holds an address - a reply, an opt-in confirmation,
  SM877's `to_field` - inherits the gap.
- **SM921 improved the client-side guard on a field whose server-side guard does not
  exist.** Worth saying because it is the same field, and because it bounds how much
  that fix achieved.

# What should change

| Ref | Change |
| --- | --- |
| FV1 | Each declared rule checked on the server at submission, and a breach refused, **naming the field and the rule** |
| FV2 | A `pattern:` that does not compile is treated as **absent**, as the browser treats it, and reported where the author will see it - never a refusal |
| FV3 | `required` binds only on fields the form declares; a visitor is never refused for a field they were not shown |
| FV4 | The refusal is a user-facing one in the handler's existing voice (`reject_user`), not a 500 and not a silent store |
| FV5 | A test per rule, and one that a form carrying an uncompilable pattern still accepts an ordinary submission - the SM921 case, asserted from the server side this time |

# What this filing does not claim

- **Not** that the storage path is injectable. The evidence says the opposite.
- **Not** that the browser-side attributes should change. They are correct and stay.
- **Not** that validation belongs in the renderer. `Lazysite::Validate` already
  holds the authoring-time check (SM921); this is the submit-time half.

# Related

[[SM921]] (the pattern that did not compile, and why an uncompilable rule must not
become a refusal), [[SM923]] (what reaches a handler, and the cap message that sent
somebody to the wrong place), [[SM904]] (a form value is decoded once),
[[feedback_a_declaration_the_code_ignores]].
