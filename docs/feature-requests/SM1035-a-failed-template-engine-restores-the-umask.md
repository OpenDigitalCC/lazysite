---
id: SM1035
title: "SM1035: a template engine that cannot be built leaves the umask as it found it"
subtitle: "When the TT compile directory could not be made, the content renderer and the registries widened the umask to 0002 and died without putting it back."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: SM1012's characterisation of render_content (t/unit/processor/113, n458), the render.pm 107 finding; ruled its own item 2026-10-12
area: processor
status-note: "SHIPPED (0.15.5): render_content and update_registries build their Template object (and the registries' make_path) under eval, restore the umask, then re-throw the same failure; t/unit/processor/126. t/unit/processor/113's record (n458, another stack) pins umask_after 0002 for one case and must change to 0027 when the two meet."
---

# The finding

SM1012's characterisation of `render_content` (t/unit/processor/113, n458)
could not reach one branch, render.pm 107:

    my $tt = Template->new(...)
        or do { umask $old_umask; die "Template error: ..." };

When the compile directory cannot be made, `Template->new` does not return
false: Template::Provider's mkdir dies inside it. So the `or do` never ran, and
the umask `_cache_umask` had set (0002, so a compile cache is group-writable
whichever identity renders first) was left in place. Under CGI the process
ends with the request; a persistent worker, or the next render in the same
process, writes what comes next with the wider umask. The release manager ruled
it its own item, with the instruction that the umask be restored on every path.

The registries' engine (`update_registries`, registries.pm) had the same shape,
with an unguarded `make_path` of the compile directory ahead of it - a second
way to die with the umask widened. Fixed with it.

# The fix

Both build the Template object under `eval` - the registries' `make_path` inside
it too - restore the umask, then re-throw the failure unchanged: the same die,
the same message ("mkdir .../x: File exists at .../Template/Provider.pm ..."
for the case measured). A `Template->new` that returns false (no input was
found that makes it, with these options) still dies with "Template error:" in
render_content and returns quietly in update_registries, as before, umask
restored.

# Tests

t/unit/processor/126, written first and failing on the code before the change
(render_content and update_registries each left 0002): with a compile directory
below a regular file, each still dies, with the same message, and leaves the
umask it found (0027 in the test); a render with a compile directory leaves it
too. The processor unit tests pass. Sabotage (tmp/sab-bak/SM1035/, restored by
cp, checked by cmp), each failing 126: render_content re-throwing before the
restore; render_content swallowing the failure into its other message; the
registries re-throwing without the restore; the registries swallowing the
failure.

# The characterisation record (t/unit/processor/113)

113 and its record are on n458 (the SM1012 stack, n450..n459), not under this
branch, so its record could not be updated here. It pins this defect: case
`tt-compile-dir-is-a-file` records `"umask_after" : "0002"`, every other case
0027. When this branch and that stack meet, that one value changes, deliberately,
to `"0027"` - the record's `died` text is unchanged - and 113 then pins the fix.
Whoever lands the second of the two updates the record (or re-records it with
`LAZYSITE_CHARACTERISE=write` and checks the diff is that one line). After
SM1012's S7 the construction lives in `_tt_engine` (n459): the rebase moves this
change there.
