---
title: "SM651: a site-wide ACL protects the login page against itself, and signing in is the only way to undo it"
subtitle: "Site agent, 2026-08-25: `acl-set` on `/` succeeds, warns about file movement, and says nothing about the redirect loop it has just created"
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED. is_auth_surface() is consulted in _acl_refused before the ACL store, so the login page, logout, the auth CGI and the engine chrome are reachable under a rule at any depth. NOT A NEW PREDICATE: is_auth_surface() already existed, already followed auth_redirect and already covered logout - it has been the cache-protection predicate since SM071 - and a second one would have been two answers to one question, which is the defect SM654 filed against a hand-kept copy. The engine's own chrome is added, because a login page that renders unstyled is not a usable way in. FOUR SABOTAGES, ALL FAIL, and the one that matters is 'disable the ACL entirely' failing 3 assertions - the test catches a carve-out that is too WIDE as well as one that is too narrow. It also proves the carve-out follows auth_redirect rather than the string /login, so a site that renamed its login page is not left in the loop this closes."
---

# The loop

    acl-set&path=/   {"read":["manager","claude-code"]}
    -> {"ok":true, "warnings":["a site-wide rule is enforced by the engine and
        does not move any files ..."]}

    GET /login -> 302 /login?next=%2Flogin
               -> 302 /login?next=%2Flogin
               -> 302 ... still 302

The login page is protected against itself. The stylesheet that would render it
is protected too.

The call warned about the thing that did not matter and was silent about the
thing that did.

# The asymmetry that makes it dangerous

| | |
|---|---|
| Who can create this state | anyone who can call `acl-set`, including from the manager UI |
| Who can undo it | only a caller who already has a session, or a token |
| What a browser user has afterwards | neither |

An operator doing this from the manager UI locks themselves out of the surface
they would use to fix it. The test instance recovered only because the rule had
been set over a partner token, and a token still reaches `acl-remove` - a
recovery route that exists for the agent and not for the human.

That is the shape of every serious lockout: the instrument that creates the
state is more widely available than the instrument that reverses it.

# The safe mechanism exists and cannot be reached

`auth_default` does this job properly, with a login carve-out already built in.
It is not settable over the API. So a caller holding `manage_config` can reach
the unsafe instrument and not the safe one, and will reasonably conclude that
`acl-set` on `/` is how site-wide protection is done - because on the evidence
available to them, it is.

# Fixes, in preference order

1. **Give the site-wide ACL the same login carve-out `auth_default` has.** The
   login page, the auth CGI and the chrome stylesheet are exempt from a rule
   whose path is `/`. This is the whole fix; everything below is a consolation.
2. **Refuse the rule instead**, if the carve-out is genuinely hard. A rule at
   `/` that makes the login page unreachable is never what the caller wanted,
   and a refusal naming the reason costs one check.
3. **Make `auth_default` settable over the API** for a caller holding
   `manage_config`, so the safe mechanism is reachable at all.
4. **Failing all three, warn on the way out.** The call already returns a
   warnings array. A rule that will make the login page unreachable is worth a
   sentence in it - though a warning after the fact is the weakest of the four,
   because by then the operator may already be locked out.

# What this shares with SM644

SM644 proposes resetting groups and capabilities to the shipped defaults, and
this filing is the argument for the constraint written into it: an operation
that can leave nobody able to reach the manager must refuse rather than warn.
Here the operation is `acl-set /`; there it is a reset. The failure is the
same, and so is the remedy.
