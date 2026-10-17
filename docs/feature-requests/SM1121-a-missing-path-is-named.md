---
id: SM1121
title: "SM1121: a missing path is named as missing, for the operator as for everyone"
subtitle: "The SM1103 refusal for a content write with no query path, or a path only in the body, sat in a block the operator never enters; the operator was told the site root is a folder."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: edge-testing agent, 0.15.9 test plan (X1 / F-1)
area: manager
status-note: "SHIPPED on n624: lazysite-manager-api.pl (_refuse_unread_or_missing_path is also called for the operator); t/unit/manager/348 section 6."
---

# What happened

The 0.15.9 results file, row X1, signed in as the operator (cookie):

> a) {"path":"/zz-0159-x1.md","content":...}, no path in the query
>    400 kind is-a-folder: "'/' is a folder (the site root), and a save writes a file."
> b) no path anywhere
>    400 the same is-a-folder answer for '/'
>
> What fails: (a) and (b). A missing path is read as '/', so the caller is told
> they named a folder. They named nothing. In (a) the path they did send, in the
> body, is not mentioned at all. [...] neither answer says that `path` goes in
> the query.

And F-1: "a save with no query `path` is refused as "'/' is a folder" whether or
not the body carries a path. It should say the path is missing and that it goes
in the query, and name a body `path` when one was sent."

The cause is not the `$params{path} // '/'` default: SM1103's refusal looks at
the request before the default matters. It was called only inside the
`if ( !_operator() )` block of the cookie door, which the operator never
enters (the block's own comment says so). The operator's save went straight to
the handler, where the absent path had become '/' and `action_save` answered
the folder refusal. t/unit/manager/348 drove only a confined account
(`writer`, in a group holding `ui` and `manage_content`), so it measured the
confined door and passed while the operator, who was the field report, was
refused wrongly.

# What shipped

- The refusal is also called for the operator (an `else` to the capability
  block), after the same gates as before, so the cookie door has one answer
  whoever signs in. The token door already called it for every client.
- A `path` in the body beside an empty query `path` (`?path=`) is named as a
  body path too, not only beside an absent one.
- The audit detail of a content write with no path is `missing-parameter: path
  missing - path is required (in the query)`; the body-path case still audits
  the body path as the target. `path=/sites/` is still `is-a-folder`, and
  file-upload's empty path still means the root (t/integration/120).
- t/unit/manager/348 gains section 6, which drives the same requests as the
  operator (a member of a group carrying the `manager` flag): no path anywhere,
  a body path only, an empty query path beside a body path, a folder, and the
  other content writes (delete, mkdir, move, copy, lock) with no path. It fails
  15 assertions against `lazysite-manager-api.pl` restored from main.
