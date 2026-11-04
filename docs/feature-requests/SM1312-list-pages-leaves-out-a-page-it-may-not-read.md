---
id: SM1312
title: "SM1312: list_pages leaves out a page the caller may not read"
subtitle: "list_pages read every page's title with no check of the page's rule, so a page under a read rule that was still in the document root had its title listed to a grant read_page refuses. It now asks the rule first."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-04
raised-by: "the release manager, ruling 60, on SM1308's open point"
area: access
status-note: "SHIPPED (PENDING) on n739: list_pages asks _acl_denied of each page before it opens it, for every grant. t/unit/mcp/69."
---

# What was asked

Ruling 60 (2026-11-04): list_pages checks the page ACL before reading a title, for
legacy pages in the document root.

Since SM286 (0.10.8) a page under a read rule is moved to the private store, which the
walk does not enter. Some pages stay in the document root under such a rule: a section
protected before 0.10.8 and not re-applied, one a pull put back, or a page under a rule
with only address lists, which moves nothing. Their titles were listed.

# What shipped

- `_list_pages` asks `_acl_denied($rel, 'read', $user)` before it opens each page. This is
  the question `read_page` asks, covering the read list and the address rule. A page it
  refuses is left out of the listing, title and all.
- It applies to every grant, confined or not, as the search's check does (SM1308).

# Tests

- **t/unit/mcp/69** (new): a gated page left in the document root is not listed, title
  included, to a confined grant or an unconfined one, neither of which its rule names. The
  reader its rule names sees it: that is the control.

With the change reverted, the four assertions for the two refused grants fail.
