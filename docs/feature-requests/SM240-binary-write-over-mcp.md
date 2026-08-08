---
title: "SM240 - An MCP agent cannot write a single byte of binary"
subtitle: "write_file takes a string and there is no base64 path anywhere in the connector. No webfont, no photograph, no favicon - which is why MCP-built sites reach for CDNs and hotlinks, and why favicons are made by hand afterwards."
brand: plain
status: candidate
status-note: "Reported by the sjm-claude-code site agent 2026-08-08 after repairing MCP-built work on theunited.fund, harmony2050.org, united.explore and edge.explore. Verified: the only occurrences of 'base64' or 'binary' in lazysite-mcp.pl are a tool description and a comment. The agent's framing is the important part - this is not agent error being corrected, it is one missing capability forcing a competent agent into a predictable bad workaround."
---

# SM240 - no binary write over MCP

## Why

`write_file` is documented as *"Create or overwrite a **text** file"* and takes a
string `content`. Verified: there is no base64 handling, no binary path, nothing
in `lazysite-mcp.pl` that could place a non-text byte. An MCP-only agent cannot
put a webfont, a photograph, a PNG or a `favicon.ico` on a site it otherwise has
full `manage_content` over.

The reporting agent's argument is the one worth keeping:

> Most of what I repair on MCP-built sites is not agent error. It is a small
> number of missing capabilities, each of which forces a competent agent into a
> predictable bad workaround. Close the capability and the workaround disappears.

This single gap explains three recurring repairs, each of which has been paid for
by hand more than once.

**Fonts arrive from a CDN.** An agent asked for a designed site needs typefaces.
With no way to upload a `woff2` it writes `@import url('https://fonts.googleapis.com/...')`.
Found on theunited.fund (Cormorant Garamond + Jost) and on every united.explore
monolith. This contradicts the standing no-CDN position directly - and on
theunited.fund it was doing so on a site whose subject is sovereign capital.

**Photography is hotlinked.** theunited.fund carried twelve
`images.unsplash.com` background URLs inline in the markup: third-party requests
on every page load, and a design that breaks when the remote changes.

**Favicons are always missing.** `favicon.ico` is binary, so an MCP agent cannot
create one, ever. This is why "no favicon" is near-universal on MCP-built sites,
and why the operator carries a standing instruction to make them by hand. A
capability gap, paid for repeatedly.

Every one of these is a rule the agent was told about and could not follow.
Documentation cannot fix an impossible instruction.

## What to build

A binary-capable write on the MCP surface. Two shapes, and the choice is not
obvious:

**`write_file` gains `encoding: "base64"`.** One tool, one mental model, and an
agent that already knows `write_file` needs no new discovery. The risk is that a
tool whose description says "text file" quietly growing a binary mode is the kind
of thing a reader misses.

**A distinct `upload_file` tool.** Self-describing, discoverable in the tool
list, and it can carry its own size and type semantics without complicating the
text path. The cost is a second way to write a file.

Recommend the second, on the grounds that discoverability is the whole theme of
this release line: an agent scanning a tool list should be able to see that
uploading is possible.

Either way it must:

- **Inherit the existing gates unchanged.** `manage_content` / `manage_themes`,
  the scope confinement, the `@DANGEROUS_EXT` blocklist, and the per-file ACL.
  Nothing here is a new privilege - it is the same privilege on a file type the
  channel cannot currently express.
- **Cap the size**, and say what the cap is in the refusal.
- **Reject a payload that does not decode**, rather than writing a corrupt file.
- **Not become a general file-transfer channel.** WebDAV exists for bulk work and
  is the right tool for a large initial build; this is for the handful of assets
  a conversational agent legitimately needs to place.

## Why it is not simply "use WebDAV"

An MCP-only partner has no WebDAV credential in hand - the connector is the whole
of its access. Telling an agent to use a channel it cannot reach is the same
category of instruction as telling it not to use a CDN while giving it no way to
host a font.

## Verification

- An MCP agent holding `manage_content` can place a `woff2`, a PNG and a
  `favicon.ico`, and the bytes round-trip exactly.
- The extension blocklist, scope confinement and ACLs refuse exactly what they
  refuse for a text write.
- An oversized payload is refused with the limit named; an undecodable payload is
  refused without writing.
- `describe_capabilities` reports the tool under the capability that unlocks it.

## Not in scope

- Any change to what `manage_content` permits.
- Image processing, resizing or format conversion. The agent supplies bytes.
- Replacing WebDAV for bulk transfer.
