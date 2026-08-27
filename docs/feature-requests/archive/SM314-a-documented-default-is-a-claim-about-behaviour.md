---
title: "SM314 - install_layout documented an activation it never performs"
subtitle: "Four statements describing behaviour SM176 deliberately removed, published through tools/list to every agent, with no second source to check them against"
brand: plain
status: shipped
status-note: "SHIPPED on claude/sm305-principal-picker-and-polish. All four statements corrected, and t/lint/49 added to hold the CLASS rather than the instance - nine descriptions state a default and none was checked. FILED 2026-08-15 from a site-agent report measured on edge/0.10.9: install_layout with defaults returned {\"activated\":false,\"ok\":1} and the instance's eight domain bindings were byte-identical before and after. The behaviour was correct throughout; only the documentation was wrong."
---

# SM314 - the only contract an agent has

## What was found

`install_layout` documented itself as installing **and activating** a layout. It
does not activate, by design, and the design is explicit
(`Manager/Layouts.pm:958`):

```perl
# SM176: install NEVER auto-activates - not even on a fresh site. Activation
# ... explicit activate:true opts in.
my $activate = $req->{activate} ? 1 : 0;
```

Four statements said otherwise:

```datatable
columns: Where | What it said | Actual
widths: 4.6cm | 7.6cm | X
bold: 1
tone: medium
---
`install_layout` description | "Install a layout ... then activate it" | installs only
`install_layout` description | "install + activate in one step" | installs only
`install_layout.activate` schema | "activate after install (default true)" | default is false
`delete_layout` description | "install_layout does both" | it does one
---
```

Measured on edge/0.10.9, `install_layout` with defaults returned
`{"activated":false,"ok":1}` and the instance's eight domain bindings were
byte-identical before and after. **The behaviour is correct. Only the
documentation was wrong.**

## Why it is worse than a typo

**It routed an agent into a refusal it could not explain.** `delete_layout` told
the agent to install the replacement and then delete the old layout, on the
stated grounds that `install_layout` had switched them. The switch never
happened, so the old layout was still active, and deleting the active layout is
always refused. The agent followed the documented sequence exactly and was left
holding a refusal that contradicted the instruction which produced it.

**It failed towards a site that looks finished and is not.** An agent trusting
"install + activate in one step" reports the restyle as complete. The site serves
the old layout. Nothing errors, and the next person to look is the customer.

**It cost a wrong belief in both directions.** The reporter, reading the schema,
passed `activate:false` as a precaution against restyling every domain on the
instance, then wrote that hazard up. There was no hazard. A reader defending
against the claim defended against nothing.

## The class, which is the real finding

**A tool description is the strongest claim in the system.** It is machine-read
by the caller, it is the only contract an agent has, there is no second source to
compare it against at runtime, and no human reads it between `tools/list` and the
call. It was also the least checked thing in the repository.

Nine descriptions state a default. Each is a claim about behaviour and none was
verified.

The answer was already built twice for weaker claims - `t/lint/36` pins a
reference document against its source, `t/lint/45` asserts every field ADR 0008
freezes is actually read. The pattern was established; it had simply never been
pointed at the tool surface.

`t/lint/49` does that. It extracts every stated default and asserts that no
description claims a boolean default of `true` - because in this codebase an
optional boolean reaches its handler only when the caller passes it, and the
handler tests truth, so the effective default is always `false`. A description
claiming `true` is describing behaviour that does not exist, to the one reader
who cannot check.

## Verification

`t/lint/49`, shown to fail on the pre-fix descriptions across all four
statements:

- no description claims a boolean default of `true`;
- `install_layout` does not claim to activate, states plainly that it does not,
  and names `activate_layout` as the tool that does;
- `delete_layout` no longer recommends a sequence that ends in an always-refused
  delete, and names the activation step its sequence needs;
- `install_layout.activate` documents `default false`, which is the field a
  cautious agent reads before deciding whether a call is safe.

## Related

SM176 (the filing that made install inert, and which this documentation
contradicted), `t/lint/36` and `t/lint/45` (the same shape for weaker claims),
and `inbox/archive/2026-08-15-install-layout-description-contradicts-its-behaviour.md`.
