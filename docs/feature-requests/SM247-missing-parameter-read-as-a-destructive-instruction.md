---
title: "SM247 - theme-activate read a missing parameter as an instruction to deactivate, and reported success"
subtitle: "The control API defaults `path` to '/', the name sanitiser reduces '/' to the empty string, and the empty string meant DEACTIVATE. A site agent stripped a live site's theme and was told ok:1."
brand: plain
status: shipped
status-note: "IMPLEMENTED in the 0.10.3 edge line (2026-08-08, commit 1b8834a). Reported by a site agent that did exactly this to a live site and caught it only by checking theme-list immediately afterwards. Written up AFTER the fact, 2026-08-08: the fix shipped without a feature-request doc, and t/lint/26 (SM258) found the gap by noticing that 0.10.3 claimed an SM number with no filing behind it - the first thing that lint caught beyond the drift it was built for."
---

# SM247 - a missing parameter was read as a destructive instruction

## What happened

`theme-activate` called with the theme name in the wrong parameter stripped the
site's theme and returned `ok:1`.

The chain:

1. the control API defaults `path` to `/` when it is absent;
2. `action_theme_activate` sanitises the name with `s/[^a-zA-Z0-9_-]//g`, which
   reduces `/` to the empty string;
3. the empty string meant **deactivate**.

So `?action=theme-activate&theme=house` - the name in a plausible-looking
parameter that the action does not read - deactivated the theme and reported
success. A site agent did this to a live site and caught it only because it
checked `theme-list` immediately afterwards. An agent trusting `ok:1` walks away
leaving a site unstyled.

## Why it was worth a fix rather than a note

The failure is not that the caller made a mistake - it is that a mistake was
indistinguishable from an instruction, and the destructive reading won. Nothing
in the request said "remove the theme"; the platform inferred it from an absence.

Reporting `ok:1` compounds it: the caller is told the thing it asked for
succeeded, so no one looks again. That is the same shape as SM256 and SM257 filed
later in the same release line, and the reason the three were grouped as "success
reported for work not done".

## What shipped

- An empty theme name is an **error**, `kind: missing-parameter`, whose message
  names `path` as the parameter that carries the name.
- Deactivation still exists and now has to be asked for: `deactivate=1`.
- `layout-activate` had always required a name; that is pinned in the same test
  so the two cannot drift apart.

The property under test is deliberately stronger than "empty means error": the
destructive branch is reachable ONLY by asking for it.

## Where it is tested

`t/unit/manager/53-activate-missing-parameter.t`, which drives the reported call
shape (`action_theme_activate('/', {})`) and asserts the site theme is untouched
afterwards - the whole point, and the thing the reporter had to check by hand.

## Related

SM261 records the remaining half of this, which the fix does not address: the
parameter is still *called* `path` while carrying a theme NAME, so a caller
building from the action reference rather than from an error message still meets
the trap. That is a naming decision rather than a defect.
