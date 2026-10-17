---
id: SM1153
title: "SM1153: the extension-list cache follows the extensions directory"
subtitle: "The cached list records what it was built from and is used only while that is unchanged; an empty list for a missing directory is not kept."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: lazysite-sites agent (oom-lab, L-5), accepted by the release manager 2026-10-17
area: manager
status-note: "SHIPPED on n642: lib/Lazysite/Manager/Plugins.pm action_plugin_list; t/unit/lib/203."
---

# What happened

From the oom-lab findings (L-5, "enabling extensions"):

> The extension-list cache (`lazysite/cache/plugin-list.cache`) kept an EMPTY
> list after `plugins/` appeared beside the docroot, until deleted by hand.
> Minor; a dev-server set-up path.

`action_plugin_list` trusted the cache for 60 seconds on the file's age alone.
A set-up that listed extensions before `plugins/` existed, then created it, was
told there were none.

# What shipped

- The cache records the state of what the list is built from: whether
  `plugins/` exists and its mtime, and each registered script's name, size and
  mtime. It is used only while that state is unchanged, so a directory
  appearing, a script added, removed or replaced is seen at once.
- While the extensions directory is missing the list is built for the request
  and not kept (and an older cache file is removed), so an empty list never
  outlives the request that built it.
- A list built from a real directory is cached as before, and an unchanged
  directory leaves the cache file alone.

How the dev server finds extensions is untouched (the `plugins/` beside the
docroot; L-6 is SM1142's).

t/unit/lib/203 lists with no directory, creates it, and lists again; then adds
and removes a script. It failed four assertions before the change.
