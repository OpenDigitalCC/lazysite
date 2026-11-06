---
id: SM1351
title: "SM1351: sign in through an outside identity provider, with its groups"
subtitle: "A service team working across hundreds of instances cannot hold an account on each. lazysite signs people in through a standard OpenID Connect provider, and the groups the provider holds become lazysite groups."
brand: plain
standard-margins: true
status: candidate
raised: 2026-11-06
raised-by: "release manager (SM1350 discussion)"
area: auth
status-note: "Filed 2026-11-06 under SM1350. Builds on ruling 70 (a generic identity provider hook)."
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
