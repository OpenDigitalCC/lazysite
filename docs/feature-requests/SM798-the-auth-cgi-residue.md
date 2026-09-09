---
id: SM798
title: "SM798: the auth CGI residue - an empty-password oracle and a rate limit that fails open"
subtitle: "Security review, 0.13.8. The wild-facing auth handler came out of the review largely solid, and these are the two low-severity items left over: an existing empty-password account answers a remote login with 403 while every other outcome answers 302, which is an enumeration oracle for exactly the configuration the engine discourages; and check_login_rate is per-IP only and fails open."
brand: plain
standard-margins: true
status: partial
status-note: "HALF BUILT 2026-09-09 on claude/sm798-sm799-the-smaller-two. The rate limiter still fails OPEN - failing closed would refuse every login on a host missing an optional module, which is a worse failure than not enforcing the cap - but it no longer does so in SILENCE: both unrunnable cases log a WARN saying the limiter is NOT IN FORCE, naming which of the two happened, the file, the error, and the Debian package for the missing module. That is SM784's rule applied where it belongs: the answer stays permissive, the log carries what was actually established. WHAT REMAINS is the empty-password enumeration oracle, which is a genuine trade and is the release manager\'s to make - closing it costs the 403 that tells an operator why their passwordless account cannot sign in remotely - and the per-IP-only scope, which would be a per-account limiter and is a design change rather than a fix."
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
