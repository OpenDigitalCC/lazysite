---
id: SM1414
title: "SM1414: a member saves content over their own session"
subtitle: "Since SM1057 a member app's authors, members without the manager, cannot save a file at all. A write_content capability passes read, save, mkdir, move and delete on the manager API's cookie door, a write only where a file rule names the member, paths inside the session's domain."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "inbox triage 2026-11-06, row T-111; release manager, ruling 169 (Q99)"
area: security
status-note: "SHIPPED (PENDING) on n775: write_content (Capabilities, @CAP_KEYS, the grids); the cookie door's member_content set (Actions); a write needs a rule naming the caller (Acl::write_rule_names); paths in the session domain's root. Register entry drafted (ADR 0007 new interface). t/integration/377."
---

# What was asked

T-111 (inbox triage, 2026-11-06): since SM1057 (b1c2469ad, 0.15.5) the manager
API's cookie door refuses every non-operator session without `ui`, so a blog
app's authors, who are members without the manager, cannot save posts. WebDAV
needs Basic auth on every request, so a browser app has no other door. The data
endpoint already serves members holding `write_data`; this is its content twin.

Ruling 169 (Q99): a `write_content` capability passes a narrow action set (read,
save, mkdir, move, delete) on the cookie door for a holder without `ui`; a write
only where a file rule names the member or their group; a path no rule governs
refused; paths resolved inside the session's domain; a register assessment for
the new door.

# What SM1057 answered, and what this keeps

SM1057 had two causes. A path no rule governs was open to every writer, because
the content actions authorise against the file's rule and an ungoverned path has
none. A domain member's `/post/...` resolved against the primary's docroot. This
door answers both for its five actions and keeps SM1057's refusal for every
other action and for every account holding neither `ui` nor `write_content`.

# What was built

**The capability.** `write_content`, "write content files where a file rule
names you, over your own signed-in session". In `@CAP_KEYS` (and the check's
copy), described in `Lazysite::Capabilities` (section Content, a `ui` unlock
only, no `implied_by`), drawn on the Groups and Users grids, and in the
generated capability map. It implies nothing and no shipped role holds it. The
operator group is topped up with it (SM645) as with every capability, which
changes nothing for the operator, who bypasses the gate.

**The set.** `member_content => 1` on `read`, `save`, `mkdir`, `move` and
`delete` in `Lazysite::ControlApi::Actions`. A load-time check holds the
declaration to that ruled set, and each member must be `scoped` and on the file
surface. The locks are left out: a save does not need one (it refuses only a
foreign live lock), and an app need not hold one.

**The gate.** In the cookie door's non-operator block, a session holding
`write_content` and not `ui` passes the `ui` gate for a `member_content` action
only. Any other action gets SM1057's refusal, which then also names the set.
For a member action:

- the paths sent (`path`, and `to` for a move) are refused when empty, climbing
  (`..`), carrying a NUL or a backslash, or in the reserved `lazysite/` tree;
- they are resolved inside the content root of the domain the request arrived
  on (its own `content_root`, else the primary's), in place, so the scope check,
  the carve-out check, the handler and the audit row all read the file written;
- the caller is confined to its own domain scopes when its domain access
  resolves any, else to the session's content root (the primary's content less
  the other domains' roots, SM1372, when that is the docroot);
- a write (save, mkdir, delete, both ends of a move) passes only when the rule
  governing the path for writing names the caller or one of its groups
  (`Lazysite::Auth::Acl::write_rule_names`); `ungoverned` and `other` are
  refused as `permission`, an unreadable store as `cannot-tell`; a folder moved
  is refused when any rule beneath it does not name the caller;
- the manager's `manage_content` gate is not asked on this door; the handler's
  own checks (the file rule, the blocklist, the extension guards) run as before.

A read is left to the file's read list, as everywhere. CSRF and the audit row
are the door's own, unchanged. A `ui` holder never takes this door.

# Tests

`t/integration/377`: on a two-domain site with rules keyed by the domains'
paths, a `write_content` member saves, reads, makes a folder, moves and deletes
where a rule names its group, and the bytes land in the domain it signed in on
(and on the other domain, and on the primary, under each tree's rule); it is
refused where the rule names someone else, where no rule governs, the domain's
tree from the primary, the engine's tree and a climbing path; it is refused
acl-set, config-read, config-set, users, list, copy and lock; and an account
holding neither is refused as SM1057 refuses it. Each control reverted fails a
subtest (the door, the rule check, the domain resolution, the set, the reserved
tree). `t/integration/220` and `221` still pass.

# Open

- `list` is outside the ruled set, so an app cannot list a folder over this
  door; it can read the site's own index pages. A ruling could add it.
- The answer's `path` names the docroot path the engine wrote
  (`/sites/<root>/post/x.md` on a domain), not the path the member sent.
