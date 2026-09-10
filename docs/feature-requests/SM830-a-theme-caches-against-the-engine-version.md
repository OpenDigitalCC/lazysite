---
title: "SM830: a theme's assets cache against the engine version, not the theme's"
subtitle: "Sites agent, 1311E-02, 2026-09-10: the mirrored file was regenerated correctly and the page went on serving the old colours, because the only fingerprint in the URL is the release number"
brand: plain
standard-margins: true
status: partial
status-note: "PARTIAL 2026-09-10: THE TOKENS LINK IS FIXED. theme-tokens.css now carries ?v=<first 12 hex of the file's own sha256> instead of the engine version, so a changed theme is a changed URL and browsers refetch. A CONTENT hash rather than an mtime: activation rewrites the mirror, and an mtime key would expire every visitor's cache on every activation even with identical bytes. If the file cannot be read the engine version is the answer, so a cache key can never be what breaks a stylesheet link. Tested in t/unit/processor/19 including that identical bytes leave the key alone. WHAT REMAINS: the other assets a mirror writes (main.css and friends) are linked by LAYOUT templates, which live in the lazysite-layouts catalogue rather than this tree and choose their own ?v=. Closing those needs the engine to expose this fingerprint as a template variable and the catalogue to use it."
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
