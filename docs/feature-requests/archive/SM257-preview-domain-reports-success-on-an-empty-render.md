---
title: "SM257 - preview_domain reports success when the render produced nothing"
subtitle: "The preview shells the processor and returns whatever came back. An empty body, a processor that died, and a genuinely blank page are all reported as ok:1 with no way to tell them apart."
brand: plain
status: shipped
status-note: "IMPLEMENTED in the 0.10.4 edge line (2026-08-09, commit e9df3c8). Found 2026-08-08 while writing behaviour coverage for the 0.10.3 MCP tools (t/unit/mcp/14-new-tool-behaviour.t). The fixture could not produce a rendered body, and the tool reported success anyway - so the test could not assert the thing the tool exists to do. Same family as SM247 and SM256: success reported for work that did not happen."
---

# SM257 - preview_domain reports success on an empty render

## Why

`preview_domain` exists so an operator or agent can CHECK a domain they have just
configured, before DNS or TLS point at it. Its whole value is answering "does
this domain actually serve its own content" without waiting for the world to
catch up.

It shells the processor and returns the output with the CGI headers stripped:

```perl
my $output = qx($^X \Q$processor\E 2>/dev/null);
$output =~ s/\A.*?\r?\n\r?\n//s;    # strip CGI headers
...
return { ok => 1, host => $host, html => $output };
```

`ok => 1` is unconditional. Nothing checks the child's exit status, and `2>/dev/null`
discards whatever the processor said about why it failed. So:

- the processor dying,
- the processor running and emitting nothing,
- the header-strip regex failing to match and eating the body,
- and a domain that genuinely renders an empty page,

are one indistinguishable answer: `ok:1` with `html` empty or wrong.

## Why it matters more here than elsewhere

A tool whose entire purpose is verification must not report success without
verifying. The failure is quiet and confidently wrong in the same direction: an
agent configuring a new domain calls this to confirm the work, gets `ok`, and
reports the domain as good. The operator finds out when the DNS lands.

This was found because a test could not be written against it. That is worth
recording on its own - the assertion "the preview shows THIS domain's content"
is the one thing the tool promises, and there was no way to make it hold or fail
meaningfully.

## What to do

- Capture the processor's exit status and stderr instead of discarding them.
  A non-zero exit is a failed preview: `ok:0` with the condition named.
- Treat an empty body after header-stripping as a failure, not a success -
  the processor always emits something for a real page, so nothing is the
  signature of a broken render, not of a blank one.
- Distinguish "the header strip found no blank line" from "the body is empty";
  they have different causes and different fixes.
- Keep the successful shape unchanged (`ok`, `host`, `html`) so callers that work
  today are unaffected.

## Tests

- A registered domain with real content: `ok:1`, `html` contains that domain's
  content and NOT the primary's (the assertion
  `t/unit/mcp/14-new-tool-behaviour.t` had to leave out).
- A processor that exits non-zero: `ok:0`, the error names the condition.
- A processor that emits nothing: `ok:0`, distinct from the above.
- Output with no CGI header block: reported, not silently returned as an empty
  body.

The first of these needs a fixture with enough installed engine for the processor
to render - which the current MCP unit fixtures do not have. That may make this
an integration test rather than a unit one.

## Scope

`domain_preview` in `lib/Lazysite/Manager/Domains.pm`. Both the `preview_domain`
MCP tool and the `domain-preview` control-API action route through it, so one fix
covers both surfaces.
