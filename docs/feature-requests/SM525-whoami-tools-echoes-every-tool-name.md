---
title: "SM525: whoami.tools echoes every tool name"
subtitle: "An authenticated caller sees the whole tool vocabulary in whoami while tools/list shows only what its capabilities allow."
brand: plain
standard-margins: true
status: candidate
status-note: "FOUND 2026-08-25 by the mcp structural review, PROVEN by probe tmp/mcp-probe-anomalies.t; class: security-confidentiality (low); recommended timing: 0.10.33. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. _tool_names() in lazysite-mcp.pl ignores the session's capabilities, so whoami.tools lists every tool name for any authenticated caller, while tools/list for the same session filters by caps (SM196). Two answers to 'what can I call' disagree, the SM353 / lint-57 class. Derive the whoami list from tool_list($caps) and pin it with an assertion in unit/mcp/01."
---

# The finding

`whoami.tools` echoes every tool name to any authenticated caller, while
`tools/list` filters by capabilities (SM196). `_tool_names()` in
`lazysite-mcp.pl` ignores caps altogether. The sensitivity is low, but the
two answers to "what can I call" disagree – the same class as SM353 and
lint 57.

# Why it matters

Security-confidentiality (low): a caller granted a narrow capability set
still learns the names of tools outside its grant. The engine has one
filtered answer already and should give it everywhere.

# The proving test

From the table row: derive from `tool_list($caps)`; assertion in
unit/mcp/01 – for a narrowly granted session, `whoami.tools` names exactly
the tools `tools/list` returns.

# Fix shape

Replace the body of `_tool_names()` with
`[ map { $_->{name} } @{ tool_list($caps) } ]` so `whoami` and
`tools/list` share one filtered source.
