---
title: "SM614: the manager session lifetime is a hard-coded constant, settable for nobody"
subtitle: "SESSION_COOKIE_MAX is 86400 in Auth/Session.pm, duplicated in Manager/Sessions.pm with a comment asking that they be kept in step. There is no config key, no per-user setting and no UI."
brand: plain
standard-margins: true
status: candidate
status-note: "ASKED BY THE OPERATOR 2026-08-26 while reading the Sessions page: can the cookie lifetime be extended for one user, or for all? ANSWERED FROM THE SOURCE: no, for anybody. `sub SESSION_COOKIE_MAX { return 86400 }` is a constant in Auth/Session.pm, read by the auth wrapper for the cookie's Max-Age and for its own expiry check, and DUPLICATED as `my $COOKIE_MAX = 86400` in Manager/Sessions.pm - which carries the comment 'Duplicate of the auth wrapper's $COOKIE_MAX (24 hours) - keep in step'. A duplicated constant kept in step by a comment is the shape this project has removed elsewhere, and any change here should collapse it to one source first rather than adding a second place to set it. WHAT MAKING IT SETTABLE WOULD INVOLVE, so the size is known before it is wanted: a config key for the instance default; a per-account override if 'one user' is really wanted, which means the value has to travel with effective_settings and be read at issue time rather than at check time, or a session issued under the old value outlives its own rule; and the manager UI to set it. THE SECURITY POSTURE IS THE REAL DECISION, not the plumbing. A longer cookie widens the window in which a stolen session is usable, and the ONLY surface on which a session can be revoked is the manager UI - which is what SM612 has just finished protecting from being switched off. Anything beyond a modest extension wants sliding expiry (renew on use, so an idle session still ages out) rather than a larger fixed window, and that is a different feature. A SMALLER ANSWER MAY BE THE RIGHT ONE: the complaint behind 'can I extend it' is usually being signed out mid-task, which sliding expiry solves at 24 hours without widening the theft window at all. Worth establishing which is wanted before building either. NOT FOR 0.11.0: a feature, and the freeze holds."
---

# What exists today

| | |
|---|---|
| Value | `86400` (24 hours) |
| Defined | `sub SESSION_COOKIE_MAX { return 86400 }` in `Auth/Session.pm` |
| Duplicated | `my $COOKIE_MAX = 86400` in `Manager/Sessions.pm`, "keep in step" |
| Configurable | no - no key, no per-user setting, no UI |

# Two different requests hide behind one question

**"Stop signing me out while I am working"** - answered by sliding expiry:
renew the cookie on use, so an active session persists and an idle one
still ages out at 24 hours. The window a stolen session is usable does not
grow.

**"I want sessions to last a week"** - a genuine posture change. The
revocation surface is the manager UI, so the longer the window, the more
the ability to revoke matters, and the more a lost laptop costs.

The first is probably what is wanted and is the cheaper and safer build.
