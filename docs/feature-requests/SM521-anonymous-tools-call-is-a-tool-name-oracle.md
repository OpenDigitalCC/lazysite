---
title: "SM521: anonymous tools/call is a tool-name oracle"
subtitle: "An unauthenticated caller learns which tool names exist, one probe at a time, undoing the hidden vocabulary SM210 established."
brand: plain
standard-margins: true
status: candidate
status-note: "FOUND 2026-08-25 by the mcp structural review, PROVEN by probe tmp/mcp-probe-anomalies.t; class: security-confidentiality; recommended timing: BEFORE-BETA-PUBLISH. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. With no bearer, tools/call with a bogus name answers HTTP 200 / -32602 'Unknown tool' while a real name answers 401, because the unknown-tool check at lazysite-mcp.pl 3252 runs before verify_bearer at 3254. SM210 hid the tool vocabulary from an anonymous tools/list; this leaks it back by enumeration. The fix is to swap the two statements so authentication runs first, and to add an anonymous-probe assertion to unit/mcp/01."
---

# The finding

Anonymous `tools/call` answers -32602 "Unknown tool" for a bogus name and
401 for a real one (`lazysite-mcp.pl 3252-3254`): the unknown-tool check
runs before `verify_bearer`. With no bearer, `name => 'zzz'` gets HTTP 200
and a JSON-RPC invalid-params error, while `name => 'write_file'` gets
401. The two answers differ only by whether the name is in the table, so
the table can be read one probe at a time.

# Why it matters

Security-confidentiality: SM210 deliberately withheld the tool vocabulary
from unauthenticated `tools/list`. This path hands the same information
back to an unauthenticated caller through a different door.

# The proving test

From the table row: swap the two statements (auth first); unit/mcp/01
"unknown tool -> invalid params" already authenticates and is unaffected;
add an anonymous-probe assertion – an unauthenticated call with an unknown
name answers 401, the same as a known one.

# Fix shape

Swap the unknown-tool check and `verify_bearer` in the `tools/call` branch
so authentication is decided before the tool name is looked up. The
existing authenticated assertion in `t/unit/mcp/01` keeps passing.
