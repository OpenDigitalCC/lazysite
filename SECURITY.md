# Security Policy

## Supported versions

Security fixes are applied to `main` and ship in the next tagged release; the
latest tagged release is the currently supported version. A formal
support-period commitment (a CRA Article 13 requirement, expected five years
from release) will be set at formal launch and recorded here and in
`docs/POLICY.md` - until then this rolling-latest posture is the interim
practice, not the committed policy.

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
- **Set `manager_groups:`** in `lazysite.conf` to restrict manager
  access to a named group. Leaving it empty grants manager access
  to any authenticated user (a DEBUG-level log line is emitted in
  that case).
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
