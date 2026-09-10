---
id: SM808
title: "SM808: the deployed manager layout is older than the engine that serves it"
subtitle: "139E-06 found a low-privilege account seeing five nav items ABSENT rather than marked - which is precisely the pre-SM775 behaviour. The template in the tree renders 16 items with 5 locked for that capability set, so the engine is right and the copy on edge is not. What cannot be answered from here is why."
brand: plain
standard-margins: true
status: superseded
status-note: "CLOSED 2026-09-10 - NO DEFECT, and superseded by SM775 and SM807, whose design this filing reported as missing. Its diagnosis (a stale deployed layout) was wrong on 2026-09-09, and the re-measurement on 2026-09-10 counted spans as well as anchors: seven span.mg-nav-locked on a one-capability account, exactly what the template predicts. The selector had counted anchors only. Nothing to build. It sat as a candidate after closing, inflating the backlog by one - found in the 0.13.12 housekeeping pass."
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

# ANSWERED 2026-09-09, and the diagnosis in this filing was WRONG

The sites agent could not read `lazysite/manager/layout.tt` - it is refused to
every route they hold (WebDAV 403, the token's scope deny list; `file-download`
as sysop, "Path is blocked") - and answered the question without reading it, on
the sound ground that **a class cannot render unless the template that rendered
it contains it.** As `ai-ui-tester` on `/manager/`: sixteen nav items, four
carrying `.mg-nav-locked`, and the literal string present in the served HTML.

**So `mg-nav-locked` IS in the deployed template. The deploy worked, and this
filing's premise - that a code-bucket file survived an upgrade - was wrong.**
Closed on that basis. It was the right question to ask and the wrong answer to
have guessed at, which is why it was asked rather than assumed.

## The follow-on reading needs re-measuring, and this is checkable here

Their three-account comparison reads:

| Account | Holds | Nav items | Locked |
| --- | --- | --- | --- |
| `ai-ui-tester` | sysop | 16 | 4 |
| `ui-test-3` | `manage_users` only | 16 | **7** |
| `ui-test-2` | neither | **11** | **0** |

and concludes that nav marking depends on `manage_users`. **The template says
otherwise, and it was read here before replying.** Every gated item in
`starter/lazysite/manager/layout.tt` carries the same three-way shape:

    IF <capability>   -> an ordinary link
    ELSE IF manage_users -> <a class="mg-nav-locked" href="/manager/groups" title="…grant X…">
    ELSE                 -> <span class="mg-nav-locked" title="…a user manager can grant it.">

Seven items use it - seven `<a>` forms and seven `<span>` forms, which is
exactly `ui-test-3`'s seven. **`manage_users` changes the ELEMENT and the
WORDING, not whether the item is marked.** An account holding neither gets seven
`<span class="mg-nav-locked">`, so the expected reading for `ui-test-2` is seven
locked, not zero.

A selector matching `a.mg-nav-locked`, or counting nav items as anchors, would
produce exactly the numbers reported. That is the likeliest cause and it is
theirs to confirm; the alternative - that the spans are genuinely absent on edge
- would be a real defect and worth knowing quickly. Asked in the reply.

The differentiated wording is deliberate and is [[SM807]]: the remedy depends on
who is reading it, so an account that can grant the capability is sent to the
Groups page and an account that cannot is told to find someone who can.

# The follow-on closes too, 2026-09-10: no defect

Re-measured counting spans as well as anchors: **seven `span.mg-nav-locked`** on
an account holding one capability - exactly the seven the template read here
predicted. The selector had counted anchors only. Nav marking works for all three
account shapes, `manage_users` changes the element and the wording as designed
([[SM807]]), and there is nothing to build. Closed.
