---
id: SM937
title: "SM937: acl-set reports reads unrestricted on a rule that does hide the page"
subtitle: "Setting `draft: true` returns `reads_unrestricted: 1` and a note saying anyone may still fetch the page. The page 404s to the public and is absent from the index. The note measures the read LIST and reports it as the read OUTCOME, and it would talk a correct operator out of trusting a protection that works."
brand: plain
standard-margins: true
status: shipped
raised: 2026-09-30
raised-by: sites agent, drafting five pages on dhcf.eu (0.14.4) and measuring anonymously afterwards
area: access control
status-note: "SHIPPED (PENDING). The reply asks `_acl_gates_public` - SM286's definition, which already counted `draft` with the reasoning written beside it - instead of testing the read LIST itself. TWO RULES FOR ONE QUESTION was the whole cause: one answered the list, the other the outcome, and they came apart on the draft case. SABOTAGE-VERIFIED: with the old read-list test put back, the new subtest fails on exactly the two draft assertions while its "draft really was stored" check still passes - so it fails for the right reason rather than because the fixture broke. The caveat still fires on the owner-only rule SM479 wrote it for, which is asserted in the same file. ORIGINAL REPORT: NOT YET RULED, and the remedy is a wording decision rather than a mechanism one. Measured: each `acl-set` with `draft: true` answered `reads_unrestricted: 1` with the note 'this rule does not restrict READING: it has no read list, so anyone may still fetch these pages', while an anonymous GET of each page returned 404 and the public directory index listed none of them. SO READS ARE RESTRICTED and the reply says they are not. THE NOTE IS TRUE OF THE READ LIST AND FALSE AS A STATEMENT ABOUT READING: `draft` is a second mechanism that restricts reading on its own, and `_scan_hidden` honours it in listings too. The guard was built for a real failure - a rule that looks protective and is not - and the fix is to make it CONDITIONAL on what the rule actually does, not to remove it. The reporter's framing of the cost is the reason this is filed: 'the shape of defect that makes a correct operator do the wrong thing', with two wrong moves available - set a read list they did not want, restricting signed-in readers they meant to allow, or conclude the draft failed and go hunting for another mechanism. And the asymmetry worth recording: a false 'you are protected' is the famous failure and this engine guards it carefully; a false 'you are NOT protected' is the same class with the sign flipped."
---

# Measured

Five pages drafted on dhcf.eu, 0.14.4. Each `acl-set` returned:

    {"ok":true,
     "acl":{"draft":true,"owner":"sjm-claude-code"},
     "reads_unrestricted":1,
     "reads_unrestricted_note":"this rule does not restrict READING: it has no read
       list, so anyone may still fetch these pages"}

Measured immediately afterwards, anonymously, over HTTP:

| Check | Result |
| --- | --- |
| `GET /videos/gwyn-williams` as a visitor | **404** |
| `GET /videos/clayton-blake` as a visitor | **404** |
| The public `/videos/` index, which scans that directory | lists **none** of them |

**Grade: measured on a live site (A)** - the same call five times, each followed by
an anonymous fetch.

# Why the note is wrong here rather than wrong in general

It is true of the `read` **list**: there is none, and an ACL with no read list
restricts nobody *by that mechanism*. It is false as a statement about reading,
because `draft: true` restricts reading on its own and listings honour it as well.

The guard exists for a real failure - a rule that looks protective and is not - and
should stay. What it needs is to know that a rule carrying `draft: true` is not a rule
that leaves reading unrestricted.

# What should change

| Ref | Change |
| --- | --- |
| RU1 | Suppress `reads_unrestricted` when the rule carries `draft` |
| RU2 | Or word it for the combination - "no read list, so signed-in users are not filtered; `draft` hides this from the public" |

Either states the position. The present wording contradicts it. RU2 says more and is
the better answer if the field is ever read by something other than a person.

# What this filing does not claim

- **Not** that the guard should be removed. It is there for the opposite and more
  dangerous failure.
- **Not** that `draft` is misbehaving. It does exactly what it is for; that is the
  whole point.

# Related

[[SM465]] (the audit captures the rule before the change - the same function),
[[SM936]] (the same surface, a rule outliving its subject),
[[feedback_a_boolean_has_four_states]], [[feedback_absence_is_a_finding]].
