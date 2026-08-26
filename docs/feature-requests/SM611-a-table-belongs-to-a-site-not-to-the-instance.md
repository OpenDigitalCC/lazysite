---
title: "SM611: a data table should belong to a site, with an instance-wide table as the deliberate exception"
subtitle: "SM593 confined who may reach a table. The table still lives in one instance-wide store and one instance-wide namespace, so \"this domain's data\" is not something the engine can compute."
brand: plain
standard-margins: true
status: candidate
status-note: "PROPOSED BY THE OPERATOR 2026-08-26, to follow SM593's field validation: attach a database to the site it serves, and keep an instance-wide database as a FEATURE rather than the only option, so one install can carry both shared tables and site-specific ones. THE DISTINCTION FROM SM593 IS THE WHOLE REQUEST. SM593 made `domain:` a LABEL that governs who may reach a table; the rows still live in one file, `lazysite/db/data.sqlite`, and the table name is still instance-unique because the descriptor's filename IS the name. So today two clients on one instance cannot both have a table called `orders`, a compromise of the store reaches every client's rows, and deleting a site leaves its data behind. This proposes making ownership STRUCTURAL rather than declared. THE ARGUMENT IS ALREADY WRITTEN IN THE CODE, which is why this is worth doing rather than merely tidy. site-backup-create takes `data_tables` as a LIST THE OPERATOR NAMES, and the comment says why: 'the data store is instance-wide, so this domain's data does not exist and a flag would sweep another domain's tables into an artefact that travels between organisations' (DP-6). That workaround exists precisely because the engine cannot answer the question this request would make answerable. Under per-site attachment a site package carries its own data by construction, safely; deleting a site takes its data with it; and two clients may both have `orders`. WHAT IT COSTS. (1) STORE RESOLUTION: every read and write must answer 'which store?' - the binding path, the manager surface, MCP, the data endpoint and the form handlers. Tables.pm alone resolves a store or a descriptor directory in 15 places, Manager::Data in 7. SM578 is the standing warning here: four package verbs each carried their own copy of one rule and two were missed, so this wants ONE resolver every caller asks, written before anything moves. (2) PRECEDENCE: if a site declares `orders` and the instance also does, which does a page get? That is a decision to take up front, not to discover. (3) MIGRATION: existing rows are in the shared file and moving them is a data migration on a store carrying live customer data - it must take a safety export first, and it is the risky half of this work, not the mechanism. (4) SM593's `domain:` KEY either becomes the attachment or is superseded by it, which is an argument for doing this SOON after SM593 is validated rather than long after, while few descriptors carry the key. RECOMMENDED SHAPE, for the operator to take or leave: a table is site-attached by default and names its site the way SM593 already does; an instance-wide table says so explicitly (`scope: instance`), because the shared case is the exception and exceptions should be the thing that is written down. NOT FOR 0.11.0. This is a feature and the operator's freeze holds; it also touches the data core the jpm-stock app runs on, so it wants a release of its own with the migration rehearsed."
---

# What is structural today, and what is only declared

| | Today | Proposed |
|---|---|---|
| Rows | one file, `lazysite/db/data.sqlite` | one store per site, plus an instance store |
| Table name | instance-unique (the filename is the name) | unique **within its site** |
| `domain:` | a label governing who may reach it (SM593) | the attachment itself, or superseded by it |
| "this domain's data" | not computable | the ordinary case |

# The workaround that documents the need

```perl
# DP-6: `data_tables` is a LIST the operator names, not a boolean. The
# data store is instance-wide, so "this domain's data" does not exist and a
# flag would sweep another domain's tables into an artefact that travels
# between organisations.
```

An operator enumerating tables by hand to back up their own site is doing
work the engine should be able to do for them, and the comment says exactly
why it cannot.

# What has to be decided before anything moves

- **Precedence** when a site and the instance both declare a name.
- **One resolver.** Tables.pm resolves a store or descriptor directory in
  15 places and Manager::Data in 7. SM578 is the warning: four verbs each
  holding their own copy of one rule, two of them missed.
- **The migration**, which is the risky half. Live rows, a safety export
  first, and rehearsed before it is offered.
