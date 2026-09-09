---
id: SM803
title: "SM803: a .url file is not a redirect, and the practice document said it was"
subtitle: "One line in the authoring practice, inherited by the generated AI briefing every site installs: '.url files - a page that is a redirect'. They are not. A .url file fetches a remote body and renders it HERE, so an author following that line points one at an application and puts its HTML through the Markdown pipeline."
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED 2026-09-09 on claude/sm802-sm803-the-remapper-and-the-url-correction. Corrected at source in docs/practice/authoring-practice.md, which tools/import-field-practice.pl generates starter/docs/ai-briefing-practice.md from - so the line was wrong in the briefing shipped to every site. The replacement says what a .url IS, says plainly that it is not a redirect, and names the consequence of believing otherwise; it also states that the engine has no outward redirect at all, because that is the question the wrong line was being read to answer."
---

# The error

`docs/practice/authoring-practice.md` carried:

    - `.url` files - a page that is a redirect

`tools/import-field-practice.pl` generates `starter/docs/ai-briefing-practice.md`
from that file, so the line shipped in the AI briefing every site installs.

It is wrong. `process_url` fetches the remote body and renders it through the
normal pipeline (`processor:2719`, "Found .url - fetch remote content"); the
visitor stays on the site's own URL and sees the remote content as a page.

# Why it matters more than a wrong sentence usually would

It was found by somebody looking for an outward redirect, which the engine does
not have ([[SM802]]). This line is the one place the documentation appears to
offer one, so it is exactly what an author in that position finds - and
following it means pointing a `.url` at an application's HTML and putting that
HTML through the Markdown processor. The failure is confusing rather than
loud.

The correction says what a `.url` is, says plainly what it is not, names the
consequence, and answers the question the reader actually arrived with: there
is no outward redirect, and `aliases:` goes inward, always to the page carrying
it.

# Provenance

Noted inside `inbox/2026-09-09-site-url-remapper-plugin.md`, which asked for it
to be corrected. Verified against `process_url` before accepting.
