---
title: "SM575: ownership is a pattern, or it is two cases"
subtitle: "ACLs enforce per-file ownership and themes enforce creator ownership. Briefs and data tables have never been asked. Either ownership is a rule every store follows, or it is two stores that happen to check, and nobody has said which."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.33: answered, and pinned as a decision rather than a measurement. Five two-principal unit tests, one per store, each carrying the reasoning in its file header: t/unit/manager/112 (a non-owner is refused acl-get, acl-set and acl-remove on another principal's rule, at the path AND the site-root branch), t/unit/mcp/22 (delete_theme over the real MCP channel refuses a theme another account created, and refuses one with no created_by at all), t/unit/manager/113 (a second principal MAY overwrite and delete another's page - and a per-file ACL is the opt-in that makes a page owned), t/unit/manager/114 (a second principal MAY read, append to and delete another's brief; attribution is per ENTRY), t/unit/data/26 (a second principal MAY read, write, drop and clear the safety export of another's table; the schema history names who acted and the drop leaves a recoverable export). ANSWER TO THE FILING'S QUESTION: ownership is NOT a pattern across stores and was never meant to be - it is two stores where the artefact is a statement about authority (an ACL) or a singular authored thing (a theme), against three where the artefact is a piece of ONE shared site. No source changed; the four rows below are now decisions with tests behind them. RAISED 2026-08-25 out of the SM570 two-principal walk on edge: a non-owner could not read, set or remove another principal's ACL rule (proven with a second principal issued by the operator), and themes refuse a delete with 'not created by this account'. Those are two stores. The briefs store (list_briefs, delete_brief - SM508, SM515) and the data tables (drop, rebuild, migrate) were UNVERIFIED: nothing said whether one partner can delete another partner's brief or drop another partner's table. Proving test, whichever way it is answered: a two-principal unit test per store asserting the non-owner is refused; where the answer for a store is 'no ownership by design', the filing records that decision and the test pins the shared-store behaviour instead. PLANNED for 0.10.33 under SM516: S if the tests only confirm what the stores already do; M if ownership must be added to a store. It was S - nothing needed adding."
---

# Two stores check, and three are shared on purpose

| Store | Ownership today | Evidence |
|---|---|---|
| ACL rules | per-file owner; non-owner refused on get, set, remove | `t/unit/manager/112`; two-principal walk on edge, 2026-08-25 (SM570) |
| Themes | creator; "not created by this account" | `t/unit/mcp/22`; theme delete refusal |
| Content | SHARED by design; the capability is the gate | `t/unit/manager/113` |
| Briefs | SHARED by design; attribution is per entry | `t/unit/manager/114` |
| Data tables | SHARED by design; the schema history names who acted | `t/unit/data/26` |

# The question

Can one partner delete another partner's brief with `delete_brief`? Can
one partner drop another's table? If the answer is meant to be no, two
stores are missing a check the other two have. If the answer is that
briefs and tables are site-shared by design, that decision has never
been written down, and a partner reading the theme refusal will assume
the same protection everywhere.

# The answer

Site-shared by design, for content, briefs and tables - and the
decision is now written down where a future change has to meet it,
which is in the test file for each store rather than only here.

The line is not "which store happened to get a check". It is what the
artefact IS:

Content, briefs and data tables
: pieces of ONE site. Pages link to each other, a brief is the record
  of intent for the next person to touch a page, a table is the site's
  data with a schema. Ownership on any of them would mean the routine
  work of running a site queues behind whoever saved a file first, and
  that anything left by a departed partner becomes permanently
  untouchable. The capability - `manage_content`, `manage_data` - is
  the operator's statement that a principal may work on this site, and
  it means all of it.

ACL rules
: not a piece of the site but the statement of who may touch one. A
  permission record any holder of `manage_content` could rewrite is not
  a permission record, and a shared answer here would dissolve the
  protection the other four rely on.

Themes
: singular, authored, and not derivable from the rest of the site.
  `delete_theme` exists so an agent can clear its own experiments
  (SM262); widened to "anyone's experiments" it becomes a destructive
  action on somebody else's design work.

What preserves accountability in the three shared stores is
attribution rather than ownership, and the tests assert it: a brief
stamps every entry with its date and actor, a data table writes a
schema-history row per operation and a safety export per drop, and a
page's content history holds what changed. Ownership on content is
still AVAILABLE as an opt-in - a per-file ACL - and
`t/unit/manager/113` pins that route as well as the default.

# Proving test

A two-principal unit test per store, asserting the answer that store
gives, with the reasoning in the file header so that changing it means
arguing with the reason rather than discovering the fact. Each refusal
was sabotage-verified (the ownership comparison relaxed in a scratch
copy of the tree, the test seen to fail); each permitted case says in
its header that it pins a deliberate permission and would fail if
ownership were added.

The rigs are the ones the suite already had - `TestHelper::dav_users_tool`
and `grant_caps` for the two accounts, `ui` on the role groups so the
site is SECURED and neither principal is treated as an operator.
