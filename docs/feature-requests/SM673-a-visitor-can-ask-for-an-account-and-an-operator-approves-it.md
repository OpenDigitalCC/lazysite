---
title: "SM673: a visitor can ask for an account, and an operator approves it"
subtitle: "Release manager, 2026-08-28: 'how might a user register for an account from a hosted site? this isn't a workflow that I had accounted for previously.'"
brand: plain
standard-margins: true
status: partial
status-note: "PARTIAL (PENDING). THE APPROVAL VERB SHIPS: `account-approve` creates the account with NO password, places it in every group flagged to take registrations, and mints the claim link - one step for what was three, and the operator never sees a password. Registration stays INVITATION-ONLY: nothing public creates an account and SM268's ruling is intact, since this is called BY an operator looking at a submission. THE TRAP IS AVOIDED rather than hit: the pending state is the SUBMISSION the forms pipeline already stores, not a disabled account - cmd_claim_create refuses a disabled account outright. WHICH GROUP THEY LAND IN IS A GROUP FLAG, at the release manager's direction: 'add anonymous user registrations to this group', ticked on the Groups page where the operator can see what that group grants while deciding. It began as a lazysite.conf key and that was worse - a config file is a thing somebody has to be told about. More than one group may carry it and an approved account joins all of them. SETTING IT PASSES THE SAME CEILING as granting the group's capabilities one at a time: it is the strongest conferral in the system, deciding what a person nobody has met holds, and ticking a box must not route around SM195. SM647 and SM682 answered the same question for allowed_groups and writable_by; this is the third. Nothing flagged means an approved account joins nothing, which is the safe default because no shipped group grants only a login. Sabotage-verified six ways across both halves. REMAINING: the operator calls this from the CLI or the API, not from a button on the submission - wiring one needs the form to say which fields are the username and address, or the operator to type them."
---

# BLOCKED ON SM709 - read this before building the public half

**The remaining work here makes a display name attacker-controlled, and that is
the input SM709 is about.** Nothing in SM709 was exploitable while display names
were operator-set; a visitor proposing their own is exactly what changes that.

SM709 is now fixed - `auth_*` is escaped where it enters the render stash, and
the admin bar is escaped at its sink - so this is a dependency to VERIFY rather
than one to wait for. Before the public half of this filing ships, prove it
against a registration whose proposed display name carries `<`, `'` and `"`:
the name must render escaped everywhere it is shown, and the account must still
authorise. `t/integration/77` is the shape of that proof.

The reason this is written here rather than left to a reviewer: the dependency
is invisible from this filing's side. Nothing about "a visitor asks for an
account" suggests a rendering boundary, and the connection was only obvious from
the other end.

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
