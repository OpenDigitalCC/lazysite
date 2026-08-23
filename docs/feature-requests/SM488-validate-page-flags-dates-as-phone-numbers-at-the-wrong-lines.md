---
title: "SM488: validate_page flags ISO dates as phone numbers, and reports every line short by the front-matter length"
subtitle: "Two minor faults that compound into one the caller cannot diagnose from outside. Reported from the field on 0.10.26"
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED 2026-08-23, same day. BOTH HALVES: ISO dates (and datetimes) are stripped from the line before the phone pattern runs - only the date, not the line, so a real number beside a date still fires; and the line counter starts at the front-matter length plus the two fences, because _split_front_matter returns the front matter WITHOUT them. The reproduction is the field agent's page in shape: seven front-matter lines, three dates in the body, two inside filenames, zero phones - and a real number inserted at line 13 is reported at line 13. Five sabotages, all confirmed to fail t/unit/mcp/11, including an off-by-two that forgets the fences and a date strip that eats the whole line. ORIGINAL REPORT: REPORTED BY THE SITE AGENT 2026-08-23 while taking a baseline for SM481. validate_page returned three public-phone warnings on a page with no phone number and no run of seven digits anywhere. TWO FAULTS, EACH MINOR, UNFIXABLE TOGETHER FROM OUTSIDE: the public-phone check matches ISO dates - the page has exactly three dates and produced exactly three warnings, two of them the filenames of filings in the engine's own inbox, so any page citing a dated document trips it; and every reported line number is short by exactly the front-matter length - reported 15/58/59, actual 24/67/68, delta 9, nine lines of front matter. You open line 15, find a canonical link, and conclude the tool is broken - which is nearly right and completely useless, when the real answer is a date-matching regex that a correct line number would have made obvious in seconds. NOT UNIVERSAL: /docs/authoring and /lazysite-demo return zero warnings, so it fires only on pages carrying a date, which is why the ones that trip it look inexplicable. NOT A 0.10.27 ITEM: that cut is past its pre-cut pass and this is a diagnostic defect, not a data one. First for 0.10.28. Two fixes, one test each: the phone pattern excludes YYYY-MM-DD (and a dated filename), and the line number is offset by the front matter the checker already split off."
---

# What the caller saw

```
validate_page /data-test
  warning public-phone  line 15
  warning public-phone  line 58
  warning public-phone  line 59
```

No phone number on the page. No run of seven digits. Line 15 is a canonical
link.

# The two faults

```datatable
columns: Fault | Evidence
widths: 6cm | X
bold: 1
tone: medium
---
The phone check matches ISO dates | three dates on the page, three warnings; two are filenames of the engine's own inbox filings
Every line number is short by the front-matter length | reported 15/58/59, actual 24/67/68 - delta 9, and the front matter is 9 lines
```

# Why they are one filing

Separately each is a nuisance. Together they are a tool that points at the
wrong line for the wrong reason: the caller opens the reported line, finds
nothing resembling a phone number, and concludes the checker is broken. That
conclusion is nearly right and completely useless. A correct line number would
have put the date under their cursor and made the regex fault obvious in
seconds.

# Why it looks inexplicable

It fires only on pages carrying a date. `/docs/authoring` and `/lazysite-demo`
return zero warnings, so the pages that trip it have nothing visibly in common
with each other and nothing visibly wrong.
