---
title: "SM461: the all-files history overview is broken, and it is in the wrong place"
subtitle: "It fails with a JSON parse error while the data behind it is fine. And seeing it at all requires granting the Files app - full read and write over content - to anyone who only needs to know what changed."
brand: plain
standard-margins: true
status: candidate
status-note: "FILED 2026-08-21 from the field, in two parts, and the SECOND is the reason to act. THE BUG: the 'Content history - all files' overview at the top of the Files app shows Loading... and then 'Error: JSON.parse: unexpected character at line 1 column 1'. THE DATA IS FINE - git-history-summary over the control API returns valid JSON on that site, 15,307 bytes, 131 files - so the fault is in the manager's request or its handling, not in the action. CONFIRMED IN THE SOURCE: the overview does fetch(...).then(r => r.json()).catch(e => 'Error: ' + e.message), with no status or content-type check, so ANY non-JSON body becomes a parse error attributed to the data. Column 1 is what JSON.parse says when handed something that is not JSON at all, usually HTML beginning with '<'; with a delay first that points at a timeout page, a login redirect, or an uncaught die. PARTLY IMPROVED ALREADY: SM445 taught the shared fetch wrapper to notice a 401 and say the session has expired, so that case is now diagnosed by a banner even though the panel still prints the parse error. A non-401 HTML body - a 500, a die, a proxy timeout - is still reported as if the JSON were malformed. Reproducing it needs a browser: every manager Files action is cookie-only, so the reporter could not make the failing call at all, and capturing the raw response body is the one-look answer. THE PLACEMENT IS THE OPERATOR'S POINT AND THE BETTER ONE. An all-files history overview is not a file operation - it is a report about the repository, sitting at the top of a file browser where nothing else shares its scope. content-history is ALREADY a plugin, in plugin-list with its own description and enable/disable, and it has no view; stats is the precedent for a plugin that owns one. THE ACCESS ARGUMENT IS THE STRONGEST PART: today, letting somebody see the history overview means giving them the Files app, which is full read and write over content. There is no way to say 'you may see what changed and when' without also saying 'you may edit anything'. An auditor or reviewer needs the first and not the second, and over-granting to satisfy a reporting need is how an estate acquires more editors than it meant to have. So the requirement is that seeing the history be grantable WITHOUT granting Files - analytics is the model, read-only, off by default, unlocking one view. Whether that is a new capability or an existing one extended is the release manager's call. KEEP AS IS: the per-file History panel. That one IS a file operation, it belongs beside the file, and its scope matches the app it sits in."
---

# Two separate things

```datatable
columns: | Says | Actually
widths: 4cm | 6cm | X
bold: 1
tone: medium
---
The panel | `Error: JSON.parse: unexpected character at line 1 column 1` | the data is valid JSON, 131 files, fetched successfully over the API
The placement | a file operation | a report about the repository, gated behind full content write
```

# The bug: a parse error standing in for a cause

```javascript
fetch(API + '?action=git-history-summary')
  .then(function(r) { return r.json(); })          // no status, no content-type
  .catch(function(e) { body.innerHTML = 'Error: ' + e.message; });
```

Any non-JSON body becomes a parse error attributed to the data. Column 1 is
what `JSON.parse` says when handed something that is not JSON at all - usually
HTML - and the delay before it points at a timeout, a login redirect, or an
uncaught die.

**Partly improved already**: SM445 taught the shared wrapper to notice a 401
and say the session has expired, so that case now gets a banner. A non-401 HTML
body is still reported as though the JSON were malformed.

Reproducing it needs a browser - every manager Files action is cookie-only -
and the raw response body is the one-look answer.

# The placement, which is the part worth acting on

An all-files overview is a report about the repository. It sits at the top of a
file browser where nothing else shares its scope. `content-history` is already
a plugin with its own description and enable/disable, and no view of its own.
`stats` is the precedent.

::: widebox
**The access argument is the strongest part.** Letting somebody see the history
overview today means granting the Files app - full read and write over content.
There is no way to say *you may see what changed and when* without also saying
*you may edit anything*.

An auditor or a reviewer needs the first and not the second. Over-granting to
satisfy a reporting need is how an estate ends up with more editors than it
meant to have.
:::

So the requirement is that the history view be grantable **without** granting
Files. `analytics` is the model: read-only, off by default, unlocking one view.
Whether that is a new capability or an existing one extended is a decision, not
a detail.

# Not proposed

Moving the per-file History panel. That one IS a file operation, it belongs
beside the file, and its scope matches the app it sits in.
