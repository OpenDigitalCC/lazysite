---
id: SM797
title: "SM797: the static serve refuses what is source rather than asset"
subtitle: "Security review, 0.13.8. _serve_content_static hands out raw bytes for any file with a trailing-alphanumeric extension and has no denylist, while DAV - the surface an operator reaches - has @DANGEROUS_EXT. On a site with an ACL store or a per-domain content root, /<page>.md.md returns the markdown source including drafts, and stray .bak/.swp/.conf/.pl files are served verbatim."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-09-11. The ruled half - the collapse in sanitise_uri and the belt in _serve_content_static - shipped first. The third question, whether the shipped front ends grow to match, was answered by the 0.13.13 plan (N13-09), and built as a HAND-OFF rather than a deny: every shipped front end (the ten Apache templates, Hestia's two proxy templates, both nginx examples) and the generated per-domain rules send the engine's source types to the engine whether or not the file exists, so the answer is the engine's everywhere - /about.md renders /about, a backup or a key is not found, and a 403 never confirms that a file exists. A deny would have been a second copy of the decision, answering differently from the engine on the same site depending on whether it had an ACL store. The list is %STATIC_DENY less .shtml/.shtm (Apache expands a legacy SSI page through mod_include), pinned in all eighteen places by t/lint/131 and driven through real Apache and nginx by t/integration/81. The .brief-only FilesMatch and nginx deny it replaces are gone. The one-rule front doors needed nothing: they already hand a static to the processor, where %STATIC_DENY answers. Existing vhosts take it when re-rendered (lazysite-apache-vhost, lazysite-nginx-vhost, or a Hestia domain rebuild)."
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
