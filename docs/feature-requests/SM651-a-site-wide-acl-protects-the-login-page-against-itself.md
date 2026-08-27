---
title: "SM651: a site-wide ACL protects the login page against itself, and signing in is the only way to undo it"
subtitle: "Site agent, 2026-08-25: `acl-set` on `/` succeeds, warns about file movement, and says nothing about the redirect loop it has just created"
brand: plain
standard-margins: true
status: candidate
status-note: "FILED FROM AN INBOX BRIEF (archived at inbox/archive/), reported by the site agent 2026-08-25 on build 0.10.32. `acl-set&path=/` succeeds and warns only that a site-wide rule moves no files. It does not warn about what it has actually done: /login answers 302 to itself, forever - an anonymous visitor is redirected to the login page, the login page is anonymous, it redirects to itself. /assets/lazysite-chrome.css also 302s, so even a reachable login page would render unstyled. WHY THIS IS WORSE THAN AN ORDINARY MISCONFIGURATION: nobody can sign in, and signing in is the only way to get an interactive session to undo it. A site protected this way FROM THE MANAGER UI would take its operator's own access with it. It survived on the test instance only because the rule was applied over a PARTNER TOKEN, which ACLs govern for content but which still reaches acl-remove - so the recovery path exists and is precisely the path a browser user does not have. THE DOCUMENTED SAFE MECHANISM IS UNREACHABLE: auth_default does the same job with a login carve-out, and is not settable over the API, so a token holding manage_config cannot use the safe instrument and can use the unsafe one. FOUR FIXES IN PREFERENCE ORDER, the first of which is the whole fix and the rest consolations. Related: SM188 (session-marker login loop), and the same lockout hazard SM644 must design against."
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
