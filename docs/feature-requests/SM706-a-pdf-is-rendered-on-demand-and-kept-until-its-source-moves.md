---
id: SM706
title: A PDF is rendered on demand and kept until its source moves, and a document may be several files
raised: 2026-08-31
raised-by: release manager
area: plugins
status: shipped
status-note: "SM732 WIRED THE CALLER and the render is reachable. Reopened first because: The composed-document refusal, the may_read part check and the cache are all built and unit-tested - and UNREACHABLE: convert() has no caller on any surface and format=pdf appears nowhere in the tree. What shipped and works is the dependency refusal: a host without md-to-pdf is told so by name and the plugin stays off, proved on edge twice. What does not exist is any way to ASK for a PDF. Needs a decision on where the render is triggered from before any more code."
---

# The request

> we should come back to how pdf files get created, and cached so that they
> dont recreate the same every time, and how partials can be specified to the
> command, as it will take a set of yaml/md files and process in order
> provided. so render on demand, but with non-expiring cache if source
> unchanged. maybe a sum of source, but that may cost same as the the render.
> or just on date comparison - that would be enough - if pdf predates latest
> soource change, re-render.

Two things, and they are the same thing seen twice: **what a document is made
of**, and **when the made thing is stale**.

# Where this stands today

SM694 converts ONE Markdown file, synchronously, inside the request, with a
timeout and a size cap, and throws the result away after serving it. Every
conversion of an unchanged page costs the same as the first - measured at
about 14KB of output for a page in roughly a second, which is not free and is
paid per reader rather than per change.

# The cache: date comparison, and why the release manager is right

The instinct to hash the source and the instinct to compare dates arrive at the
same answer, and the release manager reached the right one for the right
reason: **a checksum of the source can cost what the render costs**, and buys
nothing a timestamp does not.

So: a PDF is stale when it predates the newest of its sources. That is one
`stat` per input against one `stat` of the output.

**Where a timestamp is not enough, and what to do about it.** A date comparison
is wrong in exactly two cases, and both are worth naming rather than
discovering:

- **A restore or a copy** can give a source an OLDER mtime than the PDF built
  from a newer version of it. Content history restores a file; a sync writes
  one with a preserved mtime.
- **The BRAND changed**, not the source. A new logo or template makes every PDF
  in that brand stale, and no page file moved.

Both are answered by widening what counts as a source rather than by hashing:
the brand folder's newest mtime is an input, and any write through the manager
touches the file it wrote. A restore that back-dates a file is the residual
case, and the honest answer is a **Rebuild** button rather than a cleverer
comparison.

# Partials: a document is an ordered list of files

The wrapper already takes several inputs and concatenates them in the order
given. What is missing is a way for a PAGE to say what its parts are. The
obvious shape, and the one consistent with how this engine says everything
else, is front matter on the document itself:

    ---
    title: Annual report
    brand: house
    parts:
      - reports/2026/summary.md
      - reports/2026/accounts.md
      - reports/2026/notes.md
    ---

Which settles the cache question too: **the sources of a PDF are its parts plus
its own file plus its brand folder**, and the newest of those is what the
output is compared against.

# What to settle before building

1. ~~Where the cache lives~~ **`lazysite/cache/pdf/`**: not served.

   **Correction, found while building:** the claim that the cache page already
   swept it was wrong. That sweep clears `lazysite/cache/hosts` - the rendered
   pages - and nothing touches this folder. So the plugin that fills it empties
   it: a **Clear** action on the Plugin Manager page, deleting only the `.pdf`
   files it wrote and reporting how many. That is also the answer to the one
   case a date comparison cannot see (below).
2. ~~Whether a part is ACL-checked~~ **DECIDED by the release manager: REFUSE.**
   A part is a content file with its own rule, so a document naming a file the
   reader may not read is refused - it does not silently omit the part, and it
   does not render it. Omitting would be worse than refusing: the reader gets a
   document that looks complete and is not, and nothing tells them which.

   The cost is accepted with the decision: a document can be BROKEN by someone
   tightening a rule on a file elsewhere, and the person who broke it is not
   the person who sees the refusal. So the refusal must name the part and its
   rule, or the operator is told only that something is wrong.
3. ~~What a partial may itself contain~~ **A flat list.** A part that named its
   own parts would be a recursion needing a depth limit, a cycle check and a
   story about what the cache compares against. None of that buys anything a
   longer list does not.
4. ~~Whether rendering stays in the request~~ **In the request, for now.**
   Caching makes the common case free, which is most of the argument for a
   queue gone; the FIRST render of a long document still blocks, and that is
   what SM666 is for rather than half a queue here.

# Related

[[SM694]] (the converter this extends), [[SM666]] (a persistent runtime, if
rendering ever leaves the request), [[SM579]] (the workflow question, which is
the same "long job in a short request" problem).

# What shipped, and what did not

**Shipped in 0.11.9**, in `plugins/pandoc.pl`, covered by
`t/unit/plugins/41` (eleven sabotages, eleven caught):

- `parts:` in front matter, a flat ordered list, passed to the converter in
  document order;
- every part checked exactly as the document is - inside the docroot,
  Markdown, present - each guard proved by a case only that guard can refuse;
- a part the caller may not read **refuses** the document and names the part;
- the PDF kept in `lazysite/cache/pdf/` and reused while it post-dates every
  input, where the inputs are the document, its parts, and the brand folder;
- **Clear**, so the folder is sweepable.

**Not built, and deliberately:** nothing serves a PDF yet. `convert()` is the
library entry point and has no production caller, so the ACL refusal is proved
by test rather than in the field - the reader's authority arrives as the
`may_read` argument, and the route that will pass it does not exist. The
**Rebuild** button the cache section imagined is not built either; **Clear**
covers the same case for now, one folder rather than one document.

A route is its own filing: it needs the capability question answered (who may
convert what), and it is the point at which SM666 stops being optional for a
long document.
