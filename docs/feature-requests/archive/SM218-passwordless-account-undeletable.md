---
title: "SM218 - A passwordless (token-only) account could not be deleted"
subtitle: "cmd_remove tested the RETURN VALUE of delete rather than existence, so an account whose stored hash is the empty string reported 'not found' and stayed undeletable"
brand: plain
status: shipped
status-note: "Field-reported 2026-07-23, root-caused the same day, FIXED and shipped in 0.9.14 (also in 0.10.0 stable / 0.10.1). Numbered retrospectively 2026-07-27 - the fix predates its SM number, so this doc is the record, not an open item."
---

# SM218 - passwordless account undeletable

## The bug

A sub-user created without a password (a token-only / machine account) could not
be removed. `lazysite-users.pl remove <user>` reported **"User '<user>' not
found"** and exited, leaving the account in place - while `user-add` on the same
name said "already exists" and enable/disable worked normally. That
contradiction is what made it visible in the audit.

## Root cause

`cmd_remove` gated on the return value of `delete`:

```perl
die "User '$user' not found\n" unless delete $users{$user};
```

`delete` returns the deleted **value** - the password hash - not a truth about
existence. `cmd_account_create` stores a passwordless account with an EMPTY hash
(`$users{$user} = length($pass) ? hash_password($pass) : ''`), so `delete`
returned `''`, which is false, so the `die` fired *after* the entry had already
been removed from the in-memory hash but *before* `write_users` - the account
survived on disk, permanently undeletable through the tool.

The other verbs were unaffected because they test `exists` or read the settings
store rather than the hash value.

## The fix

Separate the existence test from the deletion:

```perl
die "User '$user' not found\n" unless exists $users{$user};
delete $users{$user};
```

One line, no behaviour change for password-holding accounts.

## Tests

`t/unit/users/01-user-management.t`: add a passwordless account, remove it,
assert the removal succeeds, that no spurious "not found" is emitted, and that
the account is gone from the list.

## Lesson

`delete`-as-existence-test is a Perl idiom trap that only bites on falsy values -
here an empty-string hash, which is exactly the shape of the newest account type
(machine credentials). It is the same class of latent defect as testing a hash
value that may legitimately be `0` or `''`. Worth a grep when adding any new
"empty value is meaningful" field.
