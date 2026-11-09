---
id: SM1351
title: "SM1351: sign in through an outside identity provider, with its groups"
subtitle: "A service team working across hundreds of instances cannot hold an account on each. lazysite signs people in through a standard OpenID Connect provider, and the groups the provider holds become lazysite groups."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-06
raised-by: "release manager (SM1350 discussion)"
area: auth
status-note: "SHIPPED (PENDING, 0.16.9) on n792: the oidc extension, H-1's second consumer; several providers (oidc-<name>, H-1 instances), code flow with PKCE, identity from the token endpoint (ruling 185), groups that may grant, audited (ruling 186), a broken provider refused and named (ruling 206). Questions 1-3 stay open."
---

# Today

- Each instance's accounts are its own.
- lazysite already runs an OAuth authorisation server, for AI connectors.
- It cannot sign a person in through someone else's provider.

# Proposed

- **The engine signs people in through a provider:** it is an OpenID Connect relying party, with the authorisation code flow plus PKCE. Settings: issuer URL, client id and secret (the secret under `lazysite/auth/`, never in `lazysite.conf`), the scopes, and which claim carries groups.
- **The sign-in page:** it offers "Sign in with <provider name>" beside, or instead of, the local form (an instance setting).
- **Group mapping:** a provider group maps to a lazysite group per instance, e.g. `service-team` to `operators`. Membership is read at each sign-in and never stored as a grant, so removing someone at the provider removes them everywhere at their next request.
- **More than one provider:** an instance may trust more than one provider, each mapped to its own groups. For example, the service desk's provider maps to operators, and a partner platform where site owners already have logins maps that owner to their own site's owner group. A provider that is not OpenID Connect is connected through ruling 70's identity hook as an extension.
- **Local accounts stay:** a site owner's account can remain local to the site (with SM1352 passkeys). They can also be at the provider.
- **No account is created** for a provider user who maps to no group.
- **Audit:** each provider sign-in is recorded with the provider and the subject.

# Provider choice is deployment, not engine

- **Authentik** is the release manager's expected choice.
- **Lighter options to weigh:**
  - Pocket ID: passkey-only and small.
  - Kanidm.
  - Authelia: it has an OpenID Connect provider.
- **A master lazysite as provider** is possible later: lazysite already issues tokens for connectors. It would make lazysite a provider for people too, which is a larger security surface. Filed as a question, not built.

The engine side is the same for all of them, which is why it is a standard relying party.

# Questions for ruling

1. Provider: Authentik or a lighter one, with a master lazysite as a later option?
2. May an instance turn its local sign-in form off entirely?
3. Provider sessions: the same session length as local sessions?

# Built (n792, 0.16.9)

Built to rulings 185, 186 and 206, as H-1's second consumer (SM1369 X4). There is no
OpenID Connect code in core.

The extension
: `extensions/oidc.pl`, its engine `Lazysite::Ext::OIDC` in its payload lib, and its
  endpoint `lazysite-oidc.pl` (H-4, held to the request kit; it takes GETs only).

Several providers
: Named in `lazysite/oidc.conf` (`providers: a, b` and `<name>.issuer`, `.client_id`,
  `.scopes`, `.group_claim`, `.group_map`, `.label`). H-1 gains `instances`: an extension
  that declares it is the providers `<id>-<name>`, each its own session prefix, record,
  why codes and audit rows; its functions are told which in `ctx`, its `login_option`
  answers one option per provider, and core refuses another extension's provider inside
  that family. The client secret is in the one secrets store (`lazysite/oidc/keys/`),
  set from the command line (`extensions/oidc.pl --secret <name>`, read from standard
  input).

The flow
: The code flow with PKCE (S256). The state is a random value in an HttpOnly,
  SameSite=Lax cookie scoped to the endpoint, naming a single-use record (nonce,
  verifier, redirect URI, next) kept ten minutes. Ruling 185: the code is exchanged at
  the token endpoint with client authentication (client_secret_basic, or _post where
  discovery offers only that); the ID token's signature is not checked; iss, aud (azp
  with several audiences), the nonce, the state and exp are. sub, the email and the
  groups come from the ID token, or from userinfo (its sub the token's) for any it
  lacks. The login is the subject: `oidc-<name>:<sub>`, shown by the email.

Groups
: Ruling 186: the extension declares `grants`, so a provider group may map to a
  capability group, operators included; core's grant row audits every sign-in with the
  provider, the subject and the groups granted. A person in no mapped group is refused
  and no account is made. The record's groups are re-read against the current map at
  every request.

Faults (ruling 206)
: A provider with a config problem, a missing or unreadable secret, or a discovery that
  failed signs nobody in and its sessions end; the others are untouched. The log line
  and `lazysite check` (H-6) name the fault and the remedy. An unreadable
  `lazysite/oidc.conf` refuses them all.

Discovery
: Fetched on save (`on_save`) and by Refresh, cached in `lazysite/oidc/discovery/`. A
  failed fetch replaces the cache with the failure. The issuer it names must be the
  configured one; the endpoints must be `https://` (plain `http://` only to this host,
  the connectors' rule); PKCE S256 must be offered where the document lists methods.

Tests
: `t/unit/extensions/170` against a 127.0.0.1 fixture issuer of two providers: a full
  sign-in; the state, iss, aud, nonce and expiry each refused when wrong; no mapped
  group refused; a group mapped to an operators group granted and audited; two
  providers side by side and on /login; userinfo groups; a broken secret refused, its
  sessions ended and named by check; a failed discovery refusing one provider; the
  family clash in core. Each sabotaged by hand.

Ruling 213 (n792)
: Plain http stays to this host only, and the identity stays `oidc-<name>:<sub>`. A
  provider may name its CA bundle (`<name>.ca_file`), the LWP client's SSL_ca_file for
  its calls alone; one that cannot be read refuses it, named by the log and the check.
  A start counts against the sign-in limiter per address before anything is written.
  The provider stays in the query, with `sep`: the web server rules (nginx's
  `/cgi-bin/<one segment>`) and the front door take no path after a script name.
