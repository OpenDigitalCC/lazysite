---
title: "SM360 - list_files cannot say why an entry is private"
subtitle: "`store: private` on all 31 entries, `read: null` on all 31 - because the rule is on the folder. So the listing cannot distinguish an entry gated by its parent from one carrying its own rule, which is exactly the stale-per-file-ACL case the runbook warns about."
brand: plain
status: shipped
---

# SM360 - the right answer to one question, and nothing for the other

## What was measured

edge 0.10.12. A folder holding 31 files, protected with a **folder-level**
rule:

```
set_permissions {"path":"/zz-surv/","read":["nobody-zz"]}
  -> {"content_moved":1,"ok":1,"acl":{"owner":"claude-code","read":["nobody-zz"]},"path":"zz-surv"}

list_files {"path":"/zz-surv/"}
  -> 31 entries
     store distribution : private x31
     read  distribution : null    x31
```

`store: private` is correct on every entry and is the useful half - it is
how [[SM286]]'s move-based protection is confirmed from a listing, and it is
what proved the move had happened during the four-surface pass when 23 of 31
files were still serving from a front-end cache.

`read: null` is also correct, literally: no entry has its own read list. But
it is the same value an unprotected file returns, so the field cannot
distinguish:

```datatable
columns: Situation | `store` | `read` | Distinguishable?
widths: 5.6cm | 1.8cm | 1.6cm | X
bold: 1
tone: medium
---
Gated by a rule on its folder | private | null | no
Gated by its own rule | private | `[...]` | yes
Not gated at all | public | null | yes
Folder rule removed, own rule left behind | private | `[...]` | yes, but only per file
```

## The case this is for, and it is one the runbook already warns about

From this instance's own test runbook:

> Check the per-file entry as well as the folder one: a folder-level
> `acl-remove` leaves a per-file ACL untouched, so a page can keep gating
> after its section is unprotected. `list_files` shows each entry's own
> `read` list and its `store` (`public` or `private`), which answers both
> questions at once and is the fastest way to see whether a move actually
> happened.

It answers the second question. For the first it returns `null` whether the
entry has no rule or is governed by one above it - so an operator looking at
a folder they have just unprotected, and finding one file still private,
cannot see from the listing *why*. They have to call `get_permissions` per
file, on the path, and on each parent, to reconstruct it.

That is the exact shape of thing that makes an operator conclude protection
is unpredictable. The information exists; the listing does not carry it.

## The fix

Name the rule in effect per entry:

```
{ "name":"probe.png", "store":"private", "read":null,
  "governed_by":"zz-surv" }

{ "name":"secret.pdf", "store":"private", "read":["alice"],
  "governed_by":"zz-surv/secret.pdf" }
```

`governed_by` naming the ACL key actually resolving for that entry answers
both questions in one call, and makes the leftover-per-file case visible in
the listing rather than needing a call per file. An entry whose
`governed_by` is its own path when the folder is unprotected is the stale
rule, readable at a glance.

Worth deciding alongside: whether `read: null` should stay `null` on an
entry governed from above, or echo the effective list. Echoing is friendlier
and riskier - a caller could not then tell whether the rule is the entry's
own, which is the distinction being added. Keeping `read` as the entry's
**own** rule and adding `governed_by` for the effective one keeps them
separable.

## What NOT to change

`store` is right as it is - a **label**, never a path. [[SM286]] was
explicit that the listing must not disclose the private store's location,
and `governed_by` should be an ACL key relative to the docroot for the same
reason, not a filesystem path.

## Verification

- Every entry reports the ACL key in effect for it, whether that key is its
  own path or an ancestor.
- A folder-level rule produces entries whose `governed_by` is the folder.
- After `acl-remove` on the folder, a file that kept its own rule is visible
  as such from the listing alone, with no per-file call.
- `read` continues to mean the entry's **own** rule.
- Neither field discloses a filesystem path or the private store's location.
- The `audit_site` `acl_keys_matching_nothing` check still finds keys
  matching no file - this adds the inverse view, files matching a key, and
  should not replace it.

## Related

[[SM286]] (protection as a move, and `store` as a label not a path),
[[SM292]] (a listing filtered on a trailing slash so it showed only
hand-edited keys - the precedent for an ACL view that answered the wrong
question), and
`inbox/four-surface-residual-observations-2026-08-17.md`.
