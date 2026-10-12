---
id: SM1002
title: "SM1002: a site can allow its own external hosts in the CSP"
subtitle: "The policy builder took script hashes and a mode and nothing else, so a site with one legitimate external script could stay report-only for ever or switch the policy off."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-11
raised-by: the dev inbox (2026-10-11, the CSP has no way to allow one external host); WORK-PLAN-0154 P16; ruling of 2026-10-12
area: security
status-note: "SHIPPED (PENDING): csp_script_src/connect_src/img_src/frame_src lists of https origins, validated (csp_origin_ok, a marked copy in the processor), appended to the default, per domain through alias.<host>.csp_*_src; never on the manager; check reports bad entries (t/unit/processor/103, lints 55 and 225)."
---

# The ruling

"Add allow-lists": csp_script_src, csp_connect_src, csp_img_src, csp_frame_src
in lazysite.conf, each a list of https origins (validated: no 'unsafe-*', no
bare *, only scheme+host[:port], a leading *. subdomain wildcard allowed),
appended to the default; per domain on multi-domain instances; check reports
bad entries.

# What a list may hold

An entry is an https origin: `https://` then a DNS-shaped host of two labels or
more, optionally led by `*.`, optionally `:port` (1-65535 shaped). That refuses,
besides what the ruling names: `http:` and every other scheme, a scheme alone
(`https:`), `https://*` and `https://*.com` (a wildcard over a top-level
domain), a single-label host (`localhost`), user information, a query, a
nonce, a hash, `'self'`, `'strict-dynamic'`, whitespace, and a `;` that would
start another directive. Entries are comma- or space-separated, lowercased
once, deduplicated, kept in the order written.

`Lazysite::SecurityHeaders::csp_origin_ok` is the rule;
`csp_allow_lists($raw)` splits a value into origins and refused entries. The
processor carries `_csp_origin_ok` as a marked copy (ADR 0001); lint 225 runs
both over six good and twenty-nine refused texts.

# Where it applies

`content_security_policy( allow => { script, connect, img, frame } )` (module)
and `_content_security_policy( \@hashes, \%allow )` (processor) append each list
to its directive after the default's own sources - `script-src 'self' <origins>
<hashes>` - and filter the origins again, so a caller cannot pass a keyword
through. Lint 55 compares the two by value, now with lists too.

The processor reads the lists in `_csp_allow` from `resolve_site_vars`, so a
domain's `alias.<host>.csp_*_src` (now in `%ALIAS_OVERRIDE_KEYS`) replaces the
site's for that domain, and a domain without one inherits the site's. An entry
that is not an origin is dropped and logged at WARN with the key and the entry;
the rest of the list stands.

**Never on the manager.** Its pages load nothing from elsewhere, and an
allow-list there would widen the one surface where an injection reaches an
operator's session; `_csp_allow` returns none for a manager request.

`lazysite check` reads every `csp_*_src` and `alias.*.csp_*_src` line and names
each refused entry with its line, or says every entry is an origin.

`csp:` itself had no entry in the reference; it has one now, beside the lists.

# Tests

t/unit/processor/103 (csp: enforce): the site's script and connect lists appear
after `'self'`, `'unsafe-inline'` and `*` do not, img-src is the default;
other.test's own script list replaces the site's and it inherits the connect
list; `lazysite check` counts two refused entries and names one with its line.
Lint 55: with stub site vars the processor's headers equal the module's given
the same lists, a refused entry is left out, the manager carries none. Lint
225.
