---
title: "SM605: data-table-drop ignores a query-string confirmation and refuses as though none was sent"
subtitle: "`table` is accepted from the body or the query string; `confirm` is accepted from the body alone - and the refusal is identical either way, so a caller cannot tell a rejected confirmation from one that never arrived."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.11.0 as recommendation (2): the body-only rule stays - a destructive confirmation in a URL is easier to send by accident and ends up in logs and shell history - and a `confirm` arriving in the query string is now refused with the route to use rather than with the wording for a value that did not match. t/unit/manager/114 pins it, and the fixture had to GRANT housekeeping first: the first version of that block measured the capability gate answering ahead of the branch, which is the same mistake as measuring a service gate and calling it a scope refusal. REPORTED BY THE SITE AGENT 2026-08-26, at a cost of two wasted calls, while dropping test tables during the 0.10.34 pass. VERIFIED FROM THE CODE the same day: the dispatch reads `$req->{table} // $params{table}` - body OR query - and `$req->{confirm}` alone. So `?action=data-table-drop&table=x&confirm=x` reaches the action with the table resolved and the confirmation undefined, and is refused for want of a confirmation the caller believes it sent. THE COMMENT BESIDE IT ARGUES AGAINST THE CODE: 'the same shape as data-rebuild, deliberately: table from either, and the CONFIRMATION from the body. Both destructive actions should be called the same way, and SM479 is what happens when two neighbouring arguments take different routes and one is silently ignored.' Two neighbouring arguments take different routes here, and one IS silently ignored - which is the failure SM479 named, arriving inside the fix for it. THE DEFECT IS THE INDISTINGUISHABLE REFUSAL rather than the body-only rule itself. A caller that sends the wrong confirmation and a caller that sends it by a route this action does not read receive the same answer, so the obvious next move - retype the table name more carefully - cannot work and does not say why. TWO WAYS TO FIX IT, and they are not equivalent: (1) ACCEPT `confirm` FROM EITHER, which makes the two arguments consistent and is what SM479's own reasoning points at; the argument against is that a destructive confirmation in a URL is easier to send by accident, and ends up in logs and shell history where a body does not. (2) KEEP IT BODY-ONLY AND SAY SO - detect a query-string `confirm` and refuse with 'the confirmation must be sent in the request body', which preserves the deliberate asymmetry and removes the silence. RECOMMENDATION: (2). The asymmetry was chosen for a reason worth keeping, and what the field actually lost was two calls to an unexplained refusal, not the ability to confirm by URL. NOT A BLOCKER for any release: the action is refusing, which is the safe direction, and an operator using the manager UI never meets it."
---

# What the caller sees

```
POST ?action=data-table-drop&table=perf_a&confirm=perf_a
  -> refused: confirmation does not match
```

The confirmation matches perfectly. It was never read.

# Why the same refusal for both cases is the problem

| Caller sent | What the action saw | Answer |
|---|---|---|
| `confirm` in the body, wrong value | the wrong value | refused |
| `confirm` in the query string, right value | **nothing** | refused, identically |

The first is a caller who should try again more carefully. The second is
a caller who should try again *differently*. One answer cannot serve both,
and the one given points at the wrong fix.
