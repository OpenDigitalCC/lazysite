---
title: "SM596: \"Connect an AI assistant\" is offered on human accounts"
subtitle: "The account sheet titles each account human or AI, then offers the AI connector to both. SM455 opened the panel to every account for a reason that only ever applied to AI accounts."
brand: plain
standard-margins: true
status: shipped
status-note: "REPORTED BY THE OPERATOR 2026-08-25: the panel shows for a human login and should only show for AI accounts. VERIFIED FROM THE CODE: the guard was a literal `if (true)`. SM127 originally gated it on the account holding a remote channel (api/mcp); SM455 replaced that with `true` DELIBERATELY, because the channel comes from group membership set on another page - so an operator setting an AI up saw no picker, and a stale page was indistinguishable from a failed action (the SM445 shape). THE FIX KEEPS BOTH, because the distinction SM455 needed was never the channel: this same sheet already titles an account `ui ? human : AI`, so `ui` is the page's own marker and an AI account carries it as false from creation. Gating on `!ui` shows the picker for an AI account that holds NO channel yet - exactly SM455's case - and stops it on an account the sheet calls human. A remote channel still counts on its own (`!ui || mcp || api`): an account holding api or mcp needs a token whatever else it is, and the WebDAV block points at this panel to get one. THAT POINTER TRAVELS WITH IT - where the panel is hidden the WebDAV line no longer says 'generate one under Connect an AI assistant below', which would otherwise name a panel that is not there; a human account authenticates WebDAV with its own password, which that block already said. Proven by t/unit/users/35, which RUNS the page's JavaScript in node rather than grepping it - the defect was entirely in what the guard evaluated to, and a source match would pass on any string carrying the right words. Sabotage-verified: restoring `if (true)` fails the three human assertions and leaves both SM455 assertions passing, which is what shows the fix did not buy the report at SM455's expense."
---

# What was wrong

The account settings sheet titles every account with what it is:

```
Configuring alice   human · ...
Configuring agent   AI · ...
```

and then offered **Connect an AI assistant** to both, because the guard
was a literal `if (true)`.

# Why it was `true`, and why that is not simply reverted

SM127 gated the panel on the account already holding `api` or `mcp`.
That capability comes from GROUP MEMBERSHIP, granted on the Groups page,
so connecting an AI went: create the account, come here, see no picker,
go to Groups, come back, still see no picker because the sheet is showing
what it loaded before the change, guess that a reload is the answer.

The operator did something correct and saw no effect - which looks
exactly like the thing they did having failed.

# The distinction that was actually needed

Not the channel. The page's own marker:

| Account | `ui` | Sheet title | Panel |
|---|---|---|---|
| a person who signs in | true (also the default) | human | no |
| an AI account, no channel yet | false | AI | **yes** - SM455's case |
| an AI account holding mcp | false | AI | yes |
| a person's account holding api | true | human | yes - it needs a token |

`ui` defaults to true when unset, so an account nobody has classified
reads as human, which is the safe direction: the panel appears when
something says AI, never merely because nothing said otherwise.
