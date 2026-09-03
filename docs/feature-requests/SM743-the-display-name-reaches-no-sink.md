---
id: SM743
title: "SM743: the display name reaches no sink"
subtitle: "A user has a display_name. The admin bar is written to prefer it. Nothing connects the two - auth_name is populated only from an upstream header, so on any site using lazysite's own auth the field is stored, editable, and consumed by nothing."
brand: plain
standard-margins: true
status: shipped
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


# What shipped

`display_name` now reaches `auth_name` on the native auth path, so the admin
bar shows what it was always written to prefer and the field stops being
stored, editable and consumed by nothing.

**Two readers, deliberately.** `Lazysite::Auth::Settings::display_name_for` is
the shared one. The processor keeps its own `_display_name_for`, because ADR
0001 makes its render path module-free by design - the same reason
`_groups_grant_cap` is a local copy of the shared helper beside it.

**The header still wins.** A deployment behind header auth has an upstream that
knows who this is, and its answer is not second-guessed by a local record; the
fallback runs only when `auth_name` arrives absent or empty.

**The value travels RAW.** SM709 escapes at the point the TT stash is built and
again at the admin bar, which reads `%AUTH_CONTEXT` directly. Both escape from
the raw value - correct, and only correct while what is stored is raw. Escaping
here would double it and render `O'Brien & Sons` as `O&#39;Brien &amp; Sons` on
the page.

**Memoised on the file's identity**, following SM334's settings cache: a
rewrite changes mtime or size, the key misses, the value is re-read. Under the
FastCGI pool this process serves many requests, and reading and decoding
user-settings.json on every authenticated render is exactly the per-request
cost SM663 and SM685 were about. A stat is not.

# The draft that would have shipped inert

The first version called the shared helper from the processor inside an `eval`.
The module is not loaded there, so the call would have died, the eval would have
swallowed it, and **every display name would silently have been ''** - a
feature that ships, appears to work, and does nothing.

That is the same shape as SM732's render with no caller and as this filing's own
defect, which makes it a poor way to fix a dead field. It was caught by reading
why `_groups_grant_cap` exists rather than by a test, so the test now asserts
the local reader exists and that the shared one is NOT called.

That assertion needed a second correction of its own: it first searched the
whole file and failed on the processor's own COMMENT, which names the shared
helper in prose to explain why it is not called. A source check that cannot tell
code from prose about code reports the explanation as the defect. Comments are
stripped first.

# What this unblocks

SM709's escaping has shipped since 0.11.10 guarding a value nothing on our fleet
could populate - the field agent could not test it at all, on edge or on a
stable site, because no native-auth deployment had a path to `auth_name`.

It is now reachable on any site with a user who has a display name. **The thing
to look for is the double-escape**, because that is what the two sinks make
possible and it is visible at a glance: an admin bar reading `O&#39;Brien`.
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
