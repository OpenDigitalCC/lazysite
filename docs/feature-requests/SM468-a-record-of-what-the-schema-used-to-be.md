---
title: "SM468: a record of what the schema used to be, and who changed it"
subtitle: "Schema state is DERIVED, so the store always describes itself correctly. What derivation cannot answer is what the shape was yesterday, when it changed, and who changed it - deferred deliberately, and recorded so the question is not rediscovered."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 0.10.29 (9480c16) - the flip its landing chain wrote was lost with the same tree rewrite that ate its changelog entry; restored at the post-cut pass. Built as the filing itself specified: a TABLE IN THE STORE (_schema_history, undeclarable by construction, invisible to listings, travelling with the data through backup/restore); apply, rebuild and drop each append one attributed row; never fatal; surfaced as history on the data-table response across manager, API and MCP. ORIGINAL NOTE: FILED 2026-08-21 at the release manager's direction, alongside the D2 decision. THE DECISION THAT PRODUCED IT: SM447's schema state is DERIVED from the database (one PRAGMA), not held in a state file. The SM410 map had listed a state file written through the SM404 checked writer; that was reconsidered because a state file is a third copy of one fact, after the descriptor (what is wanted) and the database (what exists), and it is the only copy nobody validates. Three concrete disagreements settled it: DP-6 restores into a FRESH database, possibly on another engine, so a copied state file describes something that is not there; a partial restore of data.sqlite without the state file (or the reverse) leaves two files disagreeing with nothing able to say which is right; and a hand-edited store moves on while the file does not, so the next migration plans against a fiction. THE RELEASE MANAGER CHOSE DERIVATION, and asked that the remaining question be recorded rather than dropped. WHAT DERIVATION CANNOT ANSWER, which is the whole of this filing: derivation is a perfect account of NOW and no account at all of BEFORE. It cannot say what the shape was last week, when a column appeared, which release applied it, or who ran the migration. Nobody has asked for that yet; it becomes a real question the first time a migration is blamed for something. NOT A STATE FILE, IF IT IS BUILT. The right shape is a TABLE IN THE STORE - it travels with the data through DP-6 by construction, it cannot be restored out of step with the rows it describes, and it is readable by the same tools as everything else. A file beside the database would reintroduce exactly the desync this decision removed. RELATED, AND THE REASON THIS IS NOT URGENT: the audit trail already records operator actions and is already where people look for who-did-what. What it does not carry is the SHAPE, which is the part only the data layer knows. Whether that is worth its own record, or whether an audit entry naming the migration is enough, is the open question."
---

# What each source can answer

```datatable
columns: Question | Descriptor | Database | A history
widths: 6cm | 2.2cm | 2.2cm | X
bold: 1
tone: medium
---
What shape should it be? | yes | no | no
What shape is it now? | no | **yes** | no
What shape was it last week? | no | no | yes
When did that column appear? | no | no | yes
Who applied the migration? | no | no | yes
```

Derivation covers the middle row completely, which is the row every migration
actually needs. The bottom three are a different question wearing similar
clothes, and conflating them is what a state file did.

# Why a table and not a file

A file beside the database can be restored without the database, or the
database without the file. That is the desync the derivation decision removed,
and adding a history as a file would put it straight back -- with the added
unpleasantness that the desynced copy would be the one claiming to be a record.

A table travels with the rows it describes, through backup and through the
DP-6 typed-JSON export, because it *is* rows.

# When this stops being deferred

The first time a migration is blamed for something. Until then the store
describes itself correctly, which is what the work in front of it needs.
