---
title: "SM551: group ACL reach is silent on a migrated site"
subtitle: "lazysite-check.pl builds the acls.json path under the docroot rather than through model_path, so on an SM293 migrated site the @group section reports nothing."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.32 (EDGE): report_group_acl_reach and _acls_file in lazysite-check.pl now resolve acls.json through Lazysite::Paths::lazysite_dir (the resolver run_checks uses) instead of "$docroot/lazysite/auth/acls.json"; proving assertion in t/tools/38-migrate-engine-tree.t writes an @agents rule with the real ACL writer on the migrated site and requires '@agents is granted by' in the report, which was absent before the fix. FOUND 2026-08-25 by the tools structural review, PROVEN by probe tmp/probe-check-migrated-acl/result.txt; class: correctness; recommended timing: 0.10.33. PLANNED under SM516 for 0.10.33 unless the operator pulls it forward. report_group_acl_reach and _acls_file in tools/lazysite-check.pl build $docroot/lazysite/auth/acls.json instead of using model_path or $LZ, so on a site whose engine tree was migrated out of the docroot (SM293) the @group reach section is empty and the ACL probe's sweep and cleanup look at a path that does not exist. This is the same defect that lines 188-193 already fixed for run_checks; the inside-docroot site prints '@agents is granted by /private/ (read)', the migrated site prints no reach lines at all."
---

# The finding

`report_group_acl_reach` and `_acls_file` in `tools/lazysite-check.pl`
build `"$docroot/lazysite/auth/acls.json"` instead of resolving through
`model_path` / `$LZ`. On a migrated site (SM293, engine tree at
`docroot-lazysite`) the @group section is silent and the probe's sweep
and cleanup inspect a path that does not exist - the defect that
`lazysite-check.pl 188-193` fixed for `run_checks`. The probe shows the
inside-docroot site reporting `@agents is granted by /private/ (read)`
and the migrated site reporting no reach lines.

# Why it matters

Correctness: the check reports an empty group reach as if no group rule
existed, so an operator on a migrated site reads silence as 'nothing
granted' when rules are in force.

# The proving test

`t/tools/38-migrate-engine-tree` (179-191 already runs check on a
migrated site): NEW assertion - write an @group rule first, then
`like /\@agents is granted by/`.

# Fix shape

Resolve the ACL file through `model_path` / `$LZ` as `run_checks` does,
in both `report_group_acl_reach` and `_acls_file`.
