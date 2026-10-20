---
id: SM1222
title: "SM1222: the dev server takes extension directories"
subtitle: "The dev server found extensions only in plugins/ beside the docroot. --extensions DIR, repeatable, names others; the dev server only."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-20
raised-by: "the OOM Lab, L-6 (inbox/2026-10-17-oom-lab-findings-for-the-odoo-extension.md); ruled 2026-10-20"
area: tools
status-note: "SHIPPED (PENDING) on n708: tools/lazysite-server.pl --extensions DIR (repeatable), searched in order before plugins/, first wins, symlinks refused; dev server only. t/tools/200."
---

# What was asked

L-6: run from the tree, extensions were found only in `plugins/` beside the docroot,
symlinks were refused, and the copied scripts needed the engine's `lib/` on PERL5LIB.
Ruling 2026-10-20: "an extensions dir, yes, that allows multiple".

# What shipped

- `--extensions DIR`, repeatable. The server checks each before starting: a missing
  directory, or one that is itself a symlink, stops it with a message.
- It hands them to the CGIs it runs as `LAZYSITE_EXTENSION_DIRS`, with
  `LAZYSITE_DEV_SERVER`, and puts the engine's `lib/` on `PERL5LIB`.
  `Lazysite::Paths::dev_extension_dirs` returns them only when the second is set, and
  drops any that is not a real directory, so an installed engine (never started by
  this server) is unchanged and a hand-set list alone widens nothing.
- Read by the extension registry (list, enable, run: `plugin_registry`, whose list
  cache state now includes them), the script finder the form-mail path uses
  (`_find_script`) and the server's own `/cgi-bin/form-handler.pl` route.
- Order: the given directories first, in order, then the docroot's `plugins/`. An
  explicit choice outranks the implicit default, and a development copy can stand in
  for a shipped one. A name in two: the first wins, and a startup line says which.
- Name: the option says extensions (the word the docs, the conf and the ruling use);
  the tree's directory is still `plugins/` until SM1142.
- Docs: starter/docs/development.md.

# Not covered

Three other readers of a script beside the docroot (the PDF export's pandoc.pl, the
setup-link mail in lazysite-auth.pl, Notify's form-smtp lookup) still look only where
they did.
