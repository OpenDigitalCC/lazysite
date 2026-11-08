---
id: SM1414
title: "SM1414: a member saves content over their own session"
subtitle: "Since SM1057 a member app's authors, members without the manager, cannot save a file at all. A write_content capability passes read, list, save, mkdir, move and delete on the manager API's cookie door, a write only where a file rule names the member, a listing of what a rule lets them read, paths inside the session's domain."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "inbox triage 2026-11-06, row T-111; release manager, rulings 169 (Q99) and 173 (Q103)"
area: security
status-note: "SHIPPED (PENDING) on n775: write_content (Capabilities, @CAP_KEYS, the grids); the cookie door's member_content set (Actions), list added by ruling 173; a write needs a rule naming the caller (Acl::write_rule_names); a listing shows what a rule lets them read (Files::member_listing); paths in the session domain's root. Register entry drafted. t/integration/377."
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

Ruling 173 (Q103): `list` joins the set; a listing shows only entries the member
may read under each entry's rule, inside their own domain, and never the
reserved tree.

# What SM1057 answered, and what this keeps

SM1057 had two causes. A path no rule governs was open to every writer, because
the content actions authorise against the file's rule and an ungoverned path has
none. A domain member's `/post/...` resolved against the primary's docroot. This
door answers both for its six actions and keeps SM1057's refusal for every
other action and for every account holding neither `ui` nor `write_content`.

# What was built

**The capability.** `write_content`, "write content files where a file rule
names you, over your own signed-in session". In `@CAP_KEYS` (and the check's
copy), described in `Lazysite::Capabilities` (section Content, a `ui` unlock
only, no `implied_by`), drawn on the Groups and Users grids, and in the
generated capability map. It implies nothing and no shipped role holds it. The
operator group is topped up with it (SM645) as with every capability, which
changes nothing for the operator, who bypasses the gate.

**The set.** `member_content => 1` on `read`, `list` (ruling 173), `save`,
`mkdir`, `move` and `delete` in `Lazysite::ControlApi::Actions`. A load-time check holds the
declaration to that ruled set, and each member must be `scoped` and on the file
surface. The locks are left out: a save does not need one (it refuses only a
foreign live lock), and an app need not hold one.

**The gate.** In the cookie door's non-operator block, a session holding
`write_content` and not `ui` passes the `ui` gate for a `member_content` action
only. Any other action gets SM1057's refusal, which then also names the set.
For a member action:

- the paths sent (`path`, and `to` for a move) are refused when empty, climbing
  (`..`), carrying a NUL or a backslash, or in the reserved `lazysite/` tree;
  a `list` naming no folder lists the session's root;
- they are resolved inside the content root of the domain the request arrived
  on (its own `content_root`, else the primary's), in place, so the scope check,
  the carve-out check, the handler and the audit row all read the file written;
  a resolved path inside another domain's content root (a domain whose root is
  nested in this one's tree) is refused (ruling 173, for every action);
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

**The listing (ruling 173).** The folder is resolved as for the other five, and
`action_list`'s answer is then cut down by `Lazysite::Manager::Files::member_listing`:

- an entry in the reserved tree, or inside another domain's content root, is
  left out (on the primary, SM1372 already leaves the domains' roots out; the
  view also leaves out a domain nested in the session's own tree);
- an entry is shown only when a rule governs it, one carrying a read list or a
  write list, and the read the file's rules allow admits the member
  (`Lazysite::Auth::Acl::list_rule_admits`, which asks `_acl_allows`: named in
  the read list, in a group it names, the rule's owner, or no read list in
  force); an unreadable store refuses the listing (`cannot-tell`);
- each entry keeps its name, type, size, time, store label and file facts, and
  loses the rule's lists, owner, lock holder and a served copy's hosts, which
  name other accounts and domains; the answer carries no `address_profiles`
  (SM1404 keeps the pickers to the Files page's listing);
- the paths are the site's: the session's root is taken off the answer's `path`
  and each entry's, so an entry's `path` is what the member reads or saves next.

*How "a folder no rule governs shows nothing to them" is read.* Each entry is
judged by the rule that governs that entry. An entry no rule governs, file or
folder, is not shown; so a folder no rule governs is not shown in its parent,
and listed by name it shows nothing of its unruled content (an entry beneath it
with a rule of its own is judged by that rule). A rule with only a write list
governs too: an authors' folder is commonly ruled `{"write":["@authors"]}` with
reading left open, and a listing that hid it would hide the very folder the
member writes. Why: on this door a path is the member's only where the
operator has said so with a rule, which is how the write side already refuses
an ungoverned path. A listing that showed unruled entries would offer files the
member cannot write and let a member browse the primary's whole unruled tree,
drafts and files nothing links to included, which a read of a known path does
not.

# Tests

`t/integration/377`: on a two-domain site with rules keyed by the domains'
paths, a `write_content` member saves, reads, makes a folder, moves and deletes
where a rule names its group, and the bytes land in the domain it signed in on
(and on the other domain, and on the primary, under each tree's rule); it is
refused where the rule names someone else, where no rule governs, the domain's
tree from the primary, the engine's tree and a climbing path; it is refused
acl-set, acl-get, config-read, config-set, users, copy and lock; and an account
holding neither is refused as SM1057 refuses it (a listing too). Each control
reverted fails a subtest (the door, the rule check, the domain resolution, the
set, the reserved tree). `t/integration/220` and `221` still pass.

Ruling 173's listings, on the same site with a protected folder naming the
author's group, one naming only the operators, and a third domain whose root is
nested in the first's tree: a listing shows the readable entries only, by the
site's paths, with no picker lists or rule lists, and naming no folder lists
the domain's root; a folder no rule governs shows nothing; a protected entry
naming someone else is hidden, in its parent and listed by name; with a
site-wide write rule in force, the primary's listing shows no `lazysite/` and no
domain root, the nested domain is not shown on the first, and listing the
reserved tree, another domain's root or the nested domain is refused, as is a
save into the nested domain. Each control reverted fails: `list` out of the
set, the view not applied, an ungoverned entry shown, the read not asked, the
reserved tree kept, another domain's root kept, the door's nested-domain
refusal, the entry fields kept.

# Open

- The answer's `path` on a write names the docroot path the engine wrote
  (`/sites/<root>/post/x.md` on a domain), not the path the member sent. A
  listing names the site's paths.
- A listing does not ask the address rules (SM1139) per entry: an entry under a
  rule whose address profile refuses the member's address is listed, and its
  read is refused. Asking would write an address-audit row per entry.
- A listing of a folder the member may not read answers an empty list, where a
  folder that does not exist is refused: the folder's existence is told, as a
  read's `permission` against `not-found` already tells it.
