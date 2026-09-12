---
id: SM862
title: "SM862: reading submissions reported an absent parameter as an invalid value, and would not take the form name every other surface takes"
subtitle: "`form-submissions` took `file` only. Called with `form=<name>` - which is what the MCP twin takes, and what `form-targets-read` takes on the same channel - the path validator received nothing, failed its `.jsonl` test and answered `Invalid submissions file` with 400. The caller is told their value is wrong about a value they never sent. The site agent nearly filed it as a broken action, and says it is the fourth time this campaign."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-09-12 for 0.13.14, as the release manager ruled: name the missing parameter AND accept `form=`. The form name resolves through `Handlers::form_store_dir` - the resolver SM855 built and MCP uses - so the two channels cannot disagree about where a form's submissions live. Neither parameter is marked `required` because exactly one is needed: the action answers for that by name, with kind `missing-parameter`, before the path validator can describe an absence as malformed. t/unit/manager/188 holds all four cases."
raised: 2026-09-12
raised-by: site agent (1313E, "two things that cost me time")
area: forms
---

# What was found

> "**`form-submissions` takes `file`, not `form`.** Called as
> `form-submissions&form=1313e-esc` it answers `{"ok":false,"error":"Invalid
> submissions file"}` with 400, for a form whose store `form-list` reports as
> present with one row. I nearly filed that as a broken action. It is the fourth
> time in this campaign that a **missing or misnamed parameter is reported as an
> invalid value**; SM773's "<param> is required (in the body)" already exists and
> would end it here too."

# Two faults, and fixing only the message would have left the worse one

**The message.** `_submissions_path(undef)` sets `$rel` to the empty string, which
fails `/\.jsonl\z/`, and the refusal says `Invalid submissions file`. Nothing was
invalid: nothing was sent. A caller reading that goes and inspects a value they
never supplied, which is precisely the time the agent lost.

**The parameter.** `form=` was the reasonable thing to send, because everywhere
else a form is named by name:

- MCP's `read_form_submissions` takes a form name and resolves the store - that
  is what [[SM855]] built `Handlers::form_store_dir` / `form_store_file` for.
- `form-targets-read`, on this same control API, takes `{ name => 'form' }`.

So the control API's submissions read was the odd surface, and a caller who had
learnt the system's own vocabulary was punished for using it. That is the surface
parity shape, not a wording problem.

# The fix

`action_form_submissions( $file, $form )`. A form name resolves through
`Handlers::form_store_dir` - **the same resolver MCP uses**, so the two channels
cannot drift about where a form's submissions live - and RELATIVE rather than
absolute, because `_submissions_path` needs the configured directory, which is
the distinction SM855 split the two helpers apart for.

When neither arrives:

```
No submissions named. Pass `form` with the form's name, or `file` with the path
to its .jsonl store - `form` is the one to reach for, and is what the MCP tool
takes.
```

with `kind: missing-parameter`.

**Why neither parameter is marked `required`.** SM773's `_missing_required`
hoists a refusal for a single parameter the action already refuses absent. Here
*exactly one of two* is needed, which that mechanism does not express - and
marking `file` required would refuse the `form=` call before it reached the
resolver. So the action answers for it, in SM773's spirit and with its wording
shape: name the parameter, say where it goes, stop before the branch that would
mis-describe it.

`file` still works and still wins when both are sent, so no existing caller
changes. The declaration now publishes both, each with a note saying which to
reach for, so `describe-capabilities` teaches the preferred one.

# Related

[[SM855]] (the resolver this uses, and why it is two helpers), [[SM773]] (a
missing parameter named as missing - the mechanism, and why it does not stretch
to one-of-two), SM239 (surface parity between MCP and the control API, enforced),
[[feedback_missing_parameter_named_as_missing]].
