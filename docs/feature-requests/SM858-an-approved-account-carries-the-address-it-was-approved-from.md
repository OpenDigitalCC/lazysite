---
id: SM858
title: "SM858: an approved registration carries no email, so the person it was created for cannot fetch their own link"
subtitle: "`account-approve` creates the account, places it in the flagged groups and mints a claim link - and records no address, so the operator must carry the link by hand and `forgot` can never resolve that account afterwards. The self-service the release manager asked for is `forgot`, which already exists and is already safe; what is missing is the one field it needs."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-12
raised-by: release manager (expo loop)
area: auth
---

# The loop the release manager described

> "a user follows the link with their code, fills in a form, operator uses this
> to create a user account (can this be made simpler so they don't have to
> retype from one box to another on the same system?), then they can issue the
> link. this is minimum viable. its almost self service with operator oversight."

Everything in that sentence exists except two joins, and the second one is
smaller than it looks.

# What already exists, read from the source

**`forgot` IS the self-service link.** `lazysite-auth.pl` mints a set-password
claim and emails it TO THE ACCOUNT'S REGISTERED ADDRESS. Its properties are
already the ones this needs:

- **always a generic response**, so it cannot enumerate accounts or addresses;
- **rate limited** by IP through `check_login_rate`;
- **interactive accounts only**, and never a disabled one;
- audited internally as a material auth event while the HTTP response stays
  generic;
- and where SMTP is absent it notifies the sysops rather than dead-ending
  silently (SM136).

So "someone presenting the email is able to have the link sent to them" is
built, and its security rests on the right thing: the link goes to the mailbox,
not to the asker. **The asker proves nothing; the mailbox does.**

**`account-approve` mints the claim** and returns the URL to its caller.

# The two gaps

**1. The approved account has no address.** `cmd_account_approve` calls
`cmd_add($user, '')`, joins the flagged groups and mints the claim. It never
records an email. `forgot` resolves an identifier to (username, address) from
`user-settings.json` and returns early when there is no address - generically,
as it must - so **an approved applicant can never fetch their own link**. The
operator has to carry the URL by hand, for ever.

**2. The operator retypes what the system already has.** The submission holds
the applicant's address; approval takes a username on the command line. Nothing
connects them, which is the retyping the release manager objected to - and it is
[[SM673]]'s named remaining half.

# The shape

**`account-approve` takes the address and records it**, so the account is
reachable by the machinery that already exists. Nothing else about the verb
changes: no password is set, the claim link is still the only way in.

**The form says which field is the address.** A registration form declares
`account_email: <field>` in its own conf. Without it a submission is an ordinary
submission and nothing offers to approve it - the flow is opt-in per form, which
keeps it away from every other form on the site.

**Approve from the submission.** The Submissions view offers Approve on a
submission whose form declares that field, and passes the address from the row.
The operator decides; the system does the typing.

**The username is allocated at approval, from the address** - SM673's own
recommendation, because a visitor-chosen username is both a collision problem
and an account-existence oracle.

# Why this is small

It adds no auth surface. There is no new public action, no new credential path,
no new email. The applicant's route is `forgot`, unchanged, with its generic
answer, its rate limit and its audit line. The only new thing an attacker can
reach is a form field on a page an operator chose to publish, behind the whole
forms pipeline - honeypot, timing token, rate limit, quarantine.

# What must NOT change with it

- **The generic response stays generic.** Whatever is added, the answer to
  "send me my link" must not differ between an address that exists and one that
  does not.
- **The name is decoration, not strength.** The release manager's framing has
  the person presenting an email AND a name. The mailbox is the control; a name
  check adds nothing, and if it ever answers differently for a wrong name it
  becomes the oracle the generic response exists to prevent.
- **Approval stays a human act.** SM268's ruling is intact: an operator looks at
  a submission and decides. The automatic version - approve on arrival, into
  pre-set groups - is [[SM674]] and is not this.

# Held by

To be built with: a never-claimed account approved with an address can fetch its
own link through `forgot` and set a password at `/claim`; the same request for
an unknown address answers identically; a form without `account_email` offers no
approval; and the address recorded is the one from the submission rather than
anything the caller supplied.

# Related

[[SM673]] (the approval verb and its remaining half - this is that half, plus
the field that makes it useful), [[SM674]] (the same loop with no operator),
SM072 (the claim redemption both reuse), SM136 (the no-SMTP notice),
[[SM856]] (the code that gets the applicant to the form in one tap).
