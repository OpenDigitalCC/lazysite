---
title: "SM653: `tools/list` offers 26 content tools to a themes-only grant that `tools/call` then refuses, because the listing has no way to say \"on some paths\""
subtitle: "Site agent, 2026-08-26: enforcement is correct and this is not an access hole - the discovery surface is forced into a binary the capability model outgrew"
brand: plain
standard-margins: true
status: partial
status-note: "PARTIAL (PENDING). The listing now SAYS the third case: a tool offered only through the path-aware theme/layout override carries a note in its description - callable on theme and layout paths, refused elsewhere, and which capability would widen it. Description rather than a new annotation, per the release manager: a client that does not know a hint ignores it silently, and the reader here is a model reading descriptions. DERIVED from the same rule that decides callability (_path_only_for), not a second list of tool names - a hand-kept list would be another place to update and would be wrong the first time a tool gained a capability. WHAT REMAINS: whoami does not yet report the two classes separately (the filing's second remedy, which addresses SM525), and the count of over-listed tools is unchanged - they are now described accurately rather than withheld, which was the point."
---

# What is NOT wrong

`tools/call` enforces correctly. Measured immediately after the listing, same
token, same minute:

| Call | Result |
|---|---|
| `read_file {"path":"/index.md"}` | refused - *"Insufficient capability for read_file (needs manage_content)"* |
| `list_files {"path":"/"}` | refused, same wording |

No content was reachable. This filing is about what the grant was *told* it
could do.

# Why discovery disagrees

`_tool_callable` is shared by `tools/list` and `whoami`, and both call it
without a path:

    return 1
        if $tool->{path_aware} && ( $caps->{manage_themes} || $caps->{manage_layouts} );

At call time there is a path, and the override is correct: a themes grant
genuinely may read and write under the theme and layout roots. At listing time
there is no path, so the override applies unconditionally, and all 27
`path_aware` tools are advertised.

The rule is right. The listing is being asked a question it cannot answer with
the vocabulary it has.

# The third case

The source comment frames the listing choice as a binary: is it worse to offer
a tool that will be refused, or to withhold one the caller may call? The path
rule produces a third case - **callable, on some paths** - and the listing can
express neither "yes" nor "no" about it truthfully.

That is why picking a side makes it worse either way. Withholding the tools
recreates SM210 in the opposite direction and hides capability the grant really
has; listing them plainly is what happens now.

# Fixes

| Fix | Note |
|---|---|
| Say so in the advertised description when the grant reaches a tool only by the path rule - *"for your grant: paths under `lazysite/layouts/` only"* | Cheapest honest fix. Discovery stays complete, the agent is not misled, enforcement untouched |
| Add a listing annotation - a `pathScopeHint` alongside the existing `readOnlyHint` machinery | Machine-readable, and the annotation slot already exists |
| Have `whoami` report the two classes separately - callable generally, versus callable on theme/layout paths only | `whoami` is where an agent checks its own reach, so this addresses SM525 directly |
| Withhold `path_aware` tools from a themes-only listing | **Not recommended** - recreates SM210 inverted |

One of the first two, plus the third.

# The audit ran, and found a scope escape

**Done 2026-08-27, and it was not the listing problem it was scoped as.** Six
`path_aware` tools declared no `path`/`to`/`from` argument. Four of them
(`audit_site`, `read_nav`, `list_pages`, `regenerate_registries`) genuinely
take no path, and their flag has been removed - it could never fire at call
time and made them visible to a themes-only grant at listing time. That is
27 tools down to 23, so the over-listing this filing is about is smaller.

The other two were the finding. `create_page` takes `slug`; `rename_page`
takes `old` and `new` - real paths, under names the confinement passes did not
inspect. A grant scoped to one domain created and moved content in another.
Fixed as **SM661**, which also names every path-carrying argument once and
lints against the list drifting again.

So the remaining scope of THIS filing is the original one: 23 tools are offered
to a themes-only grant that can call them only on theme and layout paths, and
the listing has no vocabulary for "on some paths". Enforcement is correct.

# A sharper form of the same gap, found building SM654's lint

Several tools carry `path_aware => 1` and appear to accept no path at all -
`read_nav`'s own comment says so outright: *"its run passes only `host` and no
path - so the dispatcher's carve-out pass had nothing to inspect"*.

On such a tool the flag is not merely imprecise, it is meaningless: there is
nothing for the path rule to test, so the override applies unconditionally at
call time as well as at listing time. That is this filing's problem in its
strongest form.

It is NOT acted on here, deliberately. Telling "takes a path under another
name" (`move_file` takes `from` and `to`) from "takes no path" needs more than
a regex over the tool table, and `path_aware` decides who reaches what. Worth a
deliberate audit of the flag as part of whatever fix this filing takes, rather
than a guess.

# Two incidental observations, recorded so they are not re-found

`theme-upload` is declared in no capability's `unlocks` and is a CHANNEL
refusal (manager-UI only). That is consistent, and is noted only because a
sweep probes it and a reader may wonder why it is absent from the declared list.

`theme-delete` enforces ownership, refusing with `kind: "not-yours"`. Same shape
as the ACL ownership rule, and working.
