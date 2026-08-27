---
title: "SM641: a failed login writes the attacker's chosen username into the audit trail as if it were an actor"
subtitle: "Operator, 2026-08-27: 'it must only log usernames that are actual users, not allow anyone to invent a new username in to audit'"
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED. Raised by the operator 2026-08-27 and built the same day. The rule they set is the rule implemented: the actor is `system` when the name is not an account, and the attempted name is kept in the detail field, sanitised. Implemented at `_audit_auth` - the single writer for every auth event in lazysite-auth.pl - rather than at the thirteen call sites, because a rule at the call sites is one the fourteenth caller forgets. A real account's failed login is unchanged and still names that account. `system` passes through untouched, or the check would have rewritten this file's own pseudo-actor into a note about itself. THE READER HALF WAS ALSO BUILT and matters more than it looks: the Audit page linked every actor unconditionally, so the entries ALREADY ON DISK on every affected site keep offering links to accounts that never existed, and no writer-side change reaches them. The API now returns the intersection of the actors in its answer with the real accounts - disclosing nothing, since every name in it was already in the response - and the page links only those. One shared reader, Lazysite::Auth::Settings::account_names, answers "is this an account" for both halves. Eight sabotages, all fail. NOTE ON THE SANITISER: the login door already strips to [a-zA-Z0-9_.-] and caps at 64 before the writer sees anything, so through that door the writer's own reduction has nothing left to do; it is kept because depending on every caller having done it first is the same mistake in a different place."
---

# What the actor column means, and what it holds

| | |
|---|---|
| What the column is for | WHO did this |
| What a login attempt proves | nothing - it has not authenticated yet |
| What is written today | whatever the form supplied |
| How the Audit page renders it | `<a href="/manager/users?user=...">` |

The audit trail's first field after the timestamp is the actor. Every other
surface fills it from an identity that has already been established: the
manager API from `$auth_user`, MCP from the bearer's resolved user, the users
tool from the account it is acting as. `lazysite-oauth.pl` fills it with an
empty string on the paths where nobody has authenticated yet, which is the
correct instinct.

The auth surface does not. `_verify_credential` audits a failure before it
knows whether the account exists, and on the branch that runs *because* it
does not exist:

    unless ( defined $expected ) {
        log_event( 'WARN', $username, 'login failed', ip => $ip );
        _audit_auth( $username, 'login', 'fail', 'invalid-credentials' );

`$username` there is form input that has just been looked up and not found.
It is written to the trail as an actor anyway.

# Why this is worth fixing rather than tolerating

It is not a spoofing hole - the entry says `fail`, and no session is created.
The cost is to the trail's usefulness and to the operator reading it:

- **The actor column stops meaning what it says.** A reader cannot tell a real
  account's failed attempt from a name that never existed without checking the
  Users page for each one.
- **The filter dropdown fills with noise.** `action=audit` builds its facet
  list from the log's own values, so every invented name becomes a permanent
  option in the operator's "(all users)" filter.
- **The page offers a link to nothing.** `auditUserLink()` links every actor
  unconditionally. A credential-stuffing run leaves a trail of clickable
  usernames that resolve to no account - and `system`, which the file already
  writes for `ip-auto-blocked`, is linked the same way today.
- **The trail is append-only and shipped to syslog.** `forward_line()` sends
  each entry onward, so an invented name is not confined to one file.

# The shape of the fix

**One chokepoint, not thirteen call sites.** `_audit_auth` is the single
writer for every auth event in the file, and it is the only place in the
product that ever holds a name that has not been proved. The check belongs
there, so a future caller cannot reintroduce this by forgetting.

- If the name is a real account, it is the actor, unchanged.
- If it is not, the actor is `system` and the detail gains
  `attempted username: <sanitised>`.
- `system` itself passes through untouched - it is already this file's
  pseudo-actor and must not be rewritten into a note about itself.

**Sanitised means bounded, not merely escaped.** The attempted name is
reduced to the characters an account name can contain, with anything else
replaced one-for-one so the length of what was tried survives, and truncated.
The audit writer already strips pipes and newlines, which protects the record
FORMAT; this protects what an operator reads.

**The reader stops linking what is not an account.** `action_audit` already
knows which names are real. Returning the intersection of the facet list with
the account list costs nothing and discloses nothing - those names are in the
response already - and lets the page link an actor only when there is
something to link to. That also repairs the entries already on disk, which no
writer-side change can reach.

# What this does not do

It does not remove the attempted name from the record. The operator asked for
it to be kept, and it is the useful part: a stuffing run against `admin`,
`root` and `test` is worth seeing. It moves from a field that asserts identity
to a field that reports what was claimed.

It does not touch `log_event`, which writes the application log rather than
the audit trail and has no actor column and no click-through.
