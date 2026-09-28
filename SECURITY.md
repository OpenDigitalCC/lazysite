# Security Policy

## Supported versions

Security fixes are applied to `main` and ship in the next tagged release. The
committed support period (a CRA Article 13 requirement) is **five years from
the first stable release (0.7.0)**, with security fixes delivered on the
stable release channel for that period; on the edge channel the latest tagged
release remains the supported version. The commitment is recorded in
`docs/POLICY.md` ("Support period") and in the Declaration of Conformity
(`docs/DECLARATION-OF-CONFORMITY.md`); the period's start date is fixed when
the 0.7.0 stable release is cut.

## Reporting a vulnerability

To report a security vulnerability, please do not open a public
GitHub issue.

Preferred channel: GitHub's private vulnerability reporting at
https://github.com/OpenDigitalCC/lazysite/security/advisories/new

Please include:

- A description of the vulnerability.
- Steps to reproduce (or a proof-of-concept).
- Assessment of the potential impact.
- Any suggested fix or mitigation.

We aim to acknowledge reports within 48 hours and to provide a fix
timeline within 7 days for critical issues.

## Scope

In scope:

- The Perl scripts in this repository (`lazysite-*.pl`, `tools/*.pl`).
- The shipped Apache vhost templates under `installers/`.
- The default manager view template.

Out of scope:

- Vulnerabilities in Perl itself or in CPAN modules listed under
  "Non-core dependencies" in `docs/architecture/code-quality.md`.
  Please report those upstream.
- Misconfiguration of an operator's web server or DNS.
- Browser-level vulnerabilities where lazysite's headers are the
  same as the wider web-server defaults.

## Threat model and security model

The structured threat model (STRIDE, with OWASP ASVS L1 control mapping) is at
[docs/SECURITY.md](docs/SECURITY.md); the mechanism-level security narrative is
at `docs/architecture/security.md`.

## Security considerations for operators

Key operational points (full detail in `docs/architecture/security.md`):

- **Strip client-supplied auth headers at the web server edge.**
  Add `RequestHeader unset X-Remote-User`, `X-Remote-Groups`,
  `X-Remote-Name`, `X-Remote-Email`, `X-Payment-Verified`, and
  `X-Payment-Payer` to the vhost. The Hestia and Docker installer
  templates include this.
- **A connector is a disclosure you configured (SM579).** Site data leaves
  the instance only through a connector you defined with `manage_connectors`,
  under a secret held engine-side (`lazysite/connectors/secrets.json`, 0600).
  A public form may send through one only if the connector opts in
  (`public: 1`, off by default); bound the fields such a form sends (fixed
  choices, not free text). Every call is audited by connector, trigger, mode
  and data class - never the payload - and rate-capped per connector.
- **A form that acknowledges the submitter mails an address a stranger chose
  (SM877).** An email handler writes only to the address you configured until
  you set `mail_the_submitter_field`; from then on the site also sends a
  separate message to whatever that form field holds. That is deliberate and it
  is an open-relay surface, so it is capped on the two axes that matter - per
  recipient and per site, both per hour, `submitter_per_destination_hour` (3)
  and `submitter_per_site_hour` (60). **The form's own rate limit does not
  protect this**: it is keyed per source IP, so it bounds how often one sender
  submits and says nothing about how many destinations the site will write to,
  and the party being harmed is the recipient. A cap that cannot be counted -
  because the record will not open - refuses the acknowledgement rather than
  treating an unreadable counter as an empty one. Your own notification always
  goes, and anything refused is recorded against that delivery in the audit
  trail.
- **Grant manager access through groups.** Manager access is
  carried by groups only: the `ui` capability admits a group's
  members to the manager UI, and `manage_users` carries the
  operator powers. Both are grants in
  `lazysite/auth/groups-settings.json`, edited on the manager
  Groups page (`perl tools/lazysite-users.pl setup-sysop --user NAME` seeds a
  correctly-granted admin group). When **no** group grants manager
  access, the site is in unsecured/dev mode and any authenticated
  user is treated as a manager (a DEBUG-level log line is emitted
  in that case). The legacy `manager_groups:` conf key was retired
  in 0.6.5 (SM138) with an automatic migration - see `UPGRADE.md`.
- **Set a password** for every user who might ever connect from
  anything other than localhost. Empty-password accounts only work
  from `127.0.0.1` / `::1`, but a user that exists must be
  password-protected before the site is exposed.
- **Use HTTPS** in production. The auth cookie's `Secure` attribute
  is only emitted when `$ENV{HTTPS}` is set; over plain HTTP the
  cookie is still `HttpOnly; SameSite=Lax`, but the `Secure`
  attribute and the trusted `Strict-Transport-Security` header
  require a TLS-terminated deployment.
- **Rotate the installation HMAC secret** to invalidate every
  outstanding session. Use the "Log out all users" button on the
  manager Users page, or rewrite `lazysite/auth/.secret` with fresh
  random bytes by hand. This is the server-side lever for mass
  logout; see `docs/architecture/security.md` under "Session
  revocation".

For questions about the security model that are not vulnerability
reports, please open a regular GitHub issue or start a discussion.
