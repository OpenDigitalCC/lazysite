---
id: SM1141
title: "SM1141: a template can test an address, the check warns, a list in use is not deleted by accident"
subtitle: "Slice D of SM1134: visitor.in_list and visitor.in_any for a page, lazysite check for address rules that cannot work, and a delete guard on the address-list store."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: release manager, 2026-10-17 (SM1134)
area: auth
status-note: "SHIPPED on n637 (slice D of SM1134; cites SM1134 and SM1138): lib/Lazysite/Auth/AddressRefs.pm, lazysite-processor/render.pm and pipeline.pm, tools/lazysite-check.pl, tools/lazysite-users.pl; t/unit/processor/133, t/unit/tools/82, t/unit/users/53."
---

# What happened

SM1134, ruled in full on 2026-10-17 ("1. yes, 2. yes. 3. yes. 4. yes. 5. yes.
6. yes."), asked for "some TT could test the blocks", for `lazysite check` to
warn "when address rules are in use and `trusted_proxies` does not cover the
front end, because then every visitor appears to come from the proxy and the
rules mean nothing", and (SM1138) a store whose lists a rule can name. Ruling 4:
the template test exposes list membership only. A list that is deleted while a
rule names it is not an empty list: an allow rule naming it admits nobody, so
the page, folder, group or manager behind it shuts with nothing said.

# What shipped

## The template test

`[% visitor.in_list('office') %]` is `1` or `0`; `[% visitor.in_any(['a','b']) %]`
is `1` when the address is on any of them. `visitor` holds those two methods and
no value, so no spelling of a template prints the address (ruled: membership
only). The address is `Lazysite::Auth::AddressLists::client_address()`, the one
reader that honours `trusted_proxies` (SM929): a caller's own `X-Forwarded-For` is
believed only from a listed proxy, and then the rightmost untrusted hop wins. A
list that does not exist, or a store that will not read, answers `0`.

**Cache rule (SM1068's).** A render that asked is the visitor's own. The method
sets `$RENDER_BY_ADDRESS` when it is CALLED; `_render_has_viewer` (the test
`process_md` uses before writing the shared cache) reads it, and the request
handler marks the response protected, which sends `Cache-Control: no-store,
private` and skips the content-type and dependency writes. A flag set by the
call was chosen over scanning the source because the call can sit in the page, an
included file or the layout, and a scan sees only the file it reads; it costs a
page that never asks nothing, and the flag is set before the answer is worked out,
so a fault in the store still keeps the page out of the cache. The flag is cleared
at the top of every request, as the pool reuses the process. The engine loads the
address module only when a template first asks (ADR 0001).

Documented in starter/docs/reference.md (Auth variables) and
starter/docs/features/authoring/visitor-ip.md.

## `lazysite check`

`report_address_rules` is silent for a site with no address rule. Where a rule
exists (page front matter `addresses` / `addresses_deny`, an acls.json entry, a
group record, `manager_addresses` / `manager_addresses_deny`) it warns:

- `trusted_proxies` trusts no front end (`none`, or a list that resolves to
  nothing): every visitor appears to be the connecting peer;
- an install with a front end in front (a pool conf in /etc/lazysite/pools for this
  docroot, or Hestia's /home/USER/web/DOMAIN/public_html layout) and
  `trusted_proxies` unset, where only 10/8, 172.16/12 and 192.168/16 are believed,
  so a proxy on loopback or a public address is not covered. The check cannot see
  the connecting address; it names the evidence it went on;
- a rule names a list the store does not hold (named, with where);
- the store cannot be read, or does not decode, while rules name lists (everything
  they name denies).

## Delete guard

`address-list-delete NAME` (users tool CLI and API, and so the manager action and
its API) refuses while any rule names the list, with kind `in-use`, saying where:
page paths, acl paths, group names, the conf key. `--force` (CLI) / `force: true`
(API; the delete is already the operator's) deletes it anyway and the audit row
(CLI) or change line (the manager's audit row) reads `deleted (N entries, KIND,
forced); still named by ...`. A rule store that cannot be read refuses too,
because it cannot say nothing names the list.

`lib/Lazysite/Auth/AddressRefs.pm` is the one reader of where the rules are; the
check and the guard both use it, so they cannot disagree about "in use". It reads
the contract's field names directly and does not depend on the slices that enforce
the rules.

It walks the docroot and the private store, and that is every domain: a content root
is served only from inside the docroot (`confine_content_root` reads it relative to
the docroot, resolves symlinks and refuses anything outside, falling back to the
docroot), and a gated page moves to the private store at the same relative path.
t/unit/users/54 pins a page under a domain root, a gated one in the private store,
and a root written as an absolute path.

# Left open

- The manager's Address lists page shows the refusal text but has no "delete
  anyway" control; the API takes `force`.
