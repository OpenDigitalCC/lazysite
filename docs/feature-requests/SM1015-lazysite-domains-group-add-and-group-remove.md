---
id: SM1015
title: "SM1015: lazysite-domains.pl group-add and group-remove"
subtitle: "A command to add or remove one group (or one locked user) on a domain from the shell, through domain_set."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: WORK-PLAN-0154 U3, ruling of 2026-10-12 ("lets have cli command to add the domain group")
area: tools
status-note: "SHIPPED (0.15.5): lazysite-domains.pl group-add / group-remove (and user-add / user-remove for locked_users) through domain_set; idempotent; an unknown group or account is refused by name (t/tools/120). Landed 2d403e12, e314cae9."
---

# The ruling

"lets have cli command to add the domain group"

# What it does

`lazysite-domains.pl --docroot DIR group-add --host H --group G` adds one group
to a domain's `allowed_groups` and keeps the others; `group-remove` takes one
out. `user-add` and `user-remove` do the same for `locked_users`. `G` may be
`@name` or `name`.

The list is written through `domain_set`, so validation, the content-history
commit and the log line are the ones every surface gets. Adding a name already
there, or removing one that is not, says so and exits 0. A group or account the
site does not have is refused, naming it, because a misspelt group admits
nobody; a store that cannot be read refuses the add. The tool gains `--help`.

`domain_access_edit` is classified in the write-path registry (e314cae9).

Test: t/tools/120.

# Note

This filing was written on 2026-10-13, after the change landed: the branch
carried a CHANGELOG entry but no filing, which the 0.15.5 release gate's
lint 26 found. The text is taken from the landed commits and the CHANGELOG
entry.
