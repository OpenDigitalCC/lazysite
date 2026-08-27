---
title: "SM291 - A malformed boolean published a hidden section, and reported success"
subtitle: "SM278 made the validator enforce the argument NAME. It never enforced the declared TYPE, and for `draft` the fallback ran in the destructive direction."
brand: plain
status: shipped
status-note: "FILED AND SHIPPED 2026-08-12 on main (unreleased), from the site agent's 0.10.7 validation of the same day - measured from outside over MCP, not inferred. draft:'yes-please' returned ok:1, CLEARED the flag, and a folder that was answering 404 to the public started answering 302. Same for 'enabled' and ['true']. Fixed at BOTH levels: validate_args now enforces declared booleans, and action_acl_set refuses an unrecognised draft rather than coercing it to false - the writer being the one that matters, since every surface funnels through it (SM267) and the control API hands it form-encoded strings no JSON schema sees. Booleans only, deliberately. t/unit/manager/68 verified failing on the stashed tree: 18 assertions."
---

# SM291 - the destructive default

## What was measured

A site agent re-testing 0.10.7 from outside, over MCP, on a folder holding
`draft: true`:

```datatable
columns: Value sent | Stored | Public GET | Matches the published schema?
widths: 4.5cm | 3cm | 2.5cm | X
bold: 1
tone: medium
---
omitted | draft kept | 404 | yes
true / "true" / 1 | draft kept | 404 | yes
false / 0 / "false" / "" | cleared | 302 | yes
null | draft kept | 404 | yes, read as omitted
"yes-please" | **cleared** | **302** | no
"enabled" | **cleared** | **302** | no
["true"] | **cleared** | **302** | no
```

Every row returned `ok:1`. The last three are the defect: a value the schema
declares invalid was neither refused nor treated as omitted. It was treated as
**publish**.

## Why this is worth more than a coercion tweak

**The inversion.** Omitting `draft` is safe and documented as safe - the schema
says *"omit to leave the current setting alone"*. Sending a malformed `draft`
was destructive. A typo is normally the safer of the two mistakes, and here it
was the dangerous one.

**It reported success.** A folder that had been returning 404 to the public
started bouncing to login, and the caller was told the call had worked. That is
the same shape as [[SM278]] (the flag silently dropped), [[SM283]] (the front
end serving what the ACL refused) and the SM285 probe that passed by testing
zero extensions. A control that reports success without doing what was asked is
this codebase's recurring defect, and it keeps arriving in a new place.

**The idiom is not uniform across tools**, so an agent cannot learn it once.
`rename_page` with `add_alias: "yes"` writes the alias - a non-empty string
reads as true there. `set_permissions` recognised `true`, `"true"` and `1` and
read everything else as *clear*. An agent applying what it learned on one tool
to the other un-hid protected content while being told it succeeded.

## What was built

**Refused, not coerced**, at two levels:

- `validate_args` in `lazysite-mcp.pl` enforces the declared type for
  **boolean** properties, so MCP callers get a schema-shaped message before the
  call runs - the same shape as the unknown-argument message SM278 added, which
  the reporter singled out as good.
- `action_acl_set` refuses an unrecognised `draft` outright. **This is the one
  that matters**: every surface funnels through this single writer (SM267), and
  the control API hands it form-encoded strings that no JSON schema ever sees.

Accepted spellings are unchanged: JSON `true`/`false`, `1`/`0`,
`true`/`false`, `yes`/`no`, `on`/`off`, and the empty string as false. A caller
that was already right is unaffected.

**Booleans only, deliberately.** They have a small closed set of sane
spellings, so refusing the rest cannot surprise a correct caller. Strings and
numbers are left alone: agents rely on the existing coercion there, and
tightening it needs its own measurement rather than a guess. The other nine
declared booleans - `analyse_visitors.index`, `create_theme.activate`,
`install_layout.update/all/activate`, `rename_page.update_links/add_alias`,
`site_apply.clean/adopt_identity` - now validate at the MCP layer for free;
only `draft` also has a writer-level refusal, because only `draft` decides
whether content is public.

## What this does NOT cover, and should be looked at

`site_apply.clean` is the other destructive boolean. Its unrecognised-value
fallback happens to be safe today (it does not clean), which is luck rather
than design - the same fallback in the same validator, pointing the other way.
It now refuses at the MCP layer; whether its own writer needs the same
belt-and-braces treatment as `draft` is worth deciding rather than assuming.

## Acceptance

- A malformed boolean is refused on every surface, and changes nothing - not
  the flag, and not the rest of the entry the same call carried.
- Every previously-accepted spelling still works, in both directions.
- The refusal says what is wanted and why the value was not guessed at.

## Related

[[SM278]] (the validator this extends, and the same class of defect),
[[SM267]] (one writer, which is why the writer-level refusal covers every
surface), [[SM283]], [[SM285]].
