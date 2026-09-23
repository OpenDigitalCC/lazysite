---
id: SM901
title: "SM901: a read list naming principals that do not exist is accepted with `ok:true`, and the path is then readable by nobody"
subtitle: "From the 0.14.4 W5b re-walk: `{\"read\":[\"agent-ai\",\"edge-testing\"]}` — group names written without the `@` — was accepted without a remark, and a signed-in member of `edge-testing` got Forbidden. With `[\"@agent-ai\",\"@edge-testing\"]` the same reader got the page. The syntax is documented; what is silent is a list that names no account and no group that exists."
brand: plain
standard-margins: true
status: shipped
raised: 2026-09-22
raised-by: sites agent, on edge 0.14.4 (reproduced twice)
area: access-control
status-note: "SHIPPED, P1-P4, on the ruling of 2026-09-23 (yes to the recommendation). Reproduced first against the pre-fix Files.pm on a rig with real accounts: {read: [agent-ai, edge-testing]} came back ok=1 with the list stored. P1: action_acl_set resolves every name in the read and write lists against the store - a bare name against account_names, @name against the new Auth::Settings::group_names - and answers ok:true with `unknown: [...]` plus a warning naming them (the CLI prints warnings; MCP set_permissions and the control API carry the result whole, so P3 needed no new code on either). P2: a NON-EMPTY list that resolves to no known principal is refused, kind unknown-principals (a deliberate 400 in t/lint/139), naming the names and how a group is spelt; nothing is written. An EMPTY list stays no-restriction. ONE CASE THE RULING DID NOT NAME, decided here: a site with NO accounts and NO groups - an unsecured dev site, or a site being provisioned before its first account - checks nothing, because there is nothing to check against and refusing every rule there would make a rule impossible to write before an account exists; three suite rigs that named principals they never created were the measurement, and are now created. P4: t/unit/manager/194 - the measured case refused and unwritten; a real @group accepted; a real login beside a future one accepted with the future one named on the result and in the warnings; a lone unknown group refused; the same on the write list; an empty list accepted; the empty-store case accepted with nothing reported. Five sabotages (the refusal removed, the collection removed, @name read as an account, the empty-store guard removed, the write list unchecked) each failed the test."
---

# What was measured

On edge, 0.14.4, setting a read rule on a section for the W5b re-walk:

| Body | Response | A signed-in member of `edge-testing` |
| --- | --- | --- |
| `{"read":["agent-ai","edge-testing"]}` | `ok:true`, no remark | Forbidden |
| `{"read":["@agent-ai","@edge-testing"]}` | `ok:true` | the page |

No account is called `agent-ai` or `edge-testing`; they are groups. The
`acl-set` note in the manager and the access-control reference both show the
`@team` form, so the spelling is documented. What is not said anywhere is
that the first body was accepted as written: a rule whose read list names
nobody who exists.

# The mechanism, read from the code

`action_acl_set` (`lib/Lazysite/Manager/Files.pm`) normalises each list with
`_to_list`, which keeps every non-empty string, and writes it into the
record. `_acl_allows` (`lib/Lazysite/Auth/Acl.pm`) later reads an entry
beginning `@` as a group and anything else as a login. Neither side consults
the auth store about whether the name exists. A bare group name therefore
matches no reader, silently, and the rule is "owner, and nobody".

The manager UI does not reach this path: SM305 replaced its free-text
principal box with a picker that emits the right spelling. The typed
surfaces do — the control API (`acl-set`), MCP `set_permissions`, and
`lazysite acl`.

# What would close it

| Ref | Change | Where |
| --- | --- | --- |
| P1 | After normalising, resolve each entry: a bare name against the account list, an `@name` against the group list. Return `ok:true` with `unknown: [...]` naming the rest — a login that will exist tomorrow is a legitimate thing to write today, and refusing it would break provisioning scripts that set rules before accounts. | `action_acl_set` |
| P2 | Refuse, naming them, when a non-empty list resolves to **no** known principal: that rule reads to nobody and can only be a mistake. Same for `write`. | `action_acl_set` |
| P3 | The CLI prints the `unknown` list on its own line; MCP's `set_permissions` carries it in the result. | `tools/lazysite-acl.pl`, MCP |
| P4 | Tests: a bare group name in a read list is reported unknown; a list of only unknown names is refused; a list mixing a known login with a future one is accepted and names the future one. | `t/unit/…` |

# What is NOT claimed

- That the engine granted anything it should not have. The failure is the
  opposite: a rule that reads to nobody, and no word about it.
- Where the agent's rule came from — the report says the syntax was theirs.
  Two reproductions, both on edge; the mechanism above is from the source.

# Related

[[SM077]] (the `@group` form), [[SM305]] (the manager's picker — why the UI
cannot make this mistake), [[SM479]] (a list sent in the wrong place was
accepted with `ok:1` — the same shape, one layer out), [[SM898]] (the walk
this was found on).
