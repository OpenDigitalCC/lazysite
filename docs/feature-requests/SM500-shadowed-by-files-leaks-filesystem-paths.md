---
title: "SM500: shadowed_by_files returns absolute filesystem paths over MCP"
subtitle: "regenerate_registries reports a shadowing file at a non-docroot content root by its full server path - the one thing no partner-facing surface may say."
brand: plain
standard-margins: true
status: shipped
status-note: "FOUND 2026-08-24 by the SM483 reproduction rig, as a side finding: on a multi-domain fixture, regenerate_registries' shadowed_by_files carried '/tmp/<dir>/sites/alpha/sitemap.xml' - an absolute filesystem path - in an MCP response. The mechanism is Files.pm's report assembly: a shadowing file under the DOCROOT is trimmed to a site-relative path, and one under any OTHER content root falls through as $root/$out, which is absolute. Partner-facing surfaces never disclose server paths (t/integration/33's rule); this is the same class on a rarely-taken branch - non-docroot roots are exactly the multi-domain case, which is also where SM483's frozen-registry conditions live, so the leak surfaces precisely when an operator is debugging registries. FIX SHAPE, S: trim against the reporting root and emit the domain-relative path (with the root named separately if needed); extend the t/integration/33-family assertion to cover this response. Not scheduled; joins the queue. SHIPPED 0.10.30 (9db1d4a) - the status flip and the changelog hunk were both lost to branch surgery and restored at the post-cut sweep."
---

# The finding

`regenerate_registries` reports a pre-existing file that shadows a generated
registry. For a shadowing file under the docroot the path is trimmed
site-relative; for one under any other content root the fallback emits
`$root/$out` - the absolute server path - in an MCP response.

# Why it matters where it lives

Non-docroot content roots are the multi-domain case, which is where SM483's
frozen-registry mechanisms live - so the leak surfaces exactly when an
operator or agent is debugging a registry, on the surface built for them.

# Fix shape (S)

Trim against the reporting root; emit the domain-relative path, naming the
root separately if the response needs it. Extend the no-filesystem-paths
assertion family (t/integration/33) to this response.
