---
id: SM783
title: "SM783: a message names the right thing - the field, the fault, and the reason"
subtitle: "Three observations from 138E on 0.13.8, each a message that names something other than what it means: a scope refusal that says 'scope' when whoami prints a different one, a site-package name refused as absent when it was sent and malformed, and 'A value is required' that does not say why this key differs from the one just cleared."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-08 on claude/sm783-a-message-names-the-right-thing. The package refusal names the FIELD (dav_scope), so a reader following it to whoami is not misled by the content `scope` block; _site_package_path's callers answer a malformed name by quoting it and giving the shape, and an absent one by naming the parameter and where it goes; config-set's refusal says the key has no default to fall back to and lists the keys that can be cleared. t/unit/manager/46 and /10 assert each."
---

# What the field saw (138E, all three offered as observations rather than findings)

1. **The scope refusal said "scope".** SM782's message - "this grant names no
   scope" - sent a reader to `whoami`, which prints a `scope` block (the
   content allow/deny) that is not the field this rule consults. "A reader who
   follows the message to `whoami` finds a scope there and may conclude the
   message is wrong about them."
2. **A malformed package name was refused as a missing one.**
   `{"name":"PLACEHOLDER"}` → `A site package name is required`. A name *was*
   sent. Their words: "the same family as the three refusals this release
   fixed - a bad value reported as an absent one - and it is what sent me
   looking at the body-vs-query split in the first place."
3. **`A value is required`** for `site_name`, immediately after clearing
   `backup_retention` with an empty value, does not say why the two differ:
   "one clause - that this key has no default to fall back to - would stop a
   reader concluding the clear is unreliable."

All three are confirmed in the source, and (2) is the direct cause of 137E's
finding 3, which cost a round trip to investigate.

# What is built

- `_package_grant_refusal` names the field: "this grant's dav_scope names no
  dav_scope" (or the scopes it does name).
- `_site_package_path` returns the path or undef, and its four callers answer
  through one `_package_name_refusal`: absent → `A site package name is
  required (in the JSON body or the query as \`name\`)`; malformed → `'X' is
  not a site package name - expected lazysite-site-<host>-<stamp>.tar.gz`.
- `config-set`: `A value is required: 'site_name' has no default to fall back
  to, so it cannot be cleared (the keys that can are asset_max_age,
  backup_retention, canonical_ip)`.
- `t/unit/manager/46` and `t/unit/manager/10` assert all three.

This is SM773's class again - a fault described as the wrong fault - three
instances after the release that fixed three. The catalogue-driven fix stays
the candidate; these are the instances the field found in the meantime.
