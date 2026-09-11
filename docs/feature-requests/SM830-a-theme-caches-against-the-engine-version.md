---
title: "SM830: a theme's assets cache against the engine version, not the theme's"
subtitle: "Sites agent, 1311E-02, 2026-09-10: the mirrored file was regenerated correctly and the page went on serving the old colours, because the only fingerprint in the URL is the release number"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-09-11, the engine's half; the catalogue's half is the layouts agent's and is filed to their inbox. THE TOKENS LINK (2026-09-10) keys on its own file's content hash. THE REST: the mirror writer (Manager::Themes::_write_mirror_fingerprint) records one fingerprint over every file it writes - by relative name and content, binary assets included - in the staged mirror, so it switches in with them; the render exposes it as [% theme_version %], so a layout links main.css?v=[% theme_version %]. It moves when the bytes do and not on a re-activation of identical files, the tokens key's property. A mirror written before this has no fingerprint until its next activation, and the key there is the engine version, which is what those links carried before. Computed at write time rather than on render, because hashing a theme's fonts on every uncached render is cost with no benefit. Pinned by t/unit/manager/179. THE CATALOGUE'S HALF: the layouts in lazysite-layouts link their own assets with their own ?v= and need to use [% theme_version %]; the engine cannot make that change for them."
---

# The measurement

Reported against 0.13.11 with the file state verified at each step, which is
what makes it a cache finding rather than a generation one:

| What | Value |
| --- | --- |
| `theme.json` colours after the edit | bg `#101820` |
| The mirrored file at that URL | contains `#101820` - **regenerated correctly** |
| The page, via its cached `<link>` | `rgb(251, 247, 239)` - the OLD colour |
| The same file fetched fresh and injected | `rgb(16, 24, 32)` - the new colour |

**Generation is right. The cache key is wrong.**

# Why

The link is emitted as `theme-tokens.css?v=<engine version>` - so within one
release the query string is constant, and a browser that has the URL has no
reason to ask again. Every theme edit inside a release is therefore invisible to
anyone who loaded the page before it.

The `?v=` convention is right and is used across the engine's assets; it is the
*value* that is wrong here. For engine-shipped CSS the engine version is exactly
the right fingerprint, because the engine version is what changes it. A theme is
authored on a different clock.

# The shape

Fingerprint the theme's own state: the mirrored file's mtime, or a content hash
of it. Either changes when and only when the theme changes, which is the
property `?v=` is supposed to carry.

A content hash is the stronger answer - mtime moves when a mirror is rewritten
with identical content, which would expire caches for no reason on every
activation. The mirror is already written by one path, so there is one place to
compute it.

# Not only theme tokens

The same question should be asked of every asset the mirror writes, because they
are all authored on the theme's clock rather than the engine's. Answering it for
`theme-tokens.css` alone would leave the same defect in the files beside it.

# Related

This is the **third finding in two runs** on one question: what refreshes an
asset, and when. [[SM820]] (a theme that was never activated linked nothing - the
mirror gap), and the known WebDAV gap recorded there (a theme uploaded after the
last activation has no mirror until the next one). Those are about a mirror that
does not exist; this is about one that does and is not reached.

Worth treating together rather than one at a time, because an operator
experiences all three as "I changed the theme and the site did not change".
