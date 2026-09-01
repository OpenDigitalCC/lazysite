---
id: SM724
title: "SM724: a user has a default page to land on"
subtitle: "Users are shared between the manager and the app, and nothing says where a given one belongs. An operator sets a default page per user - a manager page, or a domain - and an unset default falls back to the user's own page."
brand: plain
standard-margins: true
status: candidate
---

# What is asked

Requested by the release manager, 2026-09-01:

> users are shared between manager and the app. if they have manager ui, they go
> there. i would like to set users default logged-in page. this might be a page
> in manager or something else. this should be added to users page - default
> page, with dropdown list of manager pages, plus list of domains, including
> default, and the user selects. if unset, its their own user page.

# What happens today, which is not quite the premise

There is **no default-page concept at all**. A successful login goes to
`sanitise_next( $form{next} // '/' )` - `lazysite-auth.pl:278`. So a user lands
on whatever `next` says, and on `/` when it says nothing.

**A manager user "goes to the manager" because they were bounced from it.**
Reaching `/manager` unauthenticated redirects to the login page carrying
`next=/manager`, and the login sends them back. It is not a capability check and
there is no rule keyed on holding `ui`.

That distinction decides the shape of this feature: it is not overriding an
existing rule, it is **supplying one where there is none**. A user who signs in
at `/login` directly currently lands on the site root whatever they hold.

# The three things that decide the design

## 1. A domain is not a path, and the existing guard refuses it

`sanitise_next` requires `\A/[\w/.-]*\z` and explicitly rejects
protocol-relative and backslash forms - it exists to stop a login redirecting
off-site, and H-1 is cited in its comments.

**A dropdown offering "domains" therefore proposes exactly what that function
was written to prevent**: a redirect to another host. This does not make the
request wrong - the domains in question are the instance's own - but it means
the domain half cannot reuse the path guard. It needs its own rule: the target
must be a domain **this instance serves**, checked against the domain list
rather than against a character class. A free-text field here would be an open
redirect with an operator-friendly label on it.

The two halves of the dropdown are two different kinds of value, and storing
them in one free-form field is how that distinction gets lost. Store which kind
it is.

## 2. A default the user cannot reach turns login into a refusal

The dropdown as described offers every manager page and every domain. A user
without `manage_data` given `/manager/data` lands on a refusal every time they
sign in, and cannot get past it without an operator.

Worse for a **confined** user: a default naming a domain outside their scope
sends them, at every login, to the one place they are not allowed.

So the list must be filtered by what **that user** can reach. And the filter has
to be computed from the target user's own grants - not from the operator's,
which is the trap: an operator building the list from what they themselves can
see would offer pages the subject cannot open. The engine already has this
lesson recorded elsewhere as *a grant cannot attribute its own access*.

**A fallback is needed even so**, because grants change after the default is
set. A user whose default has become unreachable should land on the fallback
with an explanation, not on a 403.

## 3. An explicit `next` must still win

Someone who clicked a link to a specific page and was bounced to login is going
somewhere on purpose. The default is for an arrival with no destination -
signing in at `/login` directly - and must not steal a journey already in
progress.

# The fallback does not exist yet

"If unset, its their own user page." **There is no per-user page.** The manager
ships nineteen pages and none of them is one; `users.md` carries an
account-settings block for the signed-in user, but it is a block on a page whose
subject is all accounts, not an addressable page of their own.

So this filing carries a second, smaller question: either the fallback is that
block and it needs its own URL, or the fallback is something else - the site
root, as today - or a per-user page is worth building and this is the reason to
build it. **Deciding this decides how much work the filing is**, so it should be
answered before the rest is estimated.

# Where the setting lives

`cmd_user_settings_set` in `tools/lazysite-users.pl` is the precedent, and
`display_name` and `comment` are the shape: a per-user value, single line,
length-capped, empty clears. A `default_page` setting joins them, which also
means it arrives on every surface that already reads user settings rather than
needing a new store.

**SM642's ruling on `display_name` bears on this**: that setting is display-only
precisely so nothing looks an account up by it. A default page is not an
identity either, and should stay a preference - nothing should ever grant,
confine or audit against it.

# Open items - the operator decides

- **Who may set it.** The request says the Users page, which makes it an
  operator act. Whether a user may set their own - and whether an operator's
  choice should win over theirs - is not decided here.
- **What the fallback is**, per the section above.
- Whether a domain target means that domain's root, or a chosen page within it.

# Outcome test

- A user with no default, signing in at `/login`, lands on the fallback.
- A user whose default is a manager page they hold the capability for lands
  there; one whose default they no longer hold lands on the fallback **with an
  explanation**, not a refusal.
- A confined user is not offered, and cannot be given, a default outside their
  scope.
- An explicit `next` beats the default.
- A domain target resolves only to a domain this instance serves; anything else
  is refused at the point it is set, not at the point it is used.
