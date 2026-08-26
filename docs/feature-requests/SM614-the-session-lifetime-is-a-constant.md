---
title: "SM614: sliding session expiry, with a settable idle lifetime as the single source of the number"
subtitle: "Renew on use, expire on inactivity, and make the idle window the one place the number is written down - which retires the constant that is currently duplicated and kept in step by a comment."
brand: plain
standard-margins: true
status: candidate
status-note: "DECIDED BY THE OPERATOR 2026-08-26: SLIDING EXPIRY, plus a settable overall lifetime of no activity, and that setting becomes the one place the number lives - so it resolves the duplication rather than adding a third copy. Original question and findings below. THE PER-REQUEST PATH IS CHEAPER THAN IT LOOKS, which changes the shape of the build: the session registry (sessions.jsonl) is advisory listing metadata and is explicitly NEVER on the per-request path - expiry is checked against the timestamp carried in the SIGNED COOKIE ITSELF. So sliding is a re-issued cookie, not a file write per request, and the cost is a Set-Cookie header rather than contention on a shared file. Renewing only when the cookie is older than some fraction of the window keeps even that off most requests. THE TRAP, AND IT IS THE WHOLE DESIGN: revocation compares the COOKIE'S TIMESTAMP against a not_before epoch - session_revoked() is true when `$ts < $nb->{$user}`, which is how 'sign out everywhere' kills sessions that carry no sid. If sliding advances that same timestamp, a session renewed after a sign-out-everywhere would have $ts >= not_before and SURVIVE THE REVOCATION. A naive implementation therefore breaks the one control an operator has over a stolen session, silently, and in the direction that matters. The cookie must carry TWO times: an IMMUTABLE issue time, which is what not_before is compared against and which sliding must never touch, and a sliding last-seen time, which is what the idle window is measured from. Both are already inside a signed payload, so adding a field is cheap; getting them the wrong way round is not. TWO SMALLER CONSEQUENCES worth deciding rather than discovering. (1) The Active sessions page shows 'issued', and with sliding, issued and last-seen diverge - the column an operator reads to judge a session becomes the less useful of the two, and should probably show both or show last-seen. (2) An idle window with no absolute cap means a session that is USED never dies, so a stolen cookie in active use is immortal until the operator revokes it. Whether to keep an absolute maximum alongside the idle one is a posture decision, not a technical one, and belongs with the operator rather than in this filing. SOURCE COLLAPSE IS PART OF THE WORK, not a follow-up: Auth/Session.pm's SESSION_COOKIE_MAX and Manager/Sessions.pm's $COOKIE_MAX are the same number written twice with a comment asking that they be kept in step. The setting replaces both, read from one place. Doing that first makes the rest a change to one value rather than to two. NOT FOR 0.11.0: a feature, and the freeze holds. ASKED BY THE OPERATOR 2026-08-26 while reading the Sessions page: can the cookie lifetime be extended for one user, or for all? ANSWERED FROM THE SOURCE: no, for anybody. `sub SESSION_COOKIE_MAX { return 86400 }` is a constant in Auth/Session.pm, read by the auth wrapper for the cookie's Max-Age and for its own expiry check, and DUPLICATED as `my $COOKIE_MAX = 86400` in Manager/Sessions.pm - which carries the comment 'Duplicate of the auth wrapper's $COOKIE_MAX (24 hours) - keep in step'. A duplicated constant kept in step by a comment is the shape this project has removed elsewhere, and any change here should collapse it to one source first rather than adding a second place to set it. WHAT MAKING IT SETTABLE WOULD INVOLVE, so the size is known before it is wanted: a config key for the instance default; a per-account override if 'one user' is really wanted, which means the value has to travel with effective_settings and be read at issue time rather than at check time, or a session issued under the old value outlives its own rule; and the manager UI to set it. THE SECURITY POSTURE IS THE REAL DECISION, not the plumbing. A longer cookie widens the window in which a stolen session is usable, and the ONLY surface on which a session can be revoked is the manager UI - which is what SM612 has just finished protecting from being switched off. Anything beyond a modest extension wants sliding expiry (renew on use, so an idle session still ages out) rather than a larger fixed window, and that is a different feature. A SMALLER ANSWER MAY BE THE RIGHT ONE: the complaint behind 'can I extend it' is usually being signed out mid-task, which sliding expiry solves at 24 hours without widening the theft window at all. Worth establishing which is wanted before building either. NOT FOR 0.11.0: a feature, and the freeze holds."
---

# What exists today

| | |
|---|---|
| Value | `86400` (24 hours) |
| Defined | `sub SESSION_COOKIE_MAX { return 86400 }` in `Auth/Session.pm` |
| Duplicated | `my $COOKIE_MAX = 86400` in `Manager/Sessions.pm`, "keep in step" |
| Configurable | no - no key, no per-user setting, no UI |

# The design, as decided

| | |
|---|---|
| Renewal | on use, by re-issuing the signed cookie - not a file write |
| Expiry | after a settable period of NO ACTIVITY |
| The number | one setting, replacing both copies of the constant |
| Immutable | the issue time, because `not_before` is compared against it |

# The trap this must not fall into

```perl
# session_revoked(), today
    && $ts < $nb->{$user};
```

"Sign out everywhere" works by setting `not_before` and killing every cookie
whose timestamp precedes it. Slide **that** timestamp and a renewed session
outlives the sign-out. Two times, not one.

# Two different requests hid behind the original question

**"Stop signing me out while I am working"** - answered by sliding expiry:
renew the cookie on use, so an active session persists and an idle one
still ages out at 24 hours. The window a stolen session is usable does not
grow.

**"I want sessions to last a week"** - a genuine posture change. The
revocation surface is the manager UI, so the longer the window, the more
the ability to revoke matters, and the more a lost laptop costs.

The first is probably what is wanted and is the cheaper and safer build.
