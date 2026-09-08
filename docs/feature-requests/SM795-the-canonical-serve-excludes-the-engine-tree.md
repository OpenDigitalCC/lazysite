---
id: SM795
title: "SM795: the canonical serve excludes the engine tree, as the include path already does"
subtitle: "Security review, 0.13.8, VERIFIED: the engine-tree block is a test on the REQUEST STRING, and the canonical file serve confines only to the docroot boundary without excluding lazysite/ on the resolved path. In the inside-docroot layout a symlink whose name does not begin with /lazysite resolves into the engine tree and is served - the session secret returned as an image. _resolve_include, forty lines of the same file away, does it correctly."
brand: plain
standard-margins: true
status: partial
status-note: "THE PROCESSOR HALF BUILT 2026-09-08 on claude/secrev-wild-request-path: _serve_content_static now refuses a resolved path inside LAZYSITE_DIR, the same test _resolve_include makes, so the exclusion is on the CANONICAL path in both sinks rather than on the request string in one. WHAT REMAINS is the DAV half - resolve_under_docroot confines to the docroot boundary the same way, and DAV blocks the engine tree by request rel rather than by resolved path. It is a second module with its own resolver, its own authorise() path and its own tests, so it is left as its own change rather than folded into a processor fix."
---

# The finding

The confinement rule this project already holds (SM268 / SEC-2026-07 H3) is:
blocklist on the **canonical resolved path**, never on the raw request string.
Two of the three sinks do not.

- The engine-tree block is a literal request-string test:
  `if ($uri eq $LAZYSITE_URI || index($uri,$LAZYSITE_URI.'/')==0) { forbidden() }`
  (`processor:2245`). It answers about the string the client sent.
- `_serve_content_static` (`:3131-3136`) resolves the real path and then checks
  only that it is under the docroot or the private root. **It does not exclude
  `$LAZYSITE_DIR`.** In the inside-docroot layout the engine tree is under the
  docroot, so a resolved path inside it passes.

The asymmetry is what makes this a defect rather than a judgement: forty lines
away, `_resolve_include` (`:4510-4513`) rejects a path that is
`_path_under( $real, $LAZYSITE_DIR )` with a comment explaining exactly why.
One sink of three had the rule.

A symlink is the way in - `/leak.png` resolving to `lazysite/auth/.secret` is
served as `image/png`. That needs a symlink in the content tree, which is why
this is Medium and not High, and it is a thing an author with file access, a
restored archive or a careless deploy can produce.

# What was built

`_serve_content_static` makes the same test `_resolve_include` makes, on the
resolved path, in addition to the boundary check. A file that resolves inside
the engine tree is not served, whatever its request path said.

# What was NOT built, and why it is separate

The review reports the same shape in DAV's `resolve_under_docroot`. That is a
different module with its own resolver, its own authorise() path and its own
tests, and DAV already blocks the `lazysite/` subtree by request rel - so the
gap there is the same canonical-versus-string question asked of different code.
It should be fixed, and reviewed, as its own change rather than folded into a
processor fix. Filed here so it is not lost.

# Provenance

`inbox/2026-09-08-static-serve-canonical-confinement-symlink.md`. Accepted: the
boundary check and the include path's correct version were both read here.
