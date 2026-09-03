---
id: SM743
title: "SM743: the display name reaches no sink"
subtitle: "A user has a display_name. The admin bar is written to prefer it. Nothing connects the two - auth_name is populated only from an upstream header, so on any site using lazysite's own auth the field is stored, editable, and consumed by nothing."
brand: plain
standard-margins: true
status: candidate
---

# The moment this fills

The field agent set out to test SM709's escaping of `auth_name`. They created a
user whose display name was `Séan O'Brien & Sons` - apostrophe, ampersand and an
accent, exactly the shape the escaping exists for - gave it a group, logged in,
and found the admin bar showing the **login** (`vprobe`). A page containing
`[% auth_name %]`, rendered as that user, came back **empty**.

They asked the right question: is the bar *meant* to show the display name?

**Yes.** `lazysite-processor.pl:7443`:

```perl
my $user = $vars->{auth_name} || $vars->{auth_user} || '';
```

Display name preferred, login as the fallback. So the bar is written for a world
in which `auth_name` is populated.

# Why it was empty

`auth_name` has exactly one producer (`lazysite-processor.pl:510`):

```perl
my $auth_name = $ENV{ $make_env->( $site_vars->{auth_header_name} || 'X-Remote-Name' ) } // '';
```

An **upstream request header**, set by a proxy doing external authentication.

The native session path assigns `$auth_result->{auth_name} // ''` in two places,
and **nothing anywhere sets `$auth_result->{auth_name}`**. There is no producer
in `lib/Lazysite/Auth/` at all.

Meanwhile `display_name` is a real per-user setting, settable from the manager UI
and from the CLI. Its only reader in the entire tree is
`tools/lazysite-users.pl`, which is also its only writer.

So the chain is: **the store holds a display name, the bar wants a display name,
and no code path carries one to the other.** On any site using lazysite's own
auth, `auth_name` is permanently empty, the bar always shows the login, and
`[% auth_name %]` always renders nothing.

# Two things this is, not one

**A dead field.** An operator can set a display name, see it save, and never see
it anywhere again. That is worse than not offering the field.

**A test that cannot be run where we assumed.** V12-02 in the 0.12.0 plan asked
for a real user name in the admin bar, and the plan said the way to get one was a
stable site with real users. That was wrong, and the field agent's follow-up
inherits the error: a stable site using native auth will not light this sink
either. **The sink is reachable only behind header-based upstream auth.**

# What this says about SM709

The escaping is pointed at the right variable, and the asymmetry is worth
recording because it is easy to get backwards.

`auth_user` is **charset-constrained at creation** to `[a-zA-Z0-9_.-]`
(noted at `lazysite-processor.pl:6483`), so it cannot carry markup. `auth_name`
is free text arriving in a header from a proxy - **unconstrained, and the only
one of the pair that can carry a payload.**

So SM709 escaped the variable that actually needed it. The finding here is not
that the escaping is wrong; it is that the one sink that can be attacked is
unreachable on most of the fleet, and therefore untested.

# The decision

**Populate `auth_name` from `display_name` on the native auth path** - the bar
then behaves as written, the stored field means something, and the double-escape
question becomes testable on any site with a user. This is the option that makes
the existing code correct rather than making it dead.

**Or accept that the bar shows the login on native auth**, drop the `auth_name`
preference from the sink, and either remove `display_name` or document it as
being for the operator's own reference only.

The first looks right, but it widens what flows into a render sink, so it is the
release manager's call rather than mine.

# Provenance

Edge testing agent, 0.12.0 follow-up (V12-02), 2026-09-03. Found while trying to
test something else, which is where most of this release's findings came from.
