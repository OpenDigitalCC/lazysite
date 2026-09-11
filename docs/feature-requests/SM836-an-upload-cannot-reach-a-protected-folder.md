---
title: "SM836: an upload into a protected folder is refused as 'Target is not a directory'"
subtitle: "Release manager, 2026-09-10: adding a page to the folder works and only upload fails - because the two take different routes to the same place, and one of them still expects a gated folder to be under the docroot"
brand: plain
standard-margins: true
status: partial
status-note: "FIXED 2026-09-10, reproduced first. action_file_upload's UPFRONT directory check built `$DOCROOT/$rel_dir` and tested -d on it, but protecting a section MOVES it into the private store, so that path is deliberately absent and the upload was refused before any file was examined. It now resolves through Lazysite::Private::resolve_for_write and measures the realpath boundary against whichever root owns the target - the same resolution lazysite-dav.pl already performs for a PUT or MKCOL into a gated section. The per-file gate needed no change: validate_path was already resolving the private store correctly, which is exactly why add-page worked and upload did not. THE SHARED RESOLVER IS BUILT 2026-09-11: Lazysite::Private::write_root answers "which tree owns this write target" once, lazysite-dav.pl and Manager::Upload call it instead of each hand-writing resolve_for_write-then-private_root, and t/lint/128 fails any file outside Private.pm that rebuilds it - verified by putting DAV's old block back, which the lint names by line. Manager::Common keeps using resolve_for_write's path directly, which is the same decision. WHAT REMAINS, stated because a pass must not read as more than it is: a write path that resolves NOTHING - builds "$DOCROOT/$rel" and writes - is the SM418 shape, and no source pattern can tell it from the twenty-nine deliberate docroot-only builds (themes, nav, config under lazysite/). That class still needs review per handler."
---

# What was reported

    10/09/2026, 19:49:10  manager  ui  file-upload
    /Intranet/fileshare/projects/.../Documents/  81.220.87.112  fail
    Reason: Target is not a directory

with the decisive detail alongside it: **add page works, just not upload.**

# Why one worked and the other did not

They take different routes to the same folder.

Protecting a section **moves it out of the docroot** into the private store -
the deploy prints this itself: *"re-applying access rules (moves protected
content out of the docroot)"*. So a gated folder does not exist at
`$DOCROOT/<path>`, on purpose.

`action_file_upload` had two gates, and only one of them knew that:

- **The per-file gate was right.** It calls `validate_path`, which resolves the
  private store through `resolve_for_write` - and the comment above it says so
  in as many words, because an earlier fix put it there.
- **The upfront gate was wrong.** It built `"$DOCROOT/$rel_dir"`, tested `-d`,
  and refused. It exists so a traversal attempt is one clear error rather than
  one per file - a convenience - and it ran first, so the correct gate behind it
  was never reached.

Page creation goes through `Manager::Common`, which resolves the store properly,
which is why the operator saw one work and the other fail on the same folder.

# The fix

The upfront check resolves the target the way every other gated write already
does: `resolve_for_write` decides public or private, and the realpath
containment test is measured against whichever root owns the target rather than
always the docroot. The confinement is unchanged in strength - it is the same
test, against the correct root - and it is deliberately the same resolution
`lazysite-dav.pl` performs for a PUT or MKCOL into a gated section.

# The pattern worth naming

**This is the third time a write path has disagreed with the store about where
a gated file lives**, and each one was found by a person hitting it rather than
by a test:

- SM438: an update to a theme-asset mirror resolved private, answered 204, and
  the bytes landed where nothing serves them - *create worked, update was a
  silent no-op*.
- SM418/SM286: an upload into a gated section wrote a public copy beside
  protected content, half-publishing the section.
- This one: the folder could not be found at all.

Each fix was correct and local. The resolution now happens in
`Manager::Common`, `lazysite-dav.pl` and (as of this filing) `Manager::Upload`,
each in its own words. A fourth write path will get it wrong the same way, and
the failure will again be visible only to whoever tries it.

Worth a shared resolver, or a lint asserting that every write path routes
through one. Not built here - the field is waiting on the fix, and the wider
change wants its own review.

# Related

[[SM286]] (nothing added to nginx - protection is the engine's own job),
[[SM418]] (the traversal fix that put `validate_path` on the per-file gate),
SM438 (the mirror write that resolved to the wrong home).
