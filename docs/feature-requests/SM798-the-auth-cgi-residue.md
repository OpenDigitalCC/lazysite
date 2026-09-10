---
id: SM798
title: "SM798: the auth CGI residue - an empty-password oracle and a rate limit that fails open"
subtitle: "Security review, 0.13.8. The wild-facing auth handler came out of the review largely solid, and these are the two low-severity items left over: an existing empty-password account answers a remote login with 403 while every other outcome answers 302, which is an enumeration oracle for exactly the configuration the engine discourages; and check_login_rate is per-IP only and fails open."
brand: plain
standard-margins: true
status: partial
status-note: "HALF BUILT 2026-09-09 on claude/sm798-sm799-the-smaller-two. The rate limiter still fails OPEN - failing closed would refuse every login on a host missing an optional module, which is a worse failure than not enforcing the cap - but it no longer does so in SILENCE: both unrunnable cases log a WARN saying the limiter is NOT IN FORCE, naming which of the two happened, the file, the error, and the Debian package for the missing module. That is SM784's rule applied where it belongs: the answer stays permissive, the log carries what was actually established. THE ORACLE IS NOW CLOSED (ruled 2026-09-09, built, verified on main 2026-09-10): the passwordless remote refusal is indistinguishable from an absent user and a wrong password - same 302 ?error=1, and THE SAME SLEEP, because matching only the status would have swapped one oracle for a slower, quieter one. The explanation it cost is not lost - it moved to the log and the audit trail, where an operator can reach it and an unauthenticated caller cannot. WHAT REMAINS: the per-IP-only scope, which would be a per-account limiter and is a design change rather than a fix; and the limiter becoming a switchable extension, now scheduled with the extensions batch under SM222\'s constrained-enablement design."
---

# The two items

**An enumeration oracle for empty-password accounts.** From a non-loopback
address, an absent user and a wrong password both answer `302 ?error=1`, while
an account that exists with an empty password answers `403` through
`reject_no_password()`. So the one response that differs identifies an account
that exists *and* is in the state the engine most discourages. Low: it discloses
existence only for a configuration that should not be in production, and the
403 exists to tell an operator why their passwordless account cannot sign in
remotely - which is a real message, not an accident. The fix is to answer the
same 302 and put the reason in the log, at the cost of that message.

**The login rate limit is per-IP only, and fails open.** It cannot be read as
protection for an account, only for an address: a distributed attempt against
one account is not rate-limited at all, and a limiter that fails open when its
own store cannot be read is a cap that stops capping exactly when something is
wrong. Compare `_calls_in_last_hour` in the connector store, which returns undef
on an unreadable record and refuses the call - the same question, answered the
other way in two places.

# What was built, and what deliberately was not

**The limiter says when it is not in force.** Both unrunnable cases - `DB_File`
absent, and a counter that will not open - returned "under the cap" in complete
silence, so a site with no login rate limiting looked exactly like a site with
it, from every surface including its own health report.

The direction is unchanged and that is the decision: failing closed would
refuse every login on a host missing an optional module, and locking an
operator out of their own site to enforce a rate limit is the worse failure.
What changes is that the WARN now says the limiter is **not in force**, names
which of the two happened, the file, the error, and the package that supplies
the missing module. The consequence, not just the cause.

Logged per attempt rather than once, because these are CGI processes with
nothing to remember between them - and a run of those lines is itself the
signal that the limiter has been inert for a while.

**Not built: a health-check line.** `lazysite-check` is where an operator looks
for this kind of fact, and a line there would beat a log entry nobody reads.
Recorded rather than done, because it widens the change from the auth path into
the health tool.

# Why the rest is filed rather than built

The oracle is a genuine trade: closing it removes the sentence that tells an
operator why sign-in is refused, and the empty-password state is already
loopback-only. That is the release manager's call.

The rate limiter is the more interesting one, because it is the four-states
rule again (SM784): "I could not read the record" is being answered as "you are
under the cap". Whether it should fail closed is a decision about locking
people out of their own site when a file is unreadable, and it belongs with the
survey SM784 asks for rather than as a lone change here.

# What came out solid, and is worth not re-reviewing

Reproduced by the review rather than read: every IP decision reads
`REMOTE_ADDR`, and `X-Forwarded-For` / `X-Real-IP` / `Forwarded` spoofs of
loopback were all refused. Sessions are HMAC-SHA256 with groups re-resolved
rather than trusted from the cookie. Password hashing is salted, iterated and
constant-time. Reset tokens are 192-bit CSPRNG, stored hashed, single-use, 24
hours, with no enumeration. The `next=` redirect guard rejects `//host` and
backslash forms.

# Provenance

`inbox/2026-09-08-auth-cgi-enumeration-and-rate-limit.md`.

## Ruled 2026-09-09 by the release manager

**Close the empty-password enumeration oracle.** A passwordless account refuses
exactly as a wrong password does. This overrules the recommendation in the
register, which weighed the narrowness of the state (loopback-only, and
discouraged) against the operator's diagnosis and came down on keeping the
explaining 403. The ruling is that an unauthenticated caller must not be able to
tell one refusal from the other, whatever it costs the diagnosis - the operator
reaches the log for that.

## BUILT 2026-09-09 on `claude/sm798-the-empty-password-oracle`

The passwordless refusal is now the SAME refusal an absent account and a wrong
password get: `sleep $LOGIN_DELAY`, then `302 ?error=1`.

**The sleep is part of the fix, not decoration.** The other two refusals pause
and this path did not, so matching only the status would have swapped a loud
oracle for a slower, quieter one - the timing would still have told a caller
which accounts exist without passwords.

`reject_no_password()` has no caller left and is gone, and with it the two
chrome strings that only it rendered (`auth.nopw.title`, `auth.nopw.body`) -
a translated string for a page nothing draws is a declaration the code ignores.
`t/unit/lib/41-i18n.t` used `auth.nopw.title` as the fixture for "an EMPTY
override falls back to English"; it now uses `auth.uidisabled.title`, which
still has a caller.

**The operator's message was not deleted, it moved.** `log_event` and
`_audit_auth` record `no-password-remote` exactly as before, so the diagnosis is
in the log and the audit trail - reachable by the operator, not by the caller.
The new test asserts that too, because that recording is the whole of what the
403 was for and losing it quietly would make this a worse change than the oracle.

`t/unit/auth/10` proves the closure by INDISTINGUISHABILITY rather than against
a hand-written expectation - it requires the passwordless response to be
byte-identical to the other two refusals, so a wrong expectation cannot pass
while the oracle stays open. Checked by reopening the oracle and watching it
fail.

STILL OPEN from this filing: the rate limiter's per-IP-only scope, which would
be a per-account limiter and is a design change rather than a fix; and whether
the limiter should be a plugin, which is the one row of this filing still in
`docs/decision-register.md`.

# RULED 2026-09-10: the rate limiter becomes a switchable extension

This overrules the recommendation recorded here, and the release manager's
reasons are better than the objection they answer:

- **No core requirement for the module.** As an extension, `DB_File` is the
  extension's declared dependency (`owns.deps`) rather than something core must
  carry. That inverts the original argument entirely: the dep check was dismissed
  here because `DB_File` is a core Perl module shipped in `debian/control` - but
  the point is to stop it being one.
- **Less in the core.** The same principle as [[SM817]] and [[SM222]] L0: the
  renderer and the auth path keep only what every site needs.
- **Some situations may not want it.** A single-operator instance behind a VPN,
  or a constrained device, may legitimately not want a per-IP counter and its
  store at all. That is a real deployment, and "you may not turn this off" was
  the whole of the objection.

**What survives from the objection** is the failure mode, not the conclusion: a
rate limiter that is off must be *visibly* off. The WARN built in 0.13.10 says
when it is not in force; a disabled extension must say the same thing in the same
words, so that "disabled deliberately" and "broken quietly" never look alike.

# The semantics of OFF, ruled the same day

The release manager settled what disabling means for the three, and it is the
same answer each time - **off stops COLLECTION, it does not remove what was
collected**:

| | What OFF does |
| --- | --- |
| Audit trail | No further entries. Existing entries stay. If it was never on, the data was never collected - which is the point for a constrained instance. |
| Content history | No further logging. **The existing history is not removed.** |
| Rate limiter | No counting, and no counter store. |

That is a materially different design from the one [[SM222]] was heading towards,
and it removes the objection that made the audit switch look dangerous: **a
switch that stops collection is not a switch that erases evidence.** The hole in
the record has named edges - the disable and re-enable are recorded with the
actor - and nothing already written is touched.

It also answers the constrained-resources case directly: an instance that never
turns these on never pays for them, which is not something a "delete on disable"
design could offer.