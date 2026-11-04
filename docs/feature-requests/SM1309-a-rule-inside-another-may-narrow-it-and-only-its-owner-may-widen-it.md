---
id: SM1309
title: "SM1309: a rule inside another may narrow it, and only its owner may widen it"
subtitle: "A member of a protected area, or the member's agent, could write a rule on a subfolder that admitted a non-member, and the non-member then read the pages. Longest match stays, so an operator's carve-out still works; writing a rule that admits anyone the enclosing rule does not is now allowed only to the operator or the enclosing rule's owner, on every surface that writes or moves a rule."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-04
raised-by: "the release manager, ruling 46 (tmp/rulings-2026-10-22.md, \"4 November\"), Q1 option (b), on T-02 of the inbox triage (tmp/inbox-triage-2026-11-04.md): a report from a site building a protected intranet, gap G4"
area: access
status-note: "SHIPPED (PENDING) on n739: Acl::widening_refusal (enclosing_rule, the principals the new list adds, those the enclosing rule does not admit) is asked by Files::action_acl_set before it writes, and Acl::move_widening_refusal by Files::action_move and WebDAV MOVE before they move; kind widens-enclosing-rule, naming the enclosing rule. t/unit/mcp/66, t/unit/dav/36."
---

# What was asked

Ruling 46 (2026-11-04): "A subfolder rule keeps longest match, but only an operator, or
the owner of the enclosing rule, may write a subfolder rule that admits anyone the
enclosing rule does not (T-02)." The brief: the refusal names the enclosing rule; it
applies on every surface that can write rules; SM223's public carve-outs inside a
private site stay possible for operators.

The report (gap G4): a member's agent ran `set_permissions` on a new subfolder of a
protected area with `read: [a non-member]`. It answered ok, and the non-member then read
a page in that folder (200, where it had been 403). Changing the area's own rule was
refused to anyone but its owner.

Two facts make it possible. A mode's list is decided by the longest match
(`_acl_entry_and_key`, and the processor's copy), so a subfolder's rule replaces its
parent's for that mode rather than narrowing it. And anyone with write access to a path
may create its first rule (`action_acl_set`, since 0.4.1).

# What shipped

- **The enclosing rule.** `Acl::enclosing_rule($map, $rel, $mode)` is the rule that
  would govern the path for that mode if it had no rule of its own: the readers' walk
  with the path's own key taken out, so its page stem, each ancestor folder and the
  site-wide rule take part.
- **Who a rule admits** for a mode is the names in its list and its owner (who passes
  every mode), while the list is not empty. The principals checked are those the new
  rule admits that the rule already on the path does not, so the owner of an existing
  carve-out can re-apply or edit it without widening it further.
- **Admitted by the enclosing rule** means named, or its owner, or (for an account)
  in a named group, nesting included, or (for a group) named or nested in a named
  group. Group names compare without case and accounts exactly, as the readers do.
- **The refusal** (`Acl::widening_refusal`) is `kind: widens-enclosing-rule`, with
  `field` (read or write), `enclosing` (the key) and `admits` (the principals), and a
  sentence naming the enclosing rule. Nothing is written. It passes when
  `file_rule_bypass` holds (the operator, `local`, or an unsecured site) or the writer
  owns the enclosing rule.
- **Every writer.** `Files::action_acl_set` asks it before it writes, so the manager,
  the control API's `acl-set` (single and list forms, whose dry run asks it too), MCP
  `set_permissions` and `lazysite acl set` refuse alike. Read and write lists are both
  held to it, since both are decided by longest match.
- **Every mover.** A move carries every rule at or under the source to the target
  (`rekey_path`), so a wide rule written where nothing encloses it could be moved inside
  the area. `Acl::move_widening_refusal` asks each carried rule against what will
  enclose it at its new key, and `Files::action_move` (manager, control API, MCP
  `move_file` and `rename_page`) and WebDAV MOVE (403, the sentence as the body; a
  WebDAV account is never the operator) refuse before anything moves. A COPY carries no
  list, so it is not asked.
- Address lists are unchanged: every layer must admit (SM1134), so they cannot widen.

# Tests

- **t/unit/mcp/66** (new): the area `content/intranet` (read and write `@intranet`,
  owned by boss). The member's agent is refused a subfolder rule admitting a non-member,
  for read and for write, the refusal names `content/intranet`, nothing is written and
  the non-member still cannot read the page. A rule narrowing the subfolder to the
  member is accepted. An existing carve-out admitting a non-member still serves it, and
  its owner re-applies it unchanged but cannot widen it. The enclosing rule's owner
  (over MCP) and the operator (`lazysite acl set --actor local`) write the carve-out.
  The CLI refuses the member by the same check. A wide rule written outside the area is
  accepted, and moving it inside is refused.
- **t/unit/dav/36** (new): a MOVE carrying a rule that admits a non-member into the
  area is refused with 403 naming `content/area`, and the rule stays; a MOVE carrying a
  rule the area admits succeeds.

With `Files.pm` and `Acl.pm` put back to the base, t/unit/mcp/66 fails 4 of 6 (the
narrowing rule and the owner and operator writes are the controls). With
`lazysite-dav.pl` put back, t/unit/dav/36's refused MOVE fails.

# Not done

- **Rules already written.** A carve-out a member wrote before 0.16.3 is honoured; the
  check is on writing, and the ruling keeps longest match. Finding them needs a reading
  of each rule against its enclosing one; `lazysite check` does not do that.
- **A group's membership** is read when the rule is written. Adding someone to a group a
  subfolder rule names later admits them there, as it always has.
- **The site package** (`site_apply`) restores an acls.json as it was packaged; it is an
  operator's act and is not asked.
