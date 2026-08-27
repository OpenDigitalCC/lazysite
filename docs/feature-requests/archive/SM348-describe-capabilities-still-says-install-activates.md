---
title: "SM348 - describe_capabilities still says install_layout activates"
subtitle: "SM314 corrected the tool description, which now states the opposite plainly. The `switch-layout` task in describe_capabilities - on both the API and MCP surfaces - still tells the reader that install_layout installs AND activates in one step."
brand: plain
status: shipped
---

# SM348 - the orientation document contradicts the tool

## What was measured

edge 0.10.12. The `install_layout` tool description, which [[SM314]]
fixed:

> Install a layout and its theme(s) from the repo on demand. **Installing
> does NOT activate**: the layout is placed on the site and nothing
> visitors see changes until you call `activate_layout` (SM176 -
> activating is the part that changes the live site, so it is always asked
> for explicitly).

Its `activate` parameter is documented `default false`, and measurement
agrees: a default install returns `{"activated":false,"ok":1}`.

`describe_capabilities` (MCP) and `describe-capabilities` (control API),
task `switch-layout`, step 2 - byte-identical on both surfaces:

> call `install_layout` (MCP) or POST `action=layout-install` (control
> API) - **it installs AND activates the new layout in one step**

## Why it matters more than a stale sentence

**It is the document read first.** `describe_capabilities` exists to
orient an agent before it does anything. Its `tasks` list is the closest
thing the platform has to "here is how you perform this operation", and
an agent following the documented sequence will install a layout, believe
the site has switched, and move on. Nothing visitors see will have
changed.

**The next step in the same task is destructive.** The task continues:

> ONLY THEN, if the old layout is no longer wanted: `delete_layout` /
> `layout-delete`.

An agent that believes step 2 activated the new layout proceeds to delete
the old one - which is still the active layout. That is refused, correctly
and by design, but the caller is now in a state its instructions did not
predict, holding an installed-but-inactive layout and an error about
deleting the active one.

**SM314 was filed against exactly this claim.** The fix corrected the tool
schema and left the same assertion standing one surface away. This is the
recurring shape the register keeps recording: two surfaces disagreeing
about one question, with the fix applied to whichever one was reported.

## The fix

Correct the `switch-layout` task text to match `Layouts.pm` and the tool
description - install, then activate, then optionally delete.

Then consider the general form, because a task list that restates tool
behaviour in prose will drift from it again. The task steps already name
the tools; if the step text were generated from, or lint-checked against,
the tool descriptions, this class of drift would be caught the way
`t/lint/26` catches changelog and backlog disagreement.

## Verification

- The `switch-layout` task no longer says install activates.
- The task text and the `install_layout` description agree, on both
  surfaces.
- A lint asserts that no `describe_capabilities` task step contradicts
  the tool description it names - or, minimally, that the phrase
  "installs AND activates" appears nowhere.
- Following the task steps verbatim produces an activated layout.

## Related

[[SM314]] (the same claim, corrected in the tool schema), [[SM176]] (why
install never activates), and
`inbox/four-surface-validation-0.10.12-2026-08-17.md`.
