---
id: SM1149
title: "SM1149: the Odoo connection can trust its own CA"
subtitle: "`odoo_ca_file` in the extension's config is the CA bundle for the connection to Odoo only, passed to OOM as ssl_ca_file and never as SSL_CERT_FILE."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: the lazysite-sites agent (OOM Lab L-1), accepted by the release manager 2026-10-17 ("all rulings accepted")
area: odoo
status-note: "SHIPPED on n641: lib/Lazysite/Odoo.pm connection and context, lib/Lazysite/Odoo/Session.pm _transport, plugins/odoo.pl; t/unit/odoo/46."
---

# What happened

From the lazysite-sites agent, OOM Lab findings for the Odoo extension, 2026-10-17 (inbox/2026-10-17-oom-lab-findings-for-the-odoo-extension.md), finding L-1:

> No CA setting for the Odoo connection. The guide says to reach an internal Odoo
> over https to its private name, which usually means a private CA, and the
> extension has no `odoo_ca_file`. The lab sets `SSL_CERT_FILE` for the whole
> server (OOM's HTTP::Tiny honours it), which also replaces the system CA bundle
> for that process.

# What shipped

- `odoo_ca_file` in the extension's config: optional; a full path to a readable
  file, checked with the rest of the connection (`connection()` refuses a relative
  path, a missing file, a directory, and a file this process cannot read, by name).
  The field's note says what it is for: an Odoo behind a private authority, used for
  the connection to Odoo only, verification still on.
- OOM takes it as `ssl_ca_file`, which its transport hands to HTTP::Tiny as
  `SSL_options => { SSL_ca_file => ... }` for that client alone. Lazysite passes it on
  every client it builds for Odoo: the connection user's call and a person's
  session call (`Odoo::Ops::Config`), and sign-in, the identity refresh and sign-out
  (all now built by one `Lazysite::Odoo::Session::_transport`). Nothing is set in
  `%ENV`.
- Listed in the extension's `config_keys`, and in the guide.

t/unit/odoo/46 stands in for OOM's `http_client` to see the arguments each of the
five paths gives it (with no network), checks that none is given when the setting
is blank, that the process environment is unchanged, and that OOM's own
constructor puts the file in that client's SSL options and leaves a client built
beside it alone.
