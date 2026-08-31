---
id: SM706
title: A PDF is rendered on demand and kept until its source moves, and a document may be several files
raised: 2026-08-31
raised-by: release manager
area: plugins
status: candidate
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

1. **Where the cache lives.** `lazysite/cache/pdf/` is the obvious place - not
   served, already swept by the cache page. It must be swept: a stale PDF that
   nothing can clear is worse than a slow one.
2. **Whether a part is ACL-checked.** A part is a content file with its own
   rule. A document that includes a file the reader may not read must refuse,
   or the PDF becomes a way to read around an ACL. This is the one part of this
   filing that is a security question rather than a performance one.
3. **What a partial may itself contain.** A part that names its own parts is a
   recursion, and needs a depth limit or a flat rule.
4. **Whether rendering stays in the request.** Caching makes the common case
   free, which weakens the argument for a queue - but the FIRST render of a
   long document still blocks. Related to SM666 and SM579.

# Related

[[SM694]] (the converter this extends), [[SM666]] (a persistent runtime, if
rendering ever leaves the request), [[SM579]] (the workflow question, which is
the same "long job in a short request" problem).
