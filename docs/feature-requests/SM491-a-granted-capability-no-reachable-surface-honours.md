---
title: "SM491: a granted capability that no surface the grant can reach will honour"
subtitle: "analytics is true, mcp is false, and analytics exists only as an MCP tool. The operator sees the grant applied; the agent sees the capability held; neither can use it, and nothing says so"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-08-23, AND THE PREMISE WAS HALF WRONG - recorded because the correction matters more than the fix. The report said there was no control-API route to analytics and confirmed it with ?action=analytics returning Unrecognised. THE ROUTE EXISTS: it is named analyse_visitors, has been in Actions.pm gated on analytics since before 0.10.22, and the dispatch comment says in as many words that an API-channel agent gets analytics too. The agent guessed the action name from the capability name, got a refusal that named nothing, and reasonably concluded the surface was absent. So the real gap is narrower and sharper than filed: whoami could not say WHICH surface of their grant reached the capability, and the refusal for a wrong action name did not suggest the right one. THE FIX: whoami carries reachable, derived from Capabilities.pm unlocks against the grant's own api/mcp flags - for the reporter's grant it reads analytics: via [api], requires [mcp]. Derived, not declared, so a capability that gains or loses a surface changes the answer without anybody remembering to. NOT DONE HERE: the unhelpful refusal on a wrong action name is SM350 actions-list territory, noted and not taken. ORIGINAL NOTE FOLLOWS. FROM THE FIELD 2026-08-22 on 0.10.22, filed 2026-08-23. An operator granted analytics so an agent could check a site's access log for broken legacy URLs. whoami reported analytics:true. whoami reported mcp:false. analytics is documented - in the .well-known/ai-partner block - as 'read-only visitor-log analysis via the analyse_visitors MCP tool', and there is no control-API action of that name, confirmed. THAT IS A LEGITIMATE DESIGN. The defect is the COMBINATION: an account holding a capability whose only door is shut on a different switch, with nothing saying so from either end. The operator did the right thing and it silently did nothing. TWO FIXES, EITHER CLOSES IT, THE FIRST IS CHEAPER: say it in whoami - where a capability is only reachable on a surface the grant does not have, report 'granted, requires mcp' or a capability_notes block rather than a bare true, because an agent reads whoami before deciding what it can do and today it is told something not operationally true; or warn at grant time in the manager UI, since turning on analytics for an account with MCP off is almost always a mistake. A control-API analyse_visitors would also resolve it and is a much bigger ask this filing does not make. SIZE: S for the whoami note, S for the grant-time warning. The reporter verified rather than assumed: every claim in the table was re-checked on the live build."
---

# What happened

```datatable
columns: Check | Result
widths: 7cm | X
bold: 1
tone: medium
---
`whoami` -> `capabilities.analytics` | **true**
`whoami` -> `capabilities.mcp` | **false**
Control API `?action=analytics` | `Unrecognised action name`
MCP `analyse_visitors` | unreachable -- MCP is off for this grant
```

`analytics` lives only on MCP, by design and by documentation. The defect is
not that; it is that an account can hold it with MCP off and **nothing tells
anyone**. The operator sees the grant applied. The agent sees the capability
held. Neither can use it.

# The fix

**Say it in `whoami`.** A capability reachable only on a surface the grant
lacks is reported as `"granted, requires mcp"`, or in a `capability_notes`
block naming the dependency -- not as a bare `true`. An agent reads `whoami`
before deciding what it can do, and today it is told something that is not
operationally true.

A grant-time warning in the manager UI is the second half, and cheap.
