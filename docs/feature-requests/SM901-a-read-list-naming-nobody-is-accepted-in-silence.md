---
id: SM901
title: "SM901: a read list naming principals that do not exist is accepted with `ok:true`, and the path is then readable by nobody"
subtitle: "From the 0.14.4 W5b re-walk: `{\"read\":[\"agent-ai\",\"edge-testing\"]}` — group names written without the `@` — was accepted without a remark, and a signed-in member of `edge-testing` got Forbidden. With `[\"@agent-ai\",\"@edge-testing\"]` the same reader got the page. The syntax is documented; what is silent is a list that names no account and no group that exists."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-22
raised-by: sites agent, on edge 0.14.4 (reproduced twice)
area: access-control
status-note: "FILED, not built. VERIFIED AGAINST THE SOURCE: action_acl_set (Lazysite::Manager::Files) takes the read and write lists through _to_list, which only drops empty strings, and writes them into the record; nothing on that path asks whether a bare name is a login the auth store knows or whether an @name is a group. _acl_allows then reads a bare name as a login and an @name as a group (SM077), so a bare group name matches no reader and the rule is owner-only-plus-nobody. The manager UI does not reach this: SM305 gave it a picker that emits the right spelling. The control API, MCP set_permissions and `lazysite acl` take typed lists and are where this happens. RECOMMENDATION, for the release manager: answer `ok:true` still - a login that will exist tomorrow is a legitimate thing to write today - but carry `unknown: [...]` in the response naming every principal that is neither a known login nor a known group, and REFUSE (with the names) when a non-empty list resolves to no known principal at all, because that rule reads to nobody and the only thing it can be is a mistake. One test per branch; the same check on `write`."
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
