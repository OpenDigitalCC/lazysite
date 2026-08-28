---
title: "SM674: open self-registration, with no operator in the loop"
subtitle: "Recorded 2026-08-28 alongside SM673, for future consideration - the shape SM673 stops short of, and what it would additionally cost"
brand: plain
standard-margins: true
status: candidate
---

# The difference from SM673

SM673 keeps a human in the loop: a visitor asks, an operator approves, the
engine issues the claim. This is the same flow with the operator removed - a
visitor completes registration unattended and can sign in minutes later.

Everything SM673 needs, this needs too. What follows is what it needs ON TOP,
and the list is the argument for doing SM673 first.

# What it additionally requires

Verified email
: An unattended flow has no human to notice that an address is wrong, hostile or
  somebody else's. The account must not become usable until the holder of the
  address has proved it. The engine has no verified-email concept today - `set
  USER email` records a string nobody has checked. The claim link is already a
  proof-of-address mechanism; this would make it the gate rather than a
  convenience.

A default group that is safe for a stranger
: SM673 raises this and can defer it to the operator's judgement at approval
  time. Here there is no approval, so whatever the default group grants is what
  anybody on the internet holds after a round trip through an inbox. It has to
  be a decision made once, correctly, in advance.

A name-allocation rule that leaks nothing
: SM673 can allocate at approval. Unattended, the visitor learns immediately
  whether a name was accepted - which is an account-existence oracle unless
  names are allocated rather than chosen.

Abuse limits beyond the form's
: The forms pipeline rate-limits SUBMISSIONS per address. Unattended
  registration also needs a ceiling on ACCOUNTS - per address, per period, and
  in total - or a single afternoon produces a store with ten thousand entries
  and a Users page nobody can read. Nothing in the engine counts accounts
  against a limit today.

A way to undo it in bulk
: Approving one account at a time is self-limiting. Unattended creation is not,
  so the operator needs to remove a run of accounts created in a window, which
  is a verb that does not exist and touches personal data (SM232 territory).

# Why it is recorded rather than proposed

Every item above is a decision with a wrong answer that is expensive and quiet:
a default group that grants too much, an unverified address, an unbounded store.
SM673 gets a site self-service registration with one human step, and that step
is exactly what makes each of those decisions correctable while the site is
small.

If a site ever genuinely needs unattended registration - a community, a
directory, a customer portal - this is what it costs, and the honest order is to
run SM673 first and find out how often the human step actually bites.

# Related

[[SM673]] (the attended flow, which this presumes), SM268 (minting credentials
as a human operation - this removes the human entirely, and should be read as
overturning that ruling rather than qualifying it), [[SM232]] (subject-scoped
export and erasure - the personal-data half of bulk removal).

# Not started
