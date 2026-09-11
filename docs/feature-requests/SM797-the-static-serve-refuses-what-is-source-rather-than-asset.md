---
id: SM797
title: "SM797: the static serve refuses what is source rather than asset"
subtitle: "Security review, 0.13.8. _serve_content_static hands out raw bytes for any file with a trailing-alphanumeric extension and has no denylist, while DAV - the surface an operator reaches - has @DANGEROUS_EXT. On a site with an ACL store or a per-domain content root, /<page>.md.md returns the markdown source including drafts, and stray .bak/.swp/.conf/.pl files are served verbatim."
brand: plain
standard-margins: true
status: partial
status-note: "PARTIAL 2026-09-11: THE RULED HALF IS BUILT. The collapse in sanitise_uri - the actual mechanism - strips every trailing page extension, so /page.md.md renders the page under its draft and access rules instead of serving the markdown; and the denylist in _serve_content_static - the belt - refuses the engine's own inputs (md url brief), editor and backup litter, config and keys, and every type the upload surface refuses, checked on the requested AND the canonical path. json stays servable, by the ruling's own argument against lists that silently stop a site serving a type. THE FIRST BUILD DID NOTHING: the hash was a file-scope `my` initialised below the point the request is dispatched from, so it was empty when every request ran; an end-to-end test caught it, and the hash is filled at compile time. Each half is pinned on its own because they overlap: with the collapse reverted, the denylist still refuses md, so a request-level test cannot see the collapse is missing. WHAT REMAINS: this filing's third question, never ruled - whether the shipped Apache template's FilesMatch (which denies only .brief) grows to match. It matters: on a site with no ACL store and no content root the web server serves statics itself, and none of this code runs."
---

# The finding

`_serve_content_static` serves raw bytes for any trailing-alphanumeric
extension, content type from `%STATIC_CT` or `application/octet-stream`, with
no extension check. DAV, which is the authenticated surface, has
`@DANGEROUS_EXT`; the anonymous one has nothing.

The branch runs when the request is for a per-domain content root or the site
has an `acls.json`, so it is the multi-domain and access-controlled sites - not
the simplest ones - that are exposed.

`sanitise_uri` strips a page extension once, so `/<page>.md.md` maps back to
`<page>.md` on disk and is served as source. A `draft: true` page's markdown,
and the body of a page whose front matter names an api handler, come back as
text. `.url.url` reveals an upstream. Editor artefacts left in a content
directory - `.bak`, `.swp`, `.conf`, `.pl`, `.json` - are served verbatim.

The shipped Apache template compounds it: its `FilesMatch` denies `.brief` and
nothing else.

# Why this is filed rather than built

**Which extensions is a policy decision, and the wrong list is worse than
none** - a denylist that misses `.orig` while an operator believes it is
covered is the shape this project has met before. Three questions belong to the
release manager:

- Denylist or allowlist? DAV denies; an allowlist of servable types would be
  the stronger answer and the more disruptive one, because a site serving a
  type nobody listed stops serving it.
- Does the double-extension collapse (`/<page>.md.md` -> `<page>.md`) get
  fixed at `sanitise_uri` as well, which is the actual mechanism for the source
  disclosure and is not an extension question at all?
- Does the shipped Apache template's `FilesMatch` grow to match, and does that
  make a deployed site's behaviour change on upgrade?

Small to build, and none of it is mine to decide.

# Provenance

`inbox/2026-09-08-static-serve-source-and-backup-disclosure.md`. Accepted as
described; the absent denylist was read here.

## Ruled 2026-09-09 by the release manager

**Denylist, plus the `.md.md` collapse in `sanitise_uri`.** The collapse is the
actual mechanism and is the fix; the extension denylist is the belt. An
allowlist was considered and refused: it is stronger, and it stops a site
serving an unlisted file type on upgrade - silently, and discovered from the
field rather than from the gate.
