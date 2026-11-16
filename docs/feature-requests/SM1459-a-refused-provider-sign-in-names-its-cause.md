---
id: SM1459
title: "SM1459: a refused provider sign-in names its cause"
subtitle: "mint_provider_session refuses for four reasons and says none of them, so a stale extensions index was reported as a missing auth secret."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-16
raised-by: "a project running a development tree"
area: auth
status-note: "OPEN. R1 to R4 built on branch claude/n848-a-refused-provider-sign-in-names-its-cause (awaiting the release manager). R4 is a `lazysite check` warning, not a rebuild on load."
---

# What happened

A site on a development tree answered the Odoo sign-in with a 503 saying that a site session
cannot be made on this host because the auth secret is missing or the session registry cannot
be written, and to see the event log. The site's `lazysite/auth/.secret` and its session
registry were present and writable, and the event log held no line about either.

The cause was the site's `lazysite/extensions.index.json`. An earlier engine had built it, so
the Odoo entry carried no `identity_provider` declaration and
`Lazysite::Extensions::Hooks::identity_provider` answered nothing. Rebuilding the index fixed
the sign-in at once.

# Why

`Lazysite::Auth::Session::mint_provider_session` returned the empty list for four different
refusals and explained none of them:

1. the provider is not usable: absent from the extensions index, its extension off, or an
   extension it requires off - nothing logged;
2. the login cannot be a session's - nothing logged;
3. there is no auth secret - a missing `.secret` was silent, because `cannot_read` stays silent
   on ENOENT;
4. the registry append failed - nothing logged.

The Odoo extension then answered with one fixed text naming only causes 3 and 4, whichever
refusal it was. The OpenID Connect extension answered "The site could not start a session."

# The request

R1
: `mint_provider_session` gives a reason for each of its refusals and writes one event-log
  line per refusal, naming the provider and the path (or the remedy). A missing `.secret` is
  named. A caller asks for the reason with `refusal => \my $why`; a caller that passes nothing
  gets the empty list as before.

R2
: For a provider that is not usable, the reason says what to do. A provider absent from the
  index: the index is stale or the extension is off - rebuild the extensions index or switch
  the extension on. An index that lists the extension without its sign-in declaration: built
  by an older engine, rebuild it. An extension, or one it requires, switched off: switch it
  on. The log line carries the command an operator runs
  (`Lazysite::Extensions::Hooks::rebuild_index_command`, the upgrade's own step).

R3
: The Odoo extension's 503 carries that reason in place of its fixed text, and so does the
  OpenID Connect extension's. No secret, token or path under the private store reaches the
  browser: the page says the cause class, what to do, and "see the event log"; the path and
  the system error go to the log.

R4
: An index built by an older engine than the running one is named by `lazysite check`, with
  the rebuild command. The request path does not rebuild it: a rebuild runs each extension's
  `--describe` and writes a file the web user need not own, so doing it on load would run
  code and write state on a visitor's request. The check compares, for each enabled engine
  extension, the hooks the index holds with the hooks this engine's own descriptor declares,
  so it also catches a development tree that moved under a running site at the same version,
  which a version stamp in the index would not.

# Status

Built, awaiting the release manager. Tests: t/unit/auth/178 (each cause gives its own reason
and one log line, and the reasons differ), t/unit/odoo/63 (the 503 carries the cause through
the real endpoint), t/tools/691 (the check names a stale index, and is quiet once it is
rebuilt).
