---
id: SM1308
title: "SM1308: a confined agent lists and searches only its scope"
subtitle: "An MCP grant confined to a scope was answered list_pages, list_files and search_files from the whole docroot when it named no path, and the search printed lines of files whose rule it does not pass. A missing path is now its scope roots, every walk stays inside them, and each search hit is one it may read. The manager API's twins, list and pages, answer the same way."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-04
raised-by: "the release manager, ruling 47 (tmp/rulings-2026-10-22.md, \"4 November\"), on T-01 of the inbox triage (tmp/inbox-triage-2026-11-04.md): a report from a site building a protected intranet, gap G3"
area: access
status-note: "SHIPPED (0.16.3) on n739: a confined grant's walks (list_files, list_pages, search_files, delete_page's references, rename_page's rewrite) start at its scope roots; each search hit is asked _acl_denied; the manager API's list and pages answer the same. t/unit/mcp/65, t/unit/manager/415."
---

# What was asked

Ruling 47 (2026-11-04): "A confined grant's list_pages, list_files and search_files
answer only within its scope; a missing path means its scope roots (T-01)." The brief
added: the search applies the ACL to each hit, as reads do, and the control API's twins
are fixed the same way.

The report (gap G3): an agent confined to one area found a line of an `auth: required`
page outside it through `search_files`, was listed 108 site pages by `list_pages`, and
was shown the docroot by `list_files {"path":""}`. `read_file` on the same paths was
refused as outside its scope.

The cause is in the dispatcher's scope pass (`lazysite-mcp.pl`, tools/call): it checks
each path argument the tool declares, and skips one that is not given or is empty. So
an explicit `/` was refused, and an absent path reached the handler, which defaulted it
to `/`. `list_pages` takes no path at all.

# What shipped

- **The scope roots.** `_walk_roots($caps)` is the grant's scopes, docroot-relative,
  with nested roots dropped, or undef for a grant with no scope (which reaches the
  primary site whole, as a content path check reads it).
- **list_files.** With no path, or an empty one, a confined grant is answered
  `Files::action_list_scope_roots`: a listing with one folder entry per scope root
  that exists, `scope_roots: true`. A named path goes through the scope pass as before.
- **list_pages** walks the scope roots (`_each_page` takes the roots).
- **search_files** with no path walks the scope roots, and every candidate file is
  asked `outside_all_scopes` again, as the blocklist is asked. A named path is held to
  the scope by the pass, as before.
- **The ACL on each hit.** At a file's first matching line the search asks
  `Acl::_acl_denied($key, 'read', $user)`, read_file's question (the read list and the
  address rule), and leaves the file out when it is refused. It is asked before the
  match is counted, so paging cannot step over a hit it never showed. This applies to
  every grant, confined or not: a file read_file refuses is one the search does not
  quote.
- **delete_page and rename_page**, which reuse the same walks: `still_referenced_in`
  names only pages in the scope that the caller may read, and `update_links` rewrites
  links only in the pages of the scope. It wrote every page on the site that linked to
  the old path.
- **The manager API.** `list` with no path, or an empty one, answers the scope roots
  for a confined caller (cookie or token), through the same function. An empty path
  listed the docroot (it was `''`, which the scope check skips and action_list reads as
  `/`); an absent one was refused. `pages` keeps only the pages within the caller's
  scopes; it took no path, so the scope check had nothing to inspect. The manager's own
  pages always send a path, so its file browser is unchanged.

# Tests

- **t/unit/mcp/65** (new): a grant confined to `content/mine`. list_files with no path
  and with an empty path lists the scope root alone; list_pages and search_files name
  nothing outside the scope; a search, with and without a path, returns no line of a
  page in the scope whose rule the agent does not pass (and read_file refuses it);
  delete_page's references and rename_page's rewrite stay inside the scope. Explicit
  paths outside (refused) and inside (answered) the scope, and a grant with no scope,
  are the controls.
- **t/unit/manager/415** (new): a signed-in editor confined to one domain's content
  root, and a confined token. `list` with no path and with `path=` lists the scope root
  alone; `pages` names no page outside the scope on either channel. Named folders and
  the unconfined callers are the controls.

With `lazysite-mcp.pl` and `Files.pm` put back to the base, t/unit/mcp/65 fails 6 of 8
(the two path subtests are the controls). With `lazysite-manager-api.pl` and `Files.pm`
put back, t/unit/manager/415 fails 3 of 6 (the named-folder subtest and the two set-up
steps pass).

# Not done

- **audit_site** also walked the whole site for a confined grant. It is confined by
  SM1311 (ruling 59), and a link outside the scope is reported as outside the scope.
- **list_pages applied no ACL to the titles it reads.** SM1312 (ruling 60) has it ask
  each page's rule first.
- **Protected content in the search (T-15)** is 0.16.4: the search still walks the
  document root only.
