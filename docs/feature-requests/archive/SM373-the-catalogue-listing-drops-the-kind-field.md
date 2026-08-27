---
title: "SM373 - the catalogue listing drops the field that says what a layout is for"
subtitle: "The layouts catalogue marks a demonstration layout `kind: demonstration` so a caller can filter gallery chrome out. `list_layout_catalogue` returned seven fields and not that one, on all 23 layouts."
brand: plain
status: shipped
status-note: "SHIPPED 2026-08-18. Reported by the layouts agent, corroborated independently by the site agent on a different instance and a different engine version, with a qualification that lowered the urgency rather than raising it - the signal was misplaced, not lost, since explorer is tagged `internal` and `showcase` and a caller could infer it. That is why this is a small fix and still worth making: a tag is a convention and `kind` is a contract."
---

# Why it matters more than one field

**It is the field [[SM337]] asked for.** Activation now warns when a layout
renders no navigation - but that is after installing it, binding it to a domain
and rendering a page. [[SM349]] measured **1 of 23** catalogue layouts rendering
the site's own navigation, so the question "is this a showcase or a layout I can
build on" is the one a caller most needs answered *before* committing.

The catalogue answers it. The engine was discarding the answer.

# And the mechanism will do it again

A hand-written allowlist that predates a key drops it silently. That is
[[SM330]]'s mechanism exactly: there the statistics index enumerated class keys
by hand and lost `scanner` - the largest class on the instrument - while the
durable store held it correctly.

So the test asserts the general property, not the field: **every scalar the
manifest declares survives the passthrough.** The next key added to the
catalogue fails the test rather than vanishing.

# The qualification, kept because it is the honest frame

The site agent's corroboration included this, and it changes what kind of defect
this is. `tags` passes through intact, and explorer's are
`["internal","showcase","clean","modern"]` - so a caller *could* filter today, on
a tag.

It is not a caller unable to tell a demonstration layout from a site layout. It
is a caller having to infer from a tag vocabulary what a dedicated field states
outright. Anyone can tag a layout `showcase` and mean something else, or omit the
tag and still set `kind`. Inference from a convention is not reading a contract,
which is the whole of [[SM203]].

# A note on how this was tested

The first version of the test wrote a fixture manifest to disk and asserted
against it. `action_layouts_manifest` fetches `manifest.json` **over HTTP**, so
the fixture was ignored and the assertions ran against the live 23-layout
catalogue - passing or failing on somebody else's file, over the network, without
saying so. Mocked at the fetch now.

# Related

[[SM337]] (activation reports what it bound; this is the half that comes first),
[[SM349]] (1 of 23 render the navigation), [[SM206]] (the description/tags
passthrough this extends), [[SM203]] (declared contract over convention), and
[[SM330]] (the same allowlist mechanism).
