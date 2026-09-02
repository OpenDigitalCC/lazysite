---
id: SM741
title: "SM741: the save guard refuses what the renderer tolerates"
subtitle: "A page whose template does not parse renders happily through the raw fallback, and has done for months. Since SM708 it cannot be saved. So a page can exist that no operator is able to edit - including to fix it."
brand: plain
standard-margins: true
status: open
---

# The moment this fills

SM708 refuses a save when the page body's template does not parse, on the
manager and on WebDAV PUT (SM729). The intent is right: an unparseable page is a
page that will disappoint someone later, and refusing at the door is better than
a broken render.

The field agent characterised the behaviour on 0.12.0 and found the edge of it:

- A page carrying a **valid** `[% ... %]` directive saves and renders. Merely
  containing `[%` is fine.
- A page whose `[%` **does not parse** is refused **415** on save - and the guard
  does not care whether the body was already like that.

**The renderer does not refuse those pages.** It falls back to raw and serves
them, which is why such a page can have existed happily for months before the
upgrade. A documentation page showing an `[% FOREACH %]` example outside a code
fence is the obvious shape, and this site family writes a lot of documentation.

# The trap

The page renders. It cannot be saved. So:

- An operator who opens it, changes a typo and saves is refused.
- An operator who opens it to **fix the very syntax the guard objects to** is
  refused too, unless their fix happens to be complete and correct in one pass.

The guard was built to stop bad content arriving. On pre-existing content it
also stops content **leaving** that state through the normal editing route.

# The decision this needs

Not obvious, and it belongs to the release manager rather than to me:

**Refuse only a save that makes it worse.** If the body already failed to parse
before the edit, and still fails after it, the save is not introducing the fault
- it is an operator working on a page that was already broken. Refusing a save
that reduces the number of parse errors is actively unhelpful.

**Or hold the line and provide a route.** Keep the refusal absolute and accept
that fixing such a page needs something other than an ordinary save - in which
case that route has to exist and be documented, because at present there is not
one short of writing the file on the host.

The first reads better against how the renderer already behaves: the engine's
existing position is that an unparseable page is servable. A save guard stricter
than the renderer is the inconsistency, not the page.

# What is not yet known

**The incidence.** The field agent could not establish how many pre-existing
pages on a stable site are in this state, because they have no read access to
one. The check is cheap for whoever does: find page bodies containing `[%`, and
test which fail to parse.

If the answer is zero, this is theoretical and can wait. If it is not zero, every
one of those pages is uneditable through the manager the moment 0.12.0 deploys,
and that changes the urgency.

# Provenance

Edge testing agent, 0.12.0 stable pass, V12-03. Behaviour proved on edge; the
incidence question is open and needs stable access.
