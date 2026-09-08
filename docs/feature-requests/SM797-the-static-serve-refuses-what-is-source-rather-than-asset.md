---
id: SM797
title: "SM797: the static serve refuses what is source rather than asset"
subtitle: "Security review, 0.13.8. _serve_content_static hands out raw bytes for any file with a trailing-alphanumeric extension and has no denylist, while DAV - the surface an operator reaches - has @DANGEROUS_EXT. On a site with an ACL store or a per-domain content root, /<page>.md.md returns the markdown source including drafts, and stray .bak/.swp/.conf/.pl files are served verbatim."
brand: plain
standard-margins: true
status: candidate
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
