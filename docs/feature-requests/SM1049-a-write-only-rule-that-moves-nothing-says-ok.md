---
id: SM1049
title: "SM1049: a write-only rule that moves nothing says ok"
subtitle: "A write-only rule on a folder holding a gated subfolder asked the mover to bring the subfolder's private twin back into a document root that already held the folder. The mover refused, rightly, and the reply said partial although nothing was due."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-12
raised-by: inbox 2026-10-12, what a site partner cannot do while building a site (P-10)
area: security
status-note: "SHIPPED (PENDING): a move back into the document root is due only when the private twin holds a file no other gating rule keeps; otherwise acl-set answers ok:true, content_moved 0; a due move that fails stays partial, worded by direction (t/integration/208)."
---

# The report

P-10: a write-only rule on a domain root "returns `ok:false`, kind `partial`,
'content could not be moved out of the document root', although the rule is
stored and in force and nothing needed moving." Asked: "Report `ok:true` when
no move was due."

# The cause

A rule that does not gate (no read list, no draft) brings its path's content
back into the document root (SM286). `_sync_private_store` decided the source
was present when the path's private twin existed. A folder with a gated
subfolder has such a twin - the subfolder's content lives in it - so the mover
was asked to move the whole twin into a document root that already holds the
folder, and refused ("the docroot already holds this path"). Moving it would
have published the gated subfolder, so the refusal was right; the result was
not, because no move was due. The partial's sentence also said "out of" for a
move back in.

t/integration/208 reproduced it on main: the gated subfolder, then a write-only
rule on the domain root, answered `ok:false`, `kind: partial`,
`content_move_failed: 1`.

# The fix

A move back in is DUE when the private twin holds a file that no other rule
keeps from the public - a rule naming the file, or a folder it is in, that
gates (`_acl_gates_public`); a gating site-wide rule keeps everything. When the
twin and the document-root folder both exist and every file in the twin is kept
by another rule, nothing is due: the mover is not asked, and the reply is
`ok:true`, `content_moved: 0`, `content_move_failed: 0`. When something in the
twin is not kept, the move is due and its failure is still `partial`. The
partial's sentence now names the direction ("back into" or "out of"), as the
warning already did (SM529).

# Tests

t/integration/208: the gated subfolder case answers ok and leaves the
subfolder private and unpublished; a folder with nothing private answers ok;
a due move that fails (a gated folder with a stray public copy, ungated) is
still partial, naming the direction. Sabotage: treating every twin as due
fails the first subtest.
