---
title: "SM261 - Where an agent trips: list-response keys, the activate parameter, and three documentation gaps"
subtitle: "A wrong response key is indistinguishable from an empty result, so a working call reads as a bug. Plus a theme name passed in a parameter called path, and three rules an agent can only learn by being refused."
brand: plain
status: shipped
status-note: "IMPLEMENTED in the 0.10.4 edge line (2026-08-09, commit 96934c5). Reported by the site agent 2026-08-08 after a 0.10.3 testing pass in which it made seven wrong calls, and explicitly separated the two that were its own fault (not reading the tool schema; testing a refusal without meeting its condition) from the five below. The reporter's own priority, if only one item is done, is the response-key convention - it nearly turned a working call into a filed defect. The reporter's honesty about its own errors is why the remaining five are worth taking at face value."
---

# SM261 - where an agent trips

## 1. List responses use five different container keys

```
list_versions          -> entries
list_content_history   -> files
list_domains           -> domains
form-list              -> forms
theme-list             -> themes
```

The reporter read `list_versions` as returning zero versions and began writing it
up as a defect. It was returning two `entries` perfectly well.

**This is the item to do if only one gets done.** A wrong key and an empty result
are indistinguishable to a caller: both are "nothing there". So the failure mode
is not an error - it is a confident, wrong conclusion, and the natural next step
is to file a bug against working code. That costs the reporter time and then
costs a maintainer time, repeatedly, for as long as the mix exists.

Two ways out:

- **Normalise to the tool's own noun** - `list_versions` returns `versions`,
  `list_content_history` returns `history` or `files` (pick one and say why).
  Cleanest to use, and a breaking change to any existing caller, so it needs the
  deprecation shape SM227 used for `rows` -> `row_count`: both keys for one
  release, the old one documented as going.
- **State the convention once** in the reference, if the current keys are
  deliberate. Cheaper, and leaves every future tool free to invent a sixth.

The first is right if the platform intends agents to construct calls from the
tool list; the second only defers the cost.

## 2. `theme-activate` takes the theme NAME in a parameter called `path`

`path` is the file-ish parameter everywhere else on the surface, so passing a
theme name to it does not occur to a caller building from the action list. The
reporter sent `theme=` and - before SM247 - silently de-themed a live site.

SM247 fixed the damage: an empty name is now an error that names `path`
explicitly. But that only helps someone who has already made the call and read
the error. Someone constructing the call from the action reference still meets
the trap.

Accept `theme=` as an alias, which is what everyone tries first, or state the
parameter in the action reference. Same question for `layout-activate`.

## 3. The active theme is read-only over WebDAV, and nothing says so

Not in the shipped docs - the reporter grepped. The server explains it well at
refusal time, which is how they learned, but it changes the whole editing
workflow: you cannot edit a live theme in place, you install under a new name and
activate.

An agent planning a theme change needs that BEFORE it starts, not after its first
403. `ai-briefing-layouts.md` is the right home, beside the mirror section. State
the reason too - a live theme cannot be corrupted mid-request - so it reads as
design rather than obstruction.

Same file: **where a theme lives** (`lazysite/layouts/<layout>/themes/<theme>/`)
appears only inside the assets discussion. The reporter tried `lazysite/themes/`
first and got a 403. Worth stating plainly as its own fact.

## 4. Nothing points an agent at `describe_capabilities`

`theme-delete`, `theme-upload` and `cache-invalidate` are manager-UI-only. The
refusals are good - SM237's message says "It exists, but is served only to the
manager UI over a cookie session" - and since SM239 `describe_capabilities` lists
`unlocks` per channel, which is the real answer.

What is missing is the pointer. Nothing tells an agent that
`describe_capabilities` is the authoritative list of what IT can call, so it
plans against the documented action list and discovers the subset by failing.

One line in the publishing briefing - "before planning a sequence of calls, read
describe_capabilities; it lists exactly which actions this account can use on
this channel" - converts a trial-and-error loop into a lookup.

## 5. `upload_file` is described well but never named its parameter

`ai-briefing-building-sites.md` is genuinely good here: it states the own-origin
rule, names `upload_file`, says `write_file` is text-only and will corrupt
binary, and gives the webfont and favicon cases. It never writes
`content_base64`.

The reporter guessed `content`/`encoding`. Adding the parameter name, or a
two-line example, closes the last step between reading the guidance and making
the call correctly.

## Scope

Items 3, 4 and 5 are a paragraph each in files that already exist, and should be
done alongside SM254 (engine docs drift) rather than as separate work. Items 1
and 2 are interface decisions and need the operator to choose before anything is
written.

The capability question the same report raised - an agent that can create themes
cannot delete them - is filed separately as SM262, because it is a change to the
permission model rather than to documentation.
