---
title: "SM419: the content-history summary ignored scope, and a grep that ate its own input"
subtitle: "Every per-file history operation is scope-confined and blocklisted. Their site-level complement was neither - so a partner refused one tenant's history was handed that tenant's file inventory, edit cadence and authors by the overview beside it."
brand: plain
standard-margins: true
status: shipped
status-note: "FIXED 2026-08-20. Reported by the SECURITY-REVIEW agent's round-3 pass, reproduced against the real MCP binary with two seeded tenants. THE FINDING: git-history/git-show/git-restore (API) and list_versions/view_version/restore_version (MCP) all resolve through _git_target, which blocklists and scope-confines; the SUMMARY ls-tree'd the whole committed tree with no filter of any kind. Metadata only - content still needs the confined per-file calls - but on a multi-tenant instance it is the neighbour's file tree, edit counts, dates and last authors, plus engine paths like lazysite.conf that a direct read refuses. FIXED on both channels, with the totals RECOUNTED (a count that disagrees with its own list tells a scoped caller how many files it is not being shown) and an unscoped operator unchanged. AND A SHARPER BUG FELL OUT: the fix's own grep dropped its first element. is_blocked_config -> upload_limits -> load_upload_limits read the config with `while (<$fh>)`, which assigns the GLOBAL $_ - so calling it inside a grep destroys the element under test. upload_limits MEMOISES, so only the FIRST call in a process clobbers: the first element of the first such grep comes back empty and every later one is fine, which is a corruption that hides from a second run. `local $_` fixes it, and a regression test asserts the predicates against a plain grep rather than through the summary, because any caller can hit it. A SURVEY FOUND 19 MORE SUBS with the same shape across the tree - filed separately; none is proven live, and the difference between latent and live is one caller."
---

# Two questions, one answer

A view and its site-level complement were answering *"who may see this path?"*
differently. The per-file operations refuse a cross-scope path; the summary
listed every path there is.

::: widebox
The scoped caller was refused clientB's history by name and given clientB's
filenames, how often each changes, when, and who last edited them - by the
overview beside it.
:::

# The grep that ate its own input

Writing the filter surfaced a defect worth more than the filing that found it:

```perl
grep { !is_blocked_config( $_->{path} ) } @files   # drops the FIRST element
```

`load_upload_limits` reads its config with `while (<$fh>)`, which assigns the
global `$_`. `upload_limits` memoises, so only the first call in a process
clobbers - the first element of the first such grep comes back empty and every
later one is fine. A defect that a second run hides is worse than one that
fails every time.

# Verification

`t/unit/manager/64`: both tenants really recorded (or every assertion below
would pass against an empty summary), a scoped caller seeing only its own, the
totals matching the filtered list, blocklisted paths absent for everyone, and
an unscoped operator still seeing the whole site. Four sabotages on the filter
and one on the `local $_`, all confirmed to bite.
