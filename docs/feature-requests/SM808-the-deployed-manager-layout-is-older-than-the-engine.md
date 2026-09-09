---
id: SM808
title: "SM808: the deployed manager layout is older than the engine that serves it"
subtitle: "139E-06 found a low-privilege account seeing five nav items ABSENT rather than marked - which is precisely the pre-SM775 behaviour. The template in the tree renders 16 items with 5 locked for that capability set, so the engine is right and the copy on edge is not. What cannot be answered from here is why."
brand: plain
standard-margins: true
status: candidate
---

# The evidence, and why it points at the deployment

The field compared three accounts on the same page:

    sysop       16 items,  4 locked
    ui-test-3   16 items,  7 locked   (manage_users only)
    ui-test-2   11 items,  0 locked   (five items absent entirely)

and concluded that the capability marking is only computed when the viewer
holds `manage_users`. That is an exact description of the template **before**
SM775: the locked branch was `[% ELSIF manager_caps.manage_users %]`, so an
account without it saw the item vanish rather than marked.

SM775 replaced that with an unconditional `[% ELSE %]`. Rendering the tracked
`starter/lazysite/manager/layout.tt` at the tested capability sets gives:

    users only    16 items, 7 locked
    content+nav   16 items, 5 locked
    capless       16 items, 7 locked

which is what the ref asks for. So the engine shipped in 0.13.9 is correct, and
what is running on edge is an older copy of one file.

# What cannot be settled from here

`dist/config/classification.json` puts `^starter/lazysite/manager/(.+)$` in the
**code** bucket, and the code bucket is refreshed on every upgrade - so the
deployed `lazysite/manager/layout.tt` *should* have been replaced. Either it was
not, or the site was not upgraded in the way the deploy reported.

The engine tree has no access to a deployed docroot, so this is where the
filing stops rather than guesses.

**One command settles it**, and it belongs to whoever can read the site: fetch
`lazysite/manager/layout.tt` from edge over WebDAV and grep for
`mg-nav-locked`. Present means the deploy worked and the fault is elsewhere;
absent means the code bucket did not refresh this file, which is a deployment
defect worth more than the nav.

# Why it matters beyond one template

If a file classified as code can survive an upgrade, then **any** starter-tree
fix can be shipped, tagged, deployed and still not be running - and every field
test of such a fix would report the old behaviour while the tree is correct.
That is an expensive shape of confusion, and 139E-06 is what it looks like from
the outside: a fix that was verified in the engine, reported as broken from the
field, with both observations true.

# Provenance

`inbox/2026-09-09-139E-results-0.13.9.md`, 139E-06 steps 3 and 4. The
three-account comparison is the field's; the render comparison is the engine's.
