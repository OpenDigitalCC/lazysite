---
id: SM798
title: "SM798: the auth CGI residue - an empty-password oracle and a rate limit that fails open"
subtitle: "Security review, 0.13.8. The wild-facing auth handler came out of the review largely solid, and these are the two low-severity items left over: an existing empty-password account answers a remote login with 403 while every other outcome answers 302, which is an enumeration oracle for exactly the configuration the engine discourages; and check_login_rate is per-IP only and fails open."
brand: plain
standard-margins: true
status: candidate
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

# Why filed rather than built

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
