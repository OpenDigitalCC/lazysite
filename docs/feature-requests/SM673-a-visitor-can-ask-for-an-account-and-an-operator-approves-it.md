---
title: "SM673: a visitor can ask for an account, and an operator approves it"
subtitle: "Release manager, 2026-08-28: 'how might a user register for an account from a hosted site? this isn't a workflow that I had accounted for previously.'"
brand: plain
standard-margins: true
status: candidate
---

# What exists today, and why it is invitation-only

Registration is by invitation. An operator creates the account (`add`,
`account-create`, `partner-create` or `setup-sysop`), mints a single-use claim
link with `claim-create` (24h), and the person sets their own credential at the
public `/claim` page. The operator never sees the password: the claim token IS
the authentication, and `lazysite-auth.pl` shells to the tested `claim-redeem`,
returning one generic error on any failure.

There is no public action that CREATES an account. Nothing in the auth CGI
answers `register`, `signup` or `join`.

That is a decision, not a gap. SM268 ruled that minting credentials is a
human-at-a-browser operation, which is why `manage_users` and
`create_sub_users` are manager-UI-only. Self-registration contradicts that
ruling directly - so this filing exists to take the decision explicitly rather
than to route around it.

# The shape chosen

**A visitor asks; an operator approves; the engine issues the claim link.**

The operator keeps the decision. What they stop doing is transcribing a name
and an address from an email into a CLI, which is where the current flow
actually costs something.

# Build it ON the forms pipeline, not beside it

This is the load-bearing recommendation, and the reason is anti-abuse rather
than tidiness.

A registration form is a public, unauthenticated write endpoint on the open
internet - the most attacked shape a site has. The forms stack already carries
every defence such an endpoint needs, each built for a reason and tested:

- the honeypot field (`check_honeypot`)
- the render timestamp signed with an HMAC, refusing a replayed or forged pair,
  with the too-fast floor that catches automation (SM501 made its window
  per-form)
- the per-address rate limit, per form (SM401)
- quarantine scoring, spam keywords and a URL threshold (SM216)
- delivery through an operator-vetted handler, never an address the caller names

A registration endpoint built beside that pipeline inherits none of it, and
every item above would have to be rebuilt before it could face the public. Built
as a form handler, it inherits all of it on the day it ships.

# The sequence, and the trap in the middle

1. A public page carries a native form bound to a `register` handler. The
   visitor gives the fields the operator needs - at minimum a desired username
   and an email.
2. The handler stores the submission like any other, and the existing operator
   notification fires: a form arrived, naming the form and the time and never
   the content.
3. The operator reviews it on the Submissions page and approves.
4. Approval creates the account and mints the claim link, which is sent to the
   address on the submission.
5. The visitor sets their own credential at `/claim`. The operator never sees
   it, exactly as today.

**THE TRAP.** The obvious implementation of step 3 - create the account
DISABLED as a pending state, then enable it on approval - fails at step 4:
`cmd_claim_create` refuses a disabled account outright (`Account '$user' is
disabled`, tools/lazysite-users.pl:2211). Approval must ENABLE first and mint
second, or the pending state must live somewhere other than the disabled flag.
Recorded here because it is the kind of thing found halfway through building.

# What must be decided before any code

**Which group does an approved account land in?** This is the security crux and
it is not a detail. Whatever group it is, its capabilities are what an approved
stranger holds. The seeded roles all grant something: `content-editors` writes
pages, `analysts` reads the audit trail. There is no shipped "grants nothing"
group to land somebody in, and `reset-groups` would not create one.

So this needs either a new seeded group that grants nothing but a login, or a
per-site setting naming the group, defaulting to none - in which case an
approved account can sign in and see exactly what an anonymous visitor sees
until the operator adds it to something.

**Is a username the visitor's to choose?** A desired username that already
exists cannot be silently reassigned, and telling the visitor it is taken is an
account-existence oracle. Allocating the name at APPROVAL, from the email,
avoids both.

# Related

[[SM268]] (minting credentials is a human-at-a-browser operation - the ruling
this asks to qualify), SM072 (the public claim redemption this reuses),
[[SM501]] / SM401 / SM216 (the anti-abuse the forms pipeline already carries),
[[SM674]] (open self-registration, if this is ever to be unattended).

# Not started
