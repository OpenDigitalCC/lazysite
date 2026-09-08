---
id: SM780
title: "SM780: the plugin stamps who wrote the row"
subtitle: "Filed from familyhq.explore to finish what SM777 starts: a created_by / updated_by stamped from the authenticated actor, reserved from every writer on the same terms as the timestamps. The row audit knows the actor and is behind the audit capability, one query per row, which no page can use; the value a page renders sat in a free-text column beside it. A half-stamped row invites more confidence than an unstamped one, because the honest half vouches for the forgeable half."
brand: plain
standard-margins: true
status: shipped
status-note: "BUILT 2026-09-08 on claude/sm780-the-plugin-stamps-who-wrote-the-row (on top of SM777, landed). Under the same timestamps flag: created_by on insert, updated_by on update, from the actor every write path passes (the manager, the control API and MCP through action_data_row_save's $auth_user; a connector's kept answer; the CSV import and the safety-export restore); empty when the writer was not a signed-in account. Reserved from the payload with the same refusal. The plugin's own columns are now ADDITIVE in the migration plan - a table that had the flag before the author columns existed, or gains the flag later, gets them from data-migrate, nullable and unfilled. The descriptor note covers *_by fields. t/unit/data/61 proves insert, update, forge refusal, the empty author, the import and the additive migration; the whole data suite passes."
---

# What the field asked

`created_by` / `updated_by` beside SM777's stamps: from the authenticated
actor, reserved from every writer, under the same flag, the login as the
stored value, the same descriptor note for a look-alike `*_by` field.

# What was true, beyond the ask

The migration plan walked declared fields only, so the plugin's own columns
were never additive: a table made without the flag and given it later
never gained `created_at`/`updated_at` - the flag was a promise the store
could not keep. Adding two more reserved columns made that visible, and it
is fixed the same way for all four.

# What is built

- `Tables.pm::_stamp` takes `actor`; `insert_row`, `update_row` and
  `import_rows` accept `actor => login`. `created_by` on insert,
  `updated_by` on every write; `undef` when there is no actor - a public
  form's row says nobody, never a guess.
- Every caller that knows an actor passes it: `action_data_row_save`
  (manager, control API, MCP share it, through `$auth_user`), the CSV
  import, the safety-export restore, a connector's kept answer (the
  connector's actor).
- The reserved set is four names everywhere it is read: `Descriptor.pm`,
  `Value.pm`, `Schema.pm`, `SQLite.pm`, `Query.pm`, `Csv.pm`, `Tables.pm`.
- `Schema.pm::plan_migration`: a reserved column the flag wants and the
  store lacks is an additive step (`add_reserved_column_sql`, TEXT,
  nullable, no backfill).
- The descriptor note names `*_by` fields with `*_at` ones and lists all
  four columns; `/docs/data-tables` says what the flag adds and that an
  older table gains the columns by migration.

# Dependency, as the field named it

A stamped login is half a byline; turning a login into a display name for
anyone but the viewer is SM778 (held for the release manager). Until it
lands a site renders the login, which is the truth the engine holds.
