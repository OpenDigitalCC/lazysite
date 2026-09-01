---
id: SM714
title: MCP over HTTP lists two tools where describe_capabilities describes many
raised: 2026-09-01
raised-by: edge-testing agent (0.11.9 token-surface regression)
area: mcp
status: candidate
---

# What happens

`tools/list` over the MCP-over-HTTP bearer path returns exactly two tools -
`describe_capabilities` and `whoami` - with no `nextCursor`, so nothing suggests
the listing is partial. `describe_capabilities` then describes many MCP tools
that capabilities "unlock".

The reporter's conclusion is the one any cold agent would reach: **the MCP
surface looks nearly empty.**

# What needs deciding before anything is built

Whether this is a defect or the design. If the full tool set is deliberately
only on the wired OAuth connector, and the HTTP-bearer path is discovery-only,
then the behaviour is right and the **documentation** is the defect - nothing at
`/.well-known/ai-partner` says so, and a partner agent has no way to learn it
except by asking someone.

If it is not deliberate, it is a listing bug.

# Related, and probably the same conversation

SM653 shipped in 0.11.9 so that `whoami` says WHERE a tool can be called rather
than only that it exists - on the reasoning that a listing naming a tool without
naming its reachable paths tells a caller it has an access it may not have.
**This is the same problem from the other end**: a listing that omits tools the
caller could reach tells them the opposite falsehood.

Whichever way this is decided, it should be decided consistently with SM653.

# Cheapest useful step

State the answer in `/.well-known/ai-partner`. If the two-tool listing is
correct, one sentence there converts a dead end into a signpost, and it is worth
doing before any listing change.
