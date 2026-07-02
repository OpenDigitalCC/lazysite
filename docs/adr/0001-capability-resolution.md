# 0001 - Capability resolution: one shared helper, one recorded local copy

Status: Accepted
Date: 2026-07-02
Tags: auth, capabilities, sm095, architecture

## Context

SM095 made `Lazysite::Auth::Settings::caps_for($user)` the single capability
resolver: it resolves a user's group MEMBERSHIP from the groups file and
returns the union of capability grants. Three request-path gates, however,
already hold the requester's group list from request context (the login
session, the trusted X-Remote-Groups header) and only need the "does any of
these groups grant capability X?" half of the resolution. During the c2
manager-groups retirement those three gates each grew a private copy of the
groups-settings.json read - in `lazysite-processor.pl`, `lazysite-auth.pl` and
`lib/Lazysite/Auth/Acl.pm` - against a spec that promised one implementation.
The eight-dimension review (2026-07-01) flagged this as a
`divergent-implementation` finding, including a material inconsistency: the
canonical reader used a `:utf8` layer with `decode_json` (which expects raw
UTF-8 octets, so any non-ASCII content silently wiped the read to `{}`),
while the copies read raw bytes.

## Decision

1. `Lazysite::Auth::Settings` gains `groups_grant_cap($cap, @groups)` - the
   shared request-context flavour of the resolver. `caps_for` remains the
   membership-resolving flavour; the split (caller-supplied groups vs
   file-resolved membership) is deliberate and both share one settings read.
2. `lazysite-auth.pl` (login landing) and `lib/Lazysite/Auth/Acl.pm`
   (per-file ACL operator bypass) route through the shared helper. Acl
   localises `$Settings::AUTH_DIR` from its own `$DOCROOT` context so callers
   that only configure Acl keep working.
3. `lazysite-processor.pl` KEEPS a private copy. The processor's render path
   is deliberately module-free (documented in `docs/FEATURES.md`); importing
   the lib tree for one gate would break that property. The copy is marked
   with a reference to this ADR and must be kept in sync with the shared
   implementation.
4. JSON auth files are read as RAW OCTETS (`<:raw`) and decoded with
   `decode_json`, everywhere. The files are written as UTF-8 (character
   strings printed through a `:utf8` layer), so octets + `decode_json` is the
   correct pairing; `:utf8`-layer reads are the bug, not the convention.

## Rationale

The framework treats an unrecorded parallel implementation as a refusal-level
finding because the copies drift - which had already happened here (the
encoding split). Routing two of the three gates through the shared helper
removes the drift surface; the remaining copy exists for a recorded
architectural reason (module-free render path) and is now pinned to this
decision rather than being an accident.

## Consequences

- Non-ASCII group labels/descriptions (and user emails/comments) now survive
  the settings read on every path; previously they silently emptied the
  canonical read.
- Any future change to the capability-lookup semantics is made once in
  `Settings.pm` and once in the processor's marked copy; the marked copy is
  the known cost of the module-free render path.
- If the processor ever gains a lib dependency on its manager-gate path, the
  copy should be deleted in favour of the shared helper and this ADR updated.
