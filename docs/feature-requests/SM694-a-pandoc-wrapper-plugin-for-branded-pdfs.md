---
id: SM694
title: A pandoc-wrapper plugin, so a page can be turned into a branded PDF
raised: 2026-08-29
raised-by: release manager
area: plugins
status: candidate
status-note: "OPEN. A plugin that, when enabled, exposes a function converting supplied Markdown to PDF through an installed pandoc wrapper, with brand files kept in the site's own files area. TWO THINGS DECIDE THE SHAPE: (1) it depends on software OUTSIDE the engine, which no shipped plugin currently does, so 'enabled' must mean 'enabled AND the wrapper is actually there' or the operator gets a button that fails at use; (2) it runs an external binary on operator-supplied input, which is a different risk class from every other plugin - the brand files and the Markdown are both inputs to a process, and pandoc's own feature surface includes reading files and running filters."
---

# The request

> add pandoc-wrapper plugin, which depends on pandoc wrapper being installed,
> brand files can be stored in the files area. when enabled, a function can be
> called to convert whatever md provided to pdf using that function

So: an optional plugin; the heavy dependency stays outside the engine; the brand
assets live where the operator already keeps files; and the capability it adds is
one function - Markdown in, branded PDF out.

# Why this one is different from every plugin shipped so far

## It depends on something the engine cannot install

No shipped plugin needs software outside the install. This one is useless
without a pandoc wrapper, and pandoc pulls a LaTeX toolchain behind it - which
on this host is exactly the sort of thing the engine cannot put there itself.

That makes **"enabled" ambiguous**, and the ambiguity is the defect waiting to
happen: an operator ticks the box, the button appears, and the first person to
press it gets a failure that looks like a bug in the site. The plugin must
report three states, not two:

| State | What the operator should see |
| --- | --- |
| Not enabled | The plugin is off |
| Enabled, wrapper absent | **Enabled but not working**, naming the wrapper it looked for and where |
| Enabled, wrapper present | The version it found |

[[SM675]] just built the vocabulary for the analogous case - a capability whose
plugin is off says so rather than offering a checkbox that grants nothing. The
same argument applies one level out: a plugin whose dependency is missing should
say so where the operator is looking, not at the moment of use.

`lazysite check` is the natural second home for that probe, since it already
reports health an operator can act on.

## It runs an external binary on supplied input

Every other plugin manipulates data inside the engine. This one hands operator
content to a separate program and returns what that program produced. The
questions that follow are not rhetorical and should be answered before it is
built:

- **What may the Markdown reference?** Pandoc resolves image and include paths.
  A conversion that reads whatever path the Markdown names is a file-read
  primitive with the CGI's privileges. The brand files living in the files area
  is the right instinct - it suggests a bounded root - and that boundary should
  be explicit rather than incidental.
- **Which pandoc features are off?** `--filter` and friends execute programs.
  A wrapper that passes user-supplied options through is a command-execution
  primitive. The wrapper's argument list should be built by the plugin, never
  taken from the caller.
- **Who may call it?** A PDF of a page is a copy of that page's content, so the
  conversion should require the same read authority as the content itself. If a
  gated page can be converted by somebody who may not read it, the plugin is an
  ACL bypass with a nice output format.
- **What bounds the work?** PDF generation is slow and memory-hungry compared to
  everything else the engine does, and the measured floor for an ordinary
  request is already 69.8 ms ([[SM693]]). A synchronous conversion on the
  request path is a denial-of-service surface; a queued one needs somewhere to
  put the job, which is [[SM666]]'s territory.

None of these is a reason not to build it. They are the reasons it wants a
design pass rather than being written directly.

# Brand files in the files area

The right call, and worth stating why so it survives: brand assets are content
an operator maintains - a logo changes, a cover colour changes - and content
belongs where they already edit content, with the ACLs, history and WebDAV
access that come with it. A separate hidden store would need its own editor, its
own permissions and its own backup story.

It also gives the conversion a natural bounded root: the site's own files, which
the caller already has authority over.

Worth deciding: whether brand assets are one set per site or selectable per
conversion. The house style elsewhere is that a brand is named (`brand: xisl`,
`brand: odcc`), which suggests named brand sets rather than one implicit set.

# The function

One call, taking Markdown and a brand, returning a PDF. Two shapes to choose
between:

- **A page action** - convert THIS page, which is what most operators want and
  which makes the ACL question answer itself (the caller already reads the
  page).
- **A content function** - convert supplied Markdown, which is what the request
  says and is more general, but hands the ACL question back to the caller.

They are not exclusive; the first can be a thin caller of the second. If both
exist, the second is the one that needs the boundary work.

# What to settle before building

1. The three-state enabled/working/missing report, and where it surfaces.
2. The bounded root for anything the Markdown may reference.
3. The fixed argument list, with nothing caller-supplied reaching pandoc.
4. Whether conversion is synchronous or queued, which depends on [[SM666]].
5. Named brand sets or one per site.

# Related

[[SM675]] (a capability whose plugin is off says so - the same argument one
level out), [[SM666]] (a persistent runtime, if conversion is queued),
[[SM693]] (the request-time floor this would sit on top of), the house
diagram/document practice: SVG to PDF via inkscape, never ImageMagick - a
reminder that this project already has opinions about how PDFs get made.

# Not started
