---
id: SM865
title: "SM865: every fresh install came with a passwordless account called `manager` in an admin group, because the installer copied a file written as a demo"
subtitle: "`install.sh` seeded `lazysite/auth/users` and `auth/groups` from their `.example` files. `users.example` shipped exactly one entry - `manager:` - and `groups.example` put it in `members` and `lazysite-admins`. The trailing colon means no password, and that is refused off localhost, so it was not reachable remotely. It is still the shared role account SM659 removed from `setup-sysop` as a hazard, seeded by the other half of the same codebase on every new site."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-09-12 for 0.13.15, ruled by the release manager - 'the installer must stop seeding manager'. The seeding block is gone (it was already fresh-only and guarded, so upgrades were never touched, and an existing `manager` account is deliberately left alone). `print_next_steps` now opens with how to create the first account, because 'no accounts' is coherent but silent. Both `.example` files are rewritten as format documentation with placeholder names and an explicit note that the installer does not copy them. t/tools/03 asserts no store is seeded, that neither file names `manager`, and that the summary names setup-sysop; it failed on all four before the change."
raised: 2026-09-12
raised-by: release manager (two fresh installs, each with a `manager` account)
area: packaging
---

# How it was found, and my own error first

The release manager asked why `setup-sysop --user sjm` had also produced a
`manager` account. I probed `setup-sysop` in a hand-made docroot, found it
creates exactly one account, and answered that **nothing else had been
created**.

That was wrong, and wrong in a specific way worth recording: the report was
about a *fresh install* and I measured a *command*. The install path was the only
place the answer could be and my probe never ran it. The release manager pushed
back - "it isn't a mistake, there are 2 users, two fresh installs, both have a
manager account from the start. what evidence do you need?" - and then supplied
the install transcript, which names the cause in its own output:

```
seeded:    lazysite/auth/users (from users.example)
seeded:    lazysite/auth/groups (from groups.example)
```

**When a report names an environment, reproduce in that environment.** I had the
installer in front of me the whole time.

# What was seeded

`starter/lazysite/auth/users.example`, in full, was a comment block and one
line:

```
manager:
```

and `groups.example`:

```
members: manager
lazysite-admins: manager
```

`install.pl` copied both on a fresh install. So every new site had an account
named `manager`, with no password, in `lazysite-admins`.

# What it did and did not expose

**Not reachable remotely, and I checked rather than trusting the comment.** An
empty password field means no password, and `lazysite-auth.pl:373-396` refuses a
no-password login unless `REMOTE_ADDR` is `127.0.0.1` or `::1`. SM798 further
made that refusal answer exactly as a wrong password does - same redirect, same
`$LOGIN_DELAY` - so it cannot even be used to discover that such an account
exists. Remotely the account was inert.

**It was still the wrong default**, for three reasons that stand independently of
reachability:

1. **The codebase disagreed with itself.** SM659 removed exactly this account
   from `setup-sysop`, and said why: *"a shared-secret ROLE account, as the
   DEFAULT path ... Role accounts are how people end up sharing a password, and
   the audit trail then says `manager` did everything."* The installer then
   created one anyway, into an admin group, on every fresh site. The installer's
   half was winning everywhere it mattered.
2. **A file written as a sample had become a default.** `users.example` opened
   with *"demo users - copy to 'users' to enable auth"* - an instruction to a
   human, describing a manual step. Nobody performed it; the installer did, every
   time. A sample that is copied automatically is not a sample.
3. **Nothing said it had happened.** The summary line read `seeded:
   lazysite/auth/users (from users.example)`. It did not say that a passwordless
   account named `manager` now existed in an admin group. The release manager
   found it by reading the user list.

# The fix, as ruled

**"The installer must stop seeding manager."**

- The seeding block is removed. Nothing replaces it: SM659 already settled that a
  site with no accounts is a coherent state rather than a half-built one, because
  deployment and first user are separate steps.
- `print_next_steps` now opens with the account step and the exact
  `setup-sysop --user <name>` command, noting that there is no default login.
  "No accounts" is correct but silent, and an operator who is not told will go
  looking for a default - which is how the seeded account came to be used.
- Both `.example` files are rewritten as **format documentation**: placeholder
  names, no privileged group, and a line saying the installer does not copy them
  and that `setup-sysop` is the route. A sysop writing the store by hand still
  has the format; nobody is handed an admin account to copy.

**An existing `manager` account is left exactly where it is.** The block was
already fresh-only and guarded on `!-f`, so upgrades never touched it, and that
stays true: an operator may be signing in with that account, and an installer
that deletes a login nobody asked it to delete is worse than the account it
removes. Naming it belongs to `lazysite-check`, which is where an operator looks
for facts about their site - recorded here as not built.

# Held by

`t/tools/03-install-pl.t`, "a fresh install creates no account at all": no
`auth/users` or `auth/groups` is written, neither file names `manager` if one
ever is, the summary names `setup-sysop`, and `users.example` no longer offers a
`manager` account to copy. It failed on all four assertions before the change,
with the seeded contents in the diagnostic.

# Related

SM659 (the argument this aligns the installer with), [[SM864]] (the *other*
install path, which calls a verb SM659 deleted and so creates nothing while
saying it did - the same disagreement seen from the opposite side), SM798 (why
the no-password refusal is indistinguishable from a wrong password),
[[feedback_reproduce_before_blaming_the_host]].
