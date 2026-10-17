---
id: SM1128
title: "SM1128: sign-in through an identity provider, and groups that come from the directory"
subtitle: "The plan for united/platform's request: harden the trusted-header route it will use first, then a native OIDC relying party, then directory groups as a first-class source."
brand: plain
standard-margins: true
status: candidate
raised: 2026-10-15
raised-by: united/platform project (filed to lazysite/inbox 2026-10-15); planned at the release manager's request 2026-10-17
area: auth
status-note: "PLANNED; rulings R1-R6 ruled as proposed by the release manager 2026-10-17. Phase 1 in build; phases 2-3 when united/platform reaches step 7. auth_proxy_trusted is enabled on no site (release manager, 2026-10-17). Reply filed to united/platform/inbox 2026-10-17."
---

# The request

united/platform's phase 1 puts every service behind Authentik at
`id.theunited.community`. It asks lazysite for two things: authenticate a
visitor over OIDC (discovery, authorisation code, the groups claim mapped to
lazysite groups), and groups whose membership comes from the directory. It
will use lazysite's trusted-header route first (Caddy forward-auth to
Authentik's proxy outpost, headers copied to the names lazysite reads), and
asked six questions (`lazysite/inbox/2026-10-15-oidc-login-and-directory-groups-for-the-united.md`).

# What the code does today (2026-10-17)

Read from the code; file and line references are in the working notes.

1. **Groups under `auth_proxy_trusted`.** Page gates (`auth:`, `auth_groups:`,
   `groups:`) and per-file ACLs use the groups the proxy sends; ACLs also
   expand them through nested local groups. Manager capabilities do not:
   `caps_for` reads the local account store, so a directory group grants a
   capability only through the few gates that also read the header (`ui`,
   `manage_content`, `/manager` entry, operator status). Connector calls and
   whoami-style reports are store-only.
2. **Header names (SM960).** `auth_header_user`, `_name`, `_email`,
   `_groups` are honoured by the page gate only. The manager API, the manager
   entry, the ACL code and several processor readers use the fixed
   `X-Remote-*` names.
3. **No hop check (SM794).** With the flag on, any request carrying the
   headers is believed; nothing checks it came from the proxy. SM794 proposed
   `auth_proxy_trusted_from` (a CIDR list against `REMOTE_ADDR`); it was never
   built. On the cluster only network isolation (Caddy on a private Docker
   network) stands between a client and naming itself an operator.
4. **Unknown users.** A header identity need not exist in `auth/users`; it
   works with the header's groups. No provisioning.
5. **Group names.** Lazysite group names are `[A-Za-z0-9_-]{1,64}`; "Site
   Editors" cannot be one. The page gate splits a group list on commas, the
   manager on commas or whitespace, so a name with a space reads differently
   on the two. Authentik's groups header is pipe-separated.
6. **Sessions.** A header identity has no Sessions-registry entry and no
   cookie, so it cannot be revoked from the Sessions page; it ends at the IdP.
   If the visitor also holds a valid lazysite cookie, the cookie's identity
   replaces the proxy's - a stale local session beats the directory.
7. **Native route.** There is no OIDC client code; `lazysite-oauth.pl` is the
   authorisation server, the other direction. A password login ends in
   `_mint_session` and `_session_register` (lazysite-auth.pl); an OIDC
   callback would end the same way. Two constraints: the cookie verifier
   refuses an account missing from the local store, and it re-reads groups
   from `auth/groups` on every request, ignoring the groups in the cookie.
8. **Token doors** (MCP, control API, WebDAV) never read the browser identity
   and are unaffected by either route.

# Answers to united/platform's questions (facts; rulings marked)

1. The page gate uses the header's groups, not `auth/groups`. So step 6's
   finish line, a page visible only to a directory group, works today with
   `auth_groups: [<group>]`, provided the group name is a valid lazysite name
   or is mapped (R3), and the separator is a comma.
2. Copy the Authentik headers to `X-Remote-*` in Caddy. That is the only
   option every reader honours today; phase 1 makes the configurable names
   work everywhere.
3. Yes, the proposed shape for the native route is a relying party in
   `lazysite-auth.pl` that ends by minting the existing cookie (R4).
4. Sole or merged, and the name rule, are rulings (R2, R3).
5. Yes: token doors stay local (fact 8).
6. SM1128.

# The plan

## Phase 1 - make the trusted-header route safe and consistent (S-M, one batch)

| Ref | Change | Size |
|---|---|---|
| P1-1 | **Hop check**: `auth_proxy_trusted_from` (CIDR list). With the flag on, the headers are believed only from a listed `REMOTE_ADDR`; from anywhere else they are stripped as if the flag were off. Health-check warning when the flag is on with no list. (SM794's proposal.) | S |
| P1-2 | Every reader honours the configured header names (one accessor, a lint that nothing reads `HTTP_X_REMOTE_*` directly). | S |
| P1-3 | One rule for splitting a groups header, used everywhere; the separator configurable (`auth_header_groups_separator`, default comma, Authentik pipe). | S |
| P1-4 | Under proxy trust, the proxy's identity wins over a lazysite cookie for the same request; a cookie for a different user is ignored, not merged. | S |
| P1-5 | Group-name mapping for header groups (R3): normalise (lowercase, spaces and other characters to hyphens) or an explicit map in lazysite.conf. | S |
| P1-6 | Capabilities from header groups, consistently (R1): `caps_for` answers from the request's groups when the identity came from the proxy. | M |
| P1-7 | A docs page, "Behind an identity provider", with the Caddy forward-auth example for Authentik and the security conditions (P1-1 list, private network). | S |

## Phase 2 - native OIDC relying party (L, after rulings)

- Discovery from the issuer; authorisation code with PKCE, `state` and `nonce`;
  `id_token` verified against the issuer's JWKS (signature, `iss`, `aud`,
  `exp`, `nonce`). Needs a JWT/JWKS verifier in Perl: Debian
  `libcrypt-jwt-perl` (Crypt::JWT) is the candidate; an SBOM entry (R5).
- The callback provisions or matches the local account (R2, R4), writes the
  user's directory groups (phase 3), and ends in `_mint_session` /
  `_session_register`, so the processor, manager and Sessions page see a
  normal session that can be revoked locally.
- Sign-out is local plus RP-initiated logout at the issuer.
- Settings: issuer, client id, client secret (stored like other secrets, never
  shown), the groups claim name, scopes, the button label on /login.
- Browser visitors only; token doors unchanged.

## Phase 3 - directory groups as a source (M-L, after rulings)

- A group record may say its membership comes from the directory
  (`source: directory`). Its members are written at each OIDC sign-in from the
  claim (and replaced, not appended); the Users and Groups pages show them
  read-only and say where they come from.
- Sole or merged per site (R2): sole means local membership of a directory
  group is refused; merged keeps local members too.
- Capabilities stay on the group record, set locally, so the directory decides
  who is in a group and the site decides what the group may do.

# Rulings

The release manager, 2026-10-17: "rulings as proposed. auth_proxy_trusted has not
been enabled anywhere." The Proposed column below is the ruling.


| Ref | Question | Proposed |
|---|---|---|
| R1 | Should a directory group grant manager capabilities, or only page and file access? | Page and file access by default; capabilities only for groups the operator marks |
| R2 | Directory groups: the sole source for a site, or merged with local groups? | Per site, default merged |
| R3 | Group names from the directory: normalise, map explicitly, or both? | Normalise, with an optional explicit map that wins |
| R4 | A first OIDC sign-in by someone with no local account: create it, or refuse until an operator adds it? | Create, opt-in per site, into no groups except the directory's |
| R5 | A new dependency for JWT/JWKS verification (Crypt::JWT, Debian packaged)? | Yes; written by hand is the wrong place to save a dependency |
| R6 | Build order: phase 1 now (it is what the platform uses at step 6), phases 2-3 when the platform reaches step 7? | Yes |
