---
title: "SM832: plugin-list's id is not the key plugin-read accepts, and the error sends you to the listing"
subtitle: "Sites agent, 1311E-06, 2026-09-10: the rejection says 'call plugin-list for the ids this site has', and plugin-list's id field is precisely the value it just rejected"
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-09-10. The listing's `id` is a key the reader accepts. NOT BY FILENAME: twelve of fourteen plugins publish their stem as their id, but audit.pl publishes link-audit and log.pl publishes logging, so plugins/<id>.pl is only a guess and is confirmed against the id the plugin itself declares before it is used; an unconfirmed guess falls through to asking every plugin. A filename stem that is nobody's id is refused rather than accepted by accident. The refusal now names the fields to pass - `id` or `_script` - instead of pointing back at the listing. Tested against the REAL shipped plugins in t/unit/manager/170, including both that break the filename rule. The wider sweep the filing suggested - other listing/reader pairs with the same mismatch - was not performed."
---

# The loop

`plugin-list` returns:

```json
{"id": "bad-url-blocker", "_script": "plugins/bad-url-blocker.pl"}
```

`plugin-read&plugin=bad-url-blocker` answers:

> no plugin 'bad-url-blocker' is installed - **call plugin-list for the ids this
> site has**

The value that works is `plugins/bad-url-blocker.pl`. So the error names the
listing, the listing offers `id`, and `id` is the thing the error rejected. A
caller who does exactly what the message says arrives back where they started.

Both spellings behave identically, so this predates [[SM817]] and is not a
regression from it.

# What is actually wrong

A record that publishes two identifiers, one called `id`, where the one called
`id` is the one the API does not take. Whatever the internal key is, `id` is the
word that promises "this is what you pass back".

# The shape

Preferred: **`plugin-read` accepts the `id`.** The listing already knows both
values, so the reader can resolve a bare id to its script the same way the
listing produced it. The path form keeps working, so nothing that already
calls it breaks.

Failing that, the listing stops calling the path `_script` and the bare name
`id`, and the error names the field to pass rather than the action to call.
That is the weaker fix - it documents the trap instead of removing it - and it
is worth stating only because it is cheap.

Either way **the error message should name the field**, not just the action:
"call plugin-list and pass its `<field>`" is actionable where "call plugin-list
for the ids" is what produced the loop.

# Where else

Worth a sweep rather than a single fix: any listing/reader pair where the
listing's `id` is not the reader's key has the same defect. This one was found
because a tester followed the error message literally, which is the behaviour we
should assume rather than the exception.

# Related

[[SM817]] (the action rename - this survives it unchanged, in both spellings).
