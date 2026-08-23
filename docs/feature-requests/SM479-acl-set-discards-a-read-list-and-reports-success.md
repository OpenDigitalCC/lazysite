---
title: "SM479: acl-set discarded a read list and reported success"
subtitle: "Every signal available to the caller said protected. The page was public"
brand: plain
standard-margins: true
status: shipped
status-note: "REPORTED FROM THE FIELD ON 0.10.26, and the right thing to look at first. TWO FAULTS, AND THE CAPABILITY WAS NEVER MISSING: (1) acl-set reads its lists from the JSON BODY, and a `read` sent in the QUERY STRING was silently dropped - while the symmetric mistake, a `path` in the body, has been REFUSED with a helpful message since SM306. One direction guarded, the other not. It now refuses read, write, owner and draft in the query, naming which was misrouted and where it belongs. (2) An owner with no read list is a LEGITIMATE rule that governs writes and leaves reading open - but paired with `content_moved` it produced a reply in which ok:1, an acl object and 'content moved out of the document root' all read as confirmation of protection. That combination now carries `reads_unrestricted` and a note saying anyone may still fetch the pages, in its own field rather than in `warnings`, because nothing went wrong. VERIFIED THAT THE WORKING ROUTE WORKS before answering: path in the query and read in the body stores the list, and t/integration/52 has asserted it since SM306. The field agent put path AND read in the body together, was correctly refused for the path, and reasonably concluded the route was closed. Five sabotages, all confirmed to fail t/integration/65. THE FIELD REPORT ALSO REVISES ITS OWN EARLIER AUDIT: the 2026-08-21 parity pass recorded acl-set as working on the evidence of ok:true plus an owner appearing - the same silent discard read as success. The check that would have caught it was an unauthenticated fetch afterwards, and that is the lesson worth keeping."
---

# What the caller saw

```
POST ?action=acl-set&path=/probe&read=@team

{"ok":true,
 "acl":{"owner":"claude-code"},
 "content_moved":1,
 "content_moved_note":"content moved out of the document root..."}
```

Then `GET /probe/` returned **200 with the page in full, to anyone**.

Seven spellings were tried -- `read=`, `readers=`, `read_groups=`, `groups=`,
`allow=`, url-encoded, `read[]=` -- and every one returned `ok:true` and left
the rule owner-only.

# Why it is worse than an unimplemented parameter

An operator asks for content to be restricted. The call returns **success**.
The response then says content was **moved out of the document root**, which
reads exactly like confirmation. The content really has moved. And the page is
still served to anyone who asks.

There was no signal anywhere that told the truth, which is why the same field
agent's earlier parity audit had recorded `acl-set` as working: `ok:true` plus
an owner appearing in the returned ACL. The check that would have caught it is
an **unauthenticated fetch afterwards** -- and that is the durable lesson here,
not the parameter routing.

# The two faults

```datatable
columns: Fault | Fix
widths: 7cm | X
bold: 1
tone: medium
---
A list sent in the query string was silently dropped | Refused, naming which argument was misrouted and where it belongs. The symmetric mistake -- a path in the body -- has been refused since SM306; one direction was guarded and the other was not
A rule with an owner and no read list restricts no reads, while the reply reads as protection | The reply now carries `reads_unrestricted` and says plainly that anyone may still fetch the pages
```

The second is not a bug in the rule. An owner with no read list governs
**writes** and leaves reading open; that is documented and defensible. The
defect was the combination of that rule with a success message about moved
content and nothing to distinguish the two outcomes.

# What was NOT wrong

The capability. `path` in the query with `{"read":[...]}` in the body stores
the list, and `t/integration/52` has asserted exactly that since SM306. It was
verified before this filing was written, rather than assumed from the report.

`reads_unrestricted` is deliberately **not** a `warnings` entry. Nothing went
wrong, and a caller filtering `warnings` for failures should not find a caveat
about a successful call sitting in it -- the same reasoning `content_moved_note`
was written under.
