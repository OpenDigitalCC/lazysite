---
id: SM1047
title: "SM1047: a scope check reads the path the handler writes"
subtitle: "acl-set's scope check read the query and its handler the body. The sweep of every control-API action that takes a path, a store or a reference found two more of the same shape, each a cross-domain read by a domain-confined caller."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: inbox 2026-10-12, what a site partner cannot do while building a site (P-9)
area: security
status-note: "SHIPPED (PENDING): acl-set's path resolved once from query or body before the scope check, two that differ refused; form-submissions checks the store it reads; a brief's typed check only for type=row (t/integration/205, 206)."
---

# The report

P-9: "`path` is read from the body but the scope check reads only the query, so
a body path fails with 'Path '/' is outside your assigned scope'." Smallest
change asked: "Check the scope against the path that will be used."

# What the probe showed

t/integration/205, run against main before the fix, as a token and as a
cookie manager, each confined to `sites/mine`:

| Request | Main | Now |
| --- | --- | --- |
| body path in scope, no query path | refused: "Path '/' is outside your assigned scope" | served, rule on that path |
| body path out of scope | refused for '/' (never the path sent) | refused for scope, naming the path |
| query in scope, body out of scope | refused by the handler ("reads its path from the query string") | refused, kind `conflict`, nothing written |
| query out of scope, body in scope | refused for scope | refused for scope |
| query and body agree | refused by the handler | served |
| body path a list | refused | refused, kind `invalid` |

THE DANGEROUS DIRECTION DID NOT WRITE on main: the handler refused every body
path (SM306), after the scope check had already refused the '/' the query
defaulted to. The defect was the misleading refusal and a reference
(`query_or_body`, extracted by lint 58 from the handler's own read) that told
callers a body path was accepted.

# The fix

The dispatcher resolves the path ONCE, after the body is read and before the
scope check: for an action whose reference declares `path` `query_or_body`, a
body path is taken into `%params` and `$path`, which the scope check, the
carve-out check, the handler and the audit all read. Two different paths are
refused, naming both; a body path that is not one string is refused.
`dispatch_acl_set` refuses a body path that is not the one resolved, for a
caller that skipped the dispatcher. Lint 217 names the one new writer of
`%params`.

# The inventory

Every control-API action that takes a path, a content root, a host, a store or
a typed reference, the gate that confines it, and the value its handler uses.
"Same" means the gate and the handler read one expression.

| Action(s) | Gate (lazysite-manager-api.pl unless named) | Handler reads | Finding |
| --- | --- | --- | --- |
| list, read, save, delete, mkdir, move, copy, migrate-to-local, git-history/show/restore, lock, unlock, renew-lock, preview, preview-public, page-pdf, file-upload, file-download, acl-get, acl-remove, protected-sections | `_confine_scope` (~518): `$path`, `$params{to}`, `$params{from}`; carve-out (~990): `$path`, `$params{to}` | `$path`, `$params{to}` | same |
| acl-set | `_confine_scope`: `$path` | Files.pm `dispatch_acl_set`: `$Lazysite::Manager::Common::path`; body `path` refused | split (P-9), fixed |
| file-zip-download | `_confine_scope`: `$path`; carve-out: `collect_zip_paths()` | Upload.pm `action_file_zip_download`: `collect_zip_paths()`, each re-checked for scope and ACL | handler re-checks each entry |
| cache-invalidate | `_confine_scope` and `_refuse_unreachable_domain(host => $params{host})` | `$path`, `$params{host}` | same |
| brief-read, brief-append | `brief_reach_refusal($path, %typed)` | Briefs.pm: typed only for `type=row`, else `$path` | split: Common.pm `caller_may_reach_brief` took the typed branch for any `type`; fixed |
| brief-delete | path when given, else typed | path when given, else typed | same |
| form-submissions | `_refuse_unreachable_form`: `form` when sent, else the store's form | Plugins.pm `action_form_submissions`: `file` when sent | split; fixed |
| form-submission | store's form from `$params{file}` | `$params{file}` | same |
| form-submission-delete/-confirm/-approve, form-submissions-delete-bulk | store's form from `$req->{file} // $params{file}` | the same expression | same |
| form-targets-read/-save, form-uploads-save, form-notify-save, form-delete | `$req->{form} // $params{form}` or `$params{form}` | the same | same |
| domain-add | `_refuse_unreachable_domain(root => $req->{content_root})` | `$req->{content_root}` | same |
| domain-alias-add | `host => $req->{alias_of}` | `$req->{alias_of}` | same |
| domain-set, domain-remove, remap-save | `host => $req->{host}` (and `root => $req->{value}` for content_root) | `$req->{host}` | same |
| domain-preview, domain-check, aliases-list, theme-activate/layout-activate with host | `host => $params{host}` | `$params{host}` | same |
| nav-read, nav-save | inside Nav.pm, on the resolved host | `$params{host} // $req->{host}` | same (one value) |
| site-backup-create | inside SiteBackup.pm, on the resolved host | `$req->{host} // $params{host}` | same (one value) |
| data-row-save, data-row-delete, data-table-save | `row_write_refusal` / `writable_by` on `$req->{table} // $params{table}` | the same expression | same |
| data-safety-export-restore/-delete | inside Manager::Data, on the resolved file | `$req->{file} // $params{file}` | same (one value) |
| instance-wide gate (SM976 R1) | `$addressed` reads `$params{host}` only | theme-activate, layout-activate read `$params{host}` | same; a body host is not "addressed" and is refused as instance-wide (fails closed) |

MCP reads one argument per path (`_path_args`) for both its scope check and the
tool; `set_permissions` passes `path` to the writer it checked.

# The two further findings

Both are cross-domain reads by a domain-confined caller, built here because
they are P-9's class:

- `action=form-submissions&form=<a form of mine>&file=<another domain's
  store>` returned the other domain's submissions (tmp/probe-form-split.pl).
  The check now asks about the store when one is named.
- `action=brief-read&type=table&table=<a table of mine>&path=<another domain's
  page>` returned the other domain's brief, and `brief-append` wrote to it
  (tmp/probe-brief-split.pl). The check now takes the typed branch only for
  `type=row`, as `Briefs::typed_rel` does.

# Tests

t/integration/205 (the probe as assertions, token and cookie); 206 (the two
further splits). Sabotage: each fix undone in turn fails its test. t/lint/52
and t/integration/52 now hold that a body path is written where it says, never
the root.
