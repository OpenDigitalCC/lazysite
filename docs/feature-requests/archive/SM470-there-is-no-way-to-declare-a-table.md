---
title: "SM470: there was no way to declare a table"
subtitle: "The descriptor lives under lazysite/, which every write channel refuses. So a table could be declared only by somebody with a shell on the host - and the capability advertised a WebDAV path the front door denies."
brand: plain
standard-margins: true
status: shipped
status-note: "FILED AND SHIPPED 2026-08-22, found while checking the 0.10.24 deployment before telling the site agent to start - not by a test, and the test that should have caught it is the one that hid it. THE BLOCKER: a table descriptor lives at lazysite/db/tables/<name>.yaml. `lazysite` is a RESERVED ROOT, so the manager's content paths refuse it; WebDAV allows only lazysite/layouts/ ('the rest of lazysite/ is protected'); and no action or tool wrote one. The feature could therefore be started only by somebody with shell access to the docroot, which is nobody it is for. WHY THE TESTS MISSED IT: every fixture hand-wrote the descriptor with `open`, modelling an operator with a shell. The end-to-end proved load-then-read and never proved DECLARE, so the one step that had no path was the one step nothing exercised. A fixture that gives itself access the product does not have is not testing the product. SECOND, SMALLER FAULT, same root: manage_data's descriptor advertised `lazysite/db/tables/<table>.yaml` under webdav - a path the front door denies. That is SM435's defect exactly (a descriptor claiming what enforcement refuses), and t/lint/68 exists for it on that plane. The claim is removed. THE RESERVED ROOT IS NOT LOOSENED and that is the design point: lazysite/ holds the account store, the session secret and the ACLs, and the guard keeping a generic write channel out of it is doing its job. What was missing is a NAMED door - one action, capability-gated, writing one kind of file to one place. SHIPPED: data-table-save on the control API, save_data_table over MCP. IT VALIDATES BEFORE IT WRITES, which a generic file write could never have done: a descriptor that does not load is refused with the loader's own reason rather than stored and failing later at first use, when the author has moved on and it surfaces as 'the table does not work'. It does NOT migrate - writing a descriptor and changing the stored table are two decisions, and the second can be refused in part."
---

# Every door, before this

```datatable
columns: Channel | On `lazysite/db/tables/x.yaml`
widths: 6cm | X
bold: 1
tone: medium
---
Manager content paths | refused - `lazysite` is a reserved root
WebDAV | refused - only `lazysite/layouts/` is writable
MCP `write_file` | refused, same rule
A data action | none existed
**A shell on the host** | works, and is not a channel this product has
```

# Why the tests could not see it

Every fixture wrote the descriptor with `open`. That models an operator with a
shell, and the end-to-end I was proudest of -- load data, see it rendered --
began *after* the table already existed.

So the one step with no path was the one step nothing exercised. A fixture that
gives itself access the product does not have is not testing the product.

The corrected test declares the table through the API and creates no files at
all; `lazysite/db` does not exist when it starts.

# What was built, and what was deliberately not

A **named door**: one action, capability-gated, writing one kind of file to one
place, and validating it first. The reserved root stays exactly as it was --
it holds the account store, the session secret and the ACLs, and the guard that
keeps a generic write channel out of it is doing its job.

Validation is the part a file write could never have given. A descriptor that
does not load is refused with the field, the rule and the value, at the moment
somebody is looking at it.
