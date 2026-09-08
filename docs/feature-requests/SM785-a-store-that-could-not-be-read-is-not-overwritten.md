---
id: SM785
title: "SM785: a settings store that could not be read is not overwritten"
subtitle: "Found while building SM778, not by review: every writer of the account settings store is a read-modify-write, and read_settings answers {} for a store it could not open - so one ordinary API call replaced every account's display name, comment, email, expiry, token TTL and start page with the single entry it was stamping."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-08 on claude/sm778-the-display-name-wherever-a-login-is-handed-back. write_settings refuses when the read that produced its argument failed, and says so in the log and in the exception; an ABSENT store still reads as readable, so a first write lands. t/unit/auth/23 proves the store survives byte-for-byte, and fails when the guard is removed."
---

# What happened

A test written for SM778 made the account settings store unreadable and asked
for a display name. It came back **empty, with `readable: 1`** - the store was
readable and genuinely held nothing.

It held nothing because the failing read had already been followed by a write.

Every writer of `lazysite/auth/user-settings.json` is a read-modify-write:
read the whole hash, change one account's entry, write the whole hash back.
`read_settings` answers `{}` for a store it could not open, so the modify step
built a hash containing **one** account and the write step made that true.

The call that did it was not an administrative one. Token verification stamps
"last used" through `touch_credential`, which is a read-modify-write of this
store, so **an ordinary API request** against a site whose settings file had
lost its read permission emptied the file. And a rename needs no permission on
the target file, only on its directory, so the unreadable file was not even an
obstacle to being replaced.

What is lost: every account's display name, comment, email address, expiry,
token TTL and start page. The accounts themselves survive - they live in
`auth/users` - so the site keeps working and nobody is locked out. The damage
is silent, and the next `write_settings` from a healthy read makes it
permanent.

# The rule

**You may not overwrite a store you could not read.**

`write_settings` now refuses when the read that produced its argument failed,
naming the file, what the write would have done, and the thing to fix. The
refusal is logged as a WARN, so an operator learns the permissions are wrong
rather than discovering the loss later.

Refusing is safe in both directions, and that is the part worth stating: a
store that is simply **absent** reads as readable, because ENOENT is an
ordinary state and not a failure to establish anything. A first write still
lands, and a fresh site is unaffected.

# Why the reader could not fix this alone

SM766 and SM770 made the rule for READERS - a store reader never turns an
unopenable file into an empty answer in silence - and both are held by
t/lint/121. This is the writer half, and no reader-side change reaches it:
`read_settings` returns a hash, and a hash has nowhere to put "I could not
tell". Every caller that receives `{}` has to decide what it means, and a
writer that decides "empty" is a writer that destroys the store.

So the reader records whether it could read (`settings_readable`, added for
SM778's `display_names_readable`) and the writer asks.

This is the release manager's four-states rule (SM784) at its most expensive.
*No answer* was rendered as *false* - "there is nothing here" - and then a
writer made the wrong answer true.

# What is not done

Only the account settings store. `write_group_settings`, the ACL store and the
connector store are the same read-modify-write shape and have not been
surveyed - which is a candidate, and belongs with SM784's survey rather than
in this release.
