---
title: "SM422: the cross-surface parity map, and what remains of it"
subtitle: "Three surfaces answer one authorization question, and six places they answered it differently. Two fixed, one filed as its own finding, three still needing verification before anybody acts on them."
brand: plain
standard-margins: true
status: candidate
status-note: "FILED 2026-08-20 from the security-review agent's round-3 mapping pass. The map itself is the durable artefact - it enumerates the control API, MCP and WebDAV against each governed operation - and is archived at inbox/archive/2026-08-20-cross-surface-parity-map.md. DISPOSITION: F1 (MCP nav read undershot manage_nav) is FIXED in this branch. F2 IS NOT, and the reason is recorded rather than the fix applied: the lazysite/themes/ carve-out IS vestigial (88f16b4 added it in one batch with layouts/ and nav.conf, two real managed areas, on the assumption this was a third; no engine store has ever resolved there) - but removing it could STRAND DATA, because an agent holding manage_themes could have written under that path through this very carve-out and nothing else would have stopped it. Files that exist only BECAUSE of a carve-out are precisely the files its removal orphans. An existing test asserts the carve-out too, written in the same commit and encoding the same assumption. The decision needs a fleet survey first. F4 turned out to be real and more than cosmetic and is [[SM421]] - a manage_forms holder can declare an arbitrary delivery target by writing a raw form conf over WebDAV, which the structured verbs on the other two surfaces do not permit. F3, F5 and F6 REMAIN OPEN and are recorded here rather than acted on, because the map marks each REPORTED rather than verified and acting on an unverified parity claim is how a consistency fix becomes an outage. WHAT THE MAP IS FOR beyond these six: the recurring defect class this session kept meeting is a rule one surface enforces and another does not - SM418's upload gate, SM419's history summary, F1 here - and a map that lists the surfaces against the operations is the only cheap way to find the next one before the field does."
---

# Still open, with what each needs

F2 - the vestigial `lazysite/themes/` carve-out
: Confirmed vestigial by code search and by 88f16b4's own message. **Needs**: a
  survey of whether any deployed site has files under `lazysite/themes/`
  (they could only have got there through this carve-out), then either removal
  plus a test update, or a note that the prefix is reserved. Removing it blind
  strands whatever is there, and the operator would meet that as files the
  file manager can suddenly no longer open.

F3 - submissions read capability differs by route
: MCP's purpose-built `read_form_submissions` requires `read_submissions`
  only, while the API's `form-submissions` and MCP's `read_file` on the store
  accept `read_submissions` OR `manage_forms`. So a manage_forms-only partner
  is refused the tool built for the job and can read the same data another
  way. The safe direction is the tool's; the inconsistency undercuts the
  least-privilege story. **Needs**: the cap sets confirmed against the code
  before anything moves, since tightening the wrong one removes access an
  operator relies on.

F5 - the API carve-out gate is conditional on `$site_secured`, MCP's is not
: On an unsecured instance the API file surface skips the carve-outs, which is
  consistent with "unsecured means no auth model" - `_is_operator` already
  treats everyone as the operator there. The two surfaces do not degrade
  identically, which may be fine. **Needs**: confirmation that an unsecured
  instance never exposes the token or MCP channel at all. If it does, the
  asymmetry matters; if it cannot, this is a note.

F6 - ACL-edit entry capabilities differ, the operative check does not
: MCP `get/set_permissions` take manage_content, API token `acl-*` takes
  webdav, API cookie `acl-*` takes ownership - and all three converge on the
  same internal ownership check, so effective parity holds. **Needs**: nothing
  for safety. Aligning the entry caps is a clarity change and should be
  scheduled as one, not as a fix.

# The standing check worth keeping

From the same pass, and worth more than any single flag: for any directory a
grant's deny list names, confirm the listing is refused **and then read a known
file inside it by name on every surface that grant reaches**. A deny is only
established when all of them refuse. Recorded here as a repeatable audit shape
rather than a one-off, because every finding above is an instance of it.
