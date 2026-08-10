---
title: "SM267 - A Protected sections panel: see what is held back, and publish it in one click"
subtitle: "Section gating and draft-hide both work and are both hand-written JSON. An operator cannot see which parts of their own site are held back without reading a file."
brand: plain
status: candidate
status-note: "Carved out of SM181 on 2026-08-09 so that filing could close rather than sit at partial. SM181's ENGINE half is complete: a folder ACL entry gates a section's pages and assets, `draft: true` hides it (404, absent from every listing, editor preview), and removing the entry publishes atomically. What remains is the manager affordance - which is manager JavaScript, the area docs/MANUAL-CHECKS.md exists because the suite cannot reach."
---

# SM267 - a Protected sections panel

## Why

SM181 delivered both policies it asked for. A folder entry in
`lazysite/auth/acls.json` gates a section - every page under it and every asset
in it - and `draft: true` hides the section outright: 404 rather than a login
bounce, absent from the sitemap, `llms.txt`, the feeds and every `scan:` list,
previewable by a signed-in editor. Removing the entry publishes the whole subtree
in one act.

All of that is reached by hand-editing JSON.

The operator-facing consequence is the part SM181 named and did not build: an
operator cannot **see** which parts of their site are held back. There is no page
that answers "what is not published right now?", and the atomic release - the
original ask, "release all of it in one go" - is performed by deleting a key from
a file.

Two smaller consequences follow from the same gap:

- a draft section is invisible *by design*, so a section left in draft after
  launch stays invisible and nothing says so. The failure mode of a good hiding
  mechanism is forgetting what you hid.
- `read` lists and `draft` are edited in the same file that governs per-file
  authoring ACLs, with no affordance that distinguishes "this section is held
  back" from "this file has an owner".

## What

A **Protected sections** panel - on the Files page or an Access page of its own:

1. **List every prefix with an entry**, showing its policy (gated / draft), who
   may read it, and how many pages and assets sit under it.
2. **Add one** by picking a folder rather than typing a path, with the policy as
   a choice of two.
3. **Publish section** - one control that removes the entry (or clears `draft`,
   which are different acts and should read as different controls), with a
   confirmation naming what becomes public.
4. **Preview as public** for a draft section, so an editor can check what a
   visitor will see without signing out.

## What already exists, so nobody rebuilds it

- The store: `lazysite/auth/acls.json`, already read and written by the manager,
  MCP, WebDAV and the control API.
- The enforcement: `_acl_refused` / `_acl_is_draft` in the processor, with
  longest-path matching, covered by `t/integration/36` and `t/integration/37`.
- The listing exclusion: one filter in `scan_pages`, so registries and `scan:`
  variables are already consistent.

This is presentation over data that already exists, plus one read-only count.

## Verification

This is manager JavaScript and the repository has no browser harness, so a green
suite says nothing about it - see `docs/MANUAL-CHECKS.md`, *Manager UI
JavaScript*. The manual pass:

- add a gated section and a draft section from the panel; confirm each behaves as
  its policy says from a signed-out browser;
- confirm the draft section is absent from `/sitemap.xml` while gated content is
  present;
- publish each from the panel and confirm the section goes live and enters the
  sitemap;
- confirm a scoped (non-operator) manager sees only sections inside their scope.

## Not in scope

- Any change to the enforcement or the store - both are done.
- Per-file ACL editing, which already exists on the Files page. This panel is
  about SECTIONS; the two share a store and are different questions.
