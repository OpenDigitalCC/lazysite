---
id: SM851
title: "SM851: a submission store at a handler's own path was readable over MCP without read_submissions"
subtitle: "The MCP carve-out pass learned which directories are submission stores before the request's context told the modules where the site is. Under CGI every request is the first, so only the default store was carved out, and a store at a file handler's `path:` was read through read_file by a content partner."
brand: plain
standard-margins: true
status: shipped
raised: 2026-09-11
raised-by: engine (found building 0.13.13)
area: security
status-note: "SHIPPED 2026-09-11 on claude/n13-mop-up. setup_context now runs before the carve-out pass. Reproduced first, as a real CGI request against a site whose file handler stores to data/inbox: an mcp + manage_content partner read the store through read_file on this branch AND on main, so the gap predates SM842, which only made it audible. t/unit/mcp/25 pins it and fails without the fix."
---

# What was found

SM268 H1 made every file handler's configured `path:` a submission store, so the
read gate (`Manager::Common::carveout_refusal`) asks for `read_submissions` there
exactly as it does for the default `lazysite/forms/submissions`. The gate learns
those paths from `Manager::Plugins::submission_store_dirs`, which reads
`handlers.conf` - through module globals that `setup_context` sets.

In `lazysite-mcp.pl` the carve-out pass ran **before** `setup_context`. The control
API sets the same globals at file scope, so it was unaffected. On MCP, under CGI,
every request is its process's first: the pass found no docroot, read no
`handlers.conf`, knew only the default store - and a partner holding `mcp` and
`manage_content` but not `read_submissions` read `data/inbox/contact.jsonl`
through `read_file`, contents and all.

# How it came to light

As a log line. SM842 gave the handler config one reader, and that reader says
when it cannot find `handlers.conf` - where the old parser in `Manager::Plugins`
failed silently. The MCP test suite printed `no docroot: cannot locate
handlers.conf` after every tool call. The warning was the symptom of a gate that
had been quietly narrower than it claimed since SM268 H1.

`Manager::Common`'s own comment on the lookup reads "fails SAFE and QUIET: if the
handler config cannot be read the answer is the default prefix alone". For a
configured store that answer is open, not safe - the quiet part was the defect.

# Reproduced before fixing

`t/unit/mcp/25-a-configured-store-is-carved-out-on-the-first-call.t` drives MCP as
a real CGI request, one process per call, because that is the condition. On this
branch before the fix and on `main`, the configured store's contents came back;
the default store was refused. With `setup_context` moved ahead of the pass, both
are refused, naming `read_submissions`.

# Exposure

A site with a **file handler whose `path:` is set** (a store outside
`lazysite/forms/submissions`), and an MCP partner granted `manage_content`
without `read_submissions`. The default store was never exposed.
