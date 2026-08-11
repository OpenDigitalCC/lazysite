---
title: "lazysite - host dependencies"
subtitle: "The OS packages a host needs, beyond core Perl"
brand: plain
standard-margins: true
---

**Generated file - do not edit by hand.** Produced from
`dist/config/sbom-deps.json` by `tools/gen-host-deps.pl`; that JSON is the
authoritative machine-readable list. To check a live host instead of reading
this snapshot, run `lazysite-check.pl --dependencies`, which reports which of
these are present and prints the install line for whatever is missing.

## What you need

lazysite runs on core Perl plus a small set of packaged Perl modules. The core
modules ship with the `perl` package (Debian: `perl-modules-*`); only the
non-core packages below must be installed explicitly. Package names are Debian;
`sbom-deps.json` also carries the RHEL and Alpine equivalents.

On Debian or Ubuntu, install them all with:

```bash
sudo apt-get install \
    libarchive-zip-perl \
    libfcgi-perl \
    libfcgi-procmanager-perl \
    libio-socket-ssl-perl \
    libnet-ssleay-perl \
    libnet-xmpp-perl \
    libtemplate-perl \
    libtext-multimarkdown-perl \
    liburi-perl \
    libwww-perl
```

## Packages

```datatable
columns: Package | Perl module(s) | Enables
widths: 5cm | 4.5cm | X
bold: 1
tone: medium
text: 3
---
libarchive-zip-perl | Archive::Zip | theme upload (manager), zip download (manager)
libfcgi-perl | FCGI | FastCGI accept loop (SM142, optional; lazy-required - plain CGI needs nothing)
libfcgi-procmanager-perl | FCGI::ProcManager | FastCGI prefork pool (SM142, optional; lazy-required when LAZYSITE_FCGI_WORKERS>0)
libio-socket-ssl-perl | IO::Socket::SSL | SMTP form delivery over STARTTLS; domain-check TLS/cert probe (SM156, lazy-required)
libnet-ssleay-perl | Net::SSLeay | domain-check certificate expiry read (SM156; also IO::Socket::SSL's own backend)
libnet-xmpp-perl | Net::XMPP | XMPP notification delivery (notify-xmpp plugin, optional; lazy-required only when enabled)
libtemplate-perl | Template, Template::Parser | SM071 layout.tt compile validation in the control API (ships with Template); Template Toolkit page rendering (processor core)
libtext-multimarkdown-perl | Text::MultiMarkdown | Markdown to HTML conversion (processor core)
liburi-perl | URI | URL parsing in SSRF guard and remote-fetch path resolution
libwww-perl | LWP::UserAgent | remote content fetch for :::include and url: variables, form webhook delivery
```

## Runtime environment

perl
: Perl runtime. Required version 5.10+. On Debian: 'perl'. On Alpine: 'perl'. On RHEL: 'perl'. Includes core modules listed above.

git
: Host binary for the SM085 content history (conf key 'git_history: enabled'). Optional - only needed when the feature is enabled; invoked list-form (never through a shell), never a Perl module. Saves keep working without it (lazysite-check WARNs). Debian: 'git'.

Apache HTTP Server
: CGI host. Operator-provided. Any CGI/1.1-capable server works; Apache is the reference platform. The dev server (tools/lazysite-server.pl) is evaluation-only.

## Development-only: nginx

nginx is **not** a runtime or build dependency. It is used by two tests, both
of which skip cleanly when it is absent:

- `t/lint/34-front-end-configs-parse.t` runs `nginx -t` over every shipped
  nginx config, so one that will not start cannot ship. A front-end config that
  fails to parse takes a site down at the front door rather than degrading.
- `t/integration/42-hestia-proxy-gates-statics.t` starts nginx against the
  rendered Hestia proxy template and reproduces SM283's field measurement.

Install with `apt install nginx-light` (no service needs to run; the tests use
their own prefix, config and port). `openssl` is used to make a throwaway
certificate for the SSL template.

Worth stating plainly, because it is the lesson of SM283: the defect was in an
nginx config, on a repo whose entire coverage of nginx configs was text
matching, and the text matched. These two tests skipping is a real gap wherever
they skip - `t/lint/33` still pins the same files by text so that something
holds there, but it is the weaker check, not an equivalent one.

## Core modules

The remaining modules lazysite uses (`Digest::SHA`, `File::*`, `POSIX`, `Cwd`,
`Encode`, `JSON::PP`, `MIME::Base64`, `Socket`, `IO::Socket::INET`, and the
rest) are core Perl - present wherever Perl is. The full list, with per-module
purpose and licence, is in `dist/config/sbom-deps.json`.
