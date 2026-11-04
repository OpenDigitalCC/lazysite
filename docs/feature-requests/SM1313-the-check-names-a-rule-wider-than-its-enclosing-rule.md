---
id: SM1313
title: "SM1313: lazysite check names a rule wider than its enclosing rule"
subtitle: "0.16.3 refuses a rule that admits more than the rule enclosing it unless the operator or that rule's owner writes it, and keeps the ones already stored. The check now names each stored one of that kind as a WARN for the operator to review, and changes nothing."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-04
raised-by: "the release manager, ruling 61, on SM1309's open point"
area: access
status-note: "SHIPPED (PENDING) on n739: report_widened_rules asks Acl::widening_refusal of each stored rule, one mode at a time, with the rule's owner as the writer; an operator's rule is skipped. A WARN per finding; nothing is written, with or without --fix. t/tools/295."
---

# What was asked

Ruling 61 (2026-11-04): `lazysite check` lists every stored rule wider than its enclosing
rule (the kind written before 0.16.3), as a WARN naming the path, the enclosing rule and
who it admits extra, telling the operator to review. It changes nothing, and repair does
not touch it. It reuses `Acl::widening_refusal`'s logic rather than duplicating it.

# What shipped

- `report_widened_rules` in `tools/lazysite-check.pl` reads the rule store. For each rule
  and each mode with a list, it asks `Acl::widening_refusal` the question the writer asks
  (SM1309), with the rule's own owner as the writer.
  - A carve-out the enclosing rule's owner owns is not named, nor is one an operator's
    account owns (`Acl::account_is_operator`). Both are the kind 0.16.3 still lets their
    owners write.
  - A rule that narrows is not named.
- **Each finding is a WARN:** "the rule on PATH lets WHO MODE it, which the rule on
  ENCLOSING does not ...". The hint says to review it, and names the
  `lazysite acl remove` command to take it off. At most 50 are listed.
- **Nothing is written.** The check has no `--fix` action for it, so `lazysite repair`
  leaves it as a finding for a person.
- It loads the engine modules (`_probe_load_engine`). Where they cannot load, it says
  nothing, as the ACL probe does.

# Tests

- **t/tools/295** (new): five stored rules under one area rule.
  - The one wider rule a member owns is named once, as a WARN, with its path, the
    enclosing rule and the account it admits beyond it, and the hint to review it.
  - Carve-outs owned by the enclosing rule's owner and by an operator, and a narrowing
    rule, are not named.
  - The store is byte-identical after the check and after `--fix`.

With the check's call removed, the six assertions about the WARN fail.

# Upgrade note

There is no 0.16.3 notes draft on this branch. The wording proposed for its ON UPGRADE
section is in the n739 report.
