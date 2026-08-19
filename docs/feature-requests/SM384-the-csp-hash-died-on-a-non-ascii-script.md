---
title: "SM384: the CSP hash died on any non-ASCII character in an inline script"
subtitle: "Digest::SHA operates on bytes and dies on a wide character. A TT-rendered response is a character string, so one non-ASCII character inside an inline <script> aborted the response mid-headers - and the manager, whose own scripts carry non-ASCII, was down in the DEFAULT mode."
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED 2026-08-19 on claude/sm384-hash-the-bytes. RELEASE BLOCKER: found by the lazysite-analysis agent driving a real browser against a real manager, while the 0.10.15 cut was running. The cut was stopped before tagging, so no version was burned. Both pinned copies now hash the UTF-8 BYTES the browser receives. Two tiers: above U+00FF it DIED (200 with an empty body); U+0080-U+00FF hashed the latin-1 byte instead of the two UTF-8 bytes and the script was silently refused."
---

# What was broken

`Digest::SHA` operates on bytes and **dies on a wide character**. A
TT-rendered response is a **character** string, so a single non-ASCII
character anywhere inside an inline `<script>` aborted the response
mid-headers:

```
Wide character in subroutine entry at lazysite-processor.pl line 6620
```

The browser receives a **200 with an empty body**.

::: widebox
**The manager was down in the default mode.** Its own scripts carry
non-ASCII, and `report-only` is the default - so every manager page was
affected in every mode except `csp: off`. The feature that was supposed
to be the safe rollout setting was the one that broke it.
:::

# Two tiers, and the second is quieter

```datatable
columns: Range | Behaviour
widths: 5.0cm | X
bold: 1
tone: medium
---
Above U+00FF | **Dies.** Response aborts mid-headers; 200 with an empty body
U+0080-U+00FF | **Does not die.** Hashes the LATIN-1 byte where the browser hashes the two UTF-8 bytes it received, so the hash does not match and the script is refused with nothing anywhere to say why
ASCII | Correct
---
```

# Why no test saw it

Nothing in the suite renders a manager page end to end through the real
layout, and **every fixture's inline script was ASCII**. The shipped
catalogue was clean too - by luck rather than design, and one non-ASCII
character in a layout or in page content would have taken a site down
the same way.

It was found by driving a real browser against a real manager. That is
the second time in this line that a defect was invisible to everything
except a browser, and the first was the reason the browser rig existed
at all.

# The fix

Copy the body, `utf8::encode` if it is a character string, hash the
bytes. Three lines, in both pinned copies.

# Verification

- Every case above ASCII survives, in both copies, and matches a hash
  computed from the UTF-8 bytes independently.
- Reverting to hashing characters fails the test on the dying cases
  **and** on the silent-mismatch case.
- The fixture asserts it really contains a non-ASCII character. The
  first version of the test used single-quoted `\x{e9}`, which is a
  literal backslash sequence - so the fixture was secretly ASCII and
  the whole file passed against the unfixed code.

# Related

[[SM352]] (which introduced the hashing), [[SM380]] (the rollout mode
whose default made this reach everyone).
