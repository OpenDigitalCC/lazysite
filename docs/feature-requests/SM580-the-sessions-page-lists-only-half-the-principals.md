---
title: "SM580: the sessions page lists only cookie principals, so an agent acting now is invisible"
subtitle: "An operator read an MCP write in the audit trail, checked who was signed in, and did not find the actor. Both facts were correct: sessions.jsonl is written only by the cookie login path, so no token or OAuth partner can ever appear there."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.33 as the filing's minimum - name what the page lists and point at where the others are - PLUS the one fact that makes the other card answer the operator's actual question. WHAT WAS ALREADY THERE: the page carries two cards, Active sessions and Active keys, so the machine principals were not missing from the page. What was missing was any statement that the first card lists BROWSER sign-ins only - it said 'Everyone signed in right now' - so an operator arriving from an audit line had no way to know the actor could not be there. It now says so, and names Active keys. THE SECOND HALF IS WHAT MAKES IT USABLE: the keys card said 'in use', which is a historical fact - the key has been used at least once since issue - and showed WHEN only for an EXPIRED token. The operator's question is who is acting NOW, and a key answering 'yes, at some point' cannot be attached to an audit line. A live key now shows its last-used time, from cred_used_at, which keys-list already returned and the page already fetched. NO NEW DATA PATH was needed, which is why this stayed small enough for the cut. Proven by t/unit/manager/120, which runs renderKeys in node - sabotage-verified. RAISED BY THE OPERATOR 2026-08-25 from a live audit line (claude.ai | mcp | create | /sites/xisl/.well-known/security.txt) whose actor was absent from the active-sessions list. VERIFIED FROM CODE: Sessions::action_sessions_list reads lazysite/auth/sessions.jsonl, and that file is written ONLY by lazysite-auth.pl - the cookie login path. lazysite-mcp.pl never writes it (it audits a 'connect' line instead), so a bearer or OAuth partner is absent by construction and absence is not evidence of anything. The write itself was accounted for: it was the site agent, whose MCP identity on that connector IS 'claude.ai', doing work the operator had asked for. THE DEFECT IS THE ANSWER THE PAGE GIVES: it is titled for who is signed in and read as who is acting, and on an instance whose partners are agents, most of the acting principals are the ones it cannot show. PROPOSED: list token and OAuth principals beside cookie sessions - the data exists (the credential store has last-used, the audit has a connect line per bearer verification) - or, at minimum, name what the page lists and point to where the others are. Same shape as SM572 and list_briefs: turn 'remember which surface your partners use' into 'ask'. PLANNED for 0.10.33."
---

# What was verified

| Claim | Established by |
|---|---|
| `sessions-list` reads `lazysite/auth/sessions.jsonl` | code |
| Only `lazysite-auth.pl` writes that file | code |
| The MCP CGI writes no session record | code |
| MCP audits a `connect` line per bearer verification | code |
| `claude.ai` is the site agent's OAuth identity on that connector, not a second actor | the agent, confirming, with its groups and auth method |

# Why it matters

The operator did exactly the right thing - saw a write, asked who did
it - and the page built to answer that question could not. An
instance whose headline partners are agents cannot have a "who is here"
view that structurally excludes agents.
