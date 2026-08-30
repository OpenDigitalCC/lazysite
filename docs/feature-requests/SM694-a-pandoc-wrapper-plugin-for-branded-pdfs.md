---
id: SM694
title: A pandoc-wrapper plugin, so a page can be turned into a branded PDF
raised: 2026-08-29
raised-by: release manager
area: plugins
status: shipped
status-note: "SHIPPED in 0.11.8. plugins/pandoc.pl converts a Markdown page to a branded PDF. IT CALLS md-to-pdf, THE WRAPPER, NOT PANDOC - the release manager corrected an earlier draft that checked for pandoc itself: md-to-pdf is what gets invoked, it depends on pandoc, and it owns the pandoc and XeLaTeX invocation, the templates and the brands. So `bins` declares md-to-pdf; declaring pandoc would let the plugin enable on a host that has pandoc and not the wrapper, which is the state `bins` exists to prevent. The dependency half shipped first in 0.11.7 - a plugin declares `bins` beside `deps`, so SM472's rule (a plugin that cannot run is not enabled) applies to a program as well as a module. THE FOUR EXECUTION DECISIONS are settled and asserted, two of them differently from the plan because the wrapper owns the pandoc command line: the brands base is pinned to the site via MD_TO_PDF_BRANDS (--resource-path and --sandbox cannot be passed through the wrapper, so the bounded root is narrower than the filing assumed and the code says so); a fixed argument list (list-form exec, no shell, and a brand is a NAME matched against the directories that exist - though the brand is chosen in the document's own front matter, which is the wrapper's interface); read authority (converting a page produces a copy of it, so it rides on manage_content and invents no capability); and bounded work (an armed timeout and an input size cap, because there is no queue and it runs in the request). Proved against the real wrapper: md-to-pdf 1.0.20 converts a real page to a real 14KB PDF, and every traversal, extension and brand refusal is measured. ONE RESIDUAL RISK IS RECORDED RATHER THAN CLOSED - see the section below."
---

# The request

> add pandoc-wrapper plugin, which depends on pandoc wrapper being installed,
> brand files can be stored in the files area. when enabled, a function can be
> called to convert whatever md provided to pdf using that function

So: an optional plugin; the heavy dependency stays outside the engine; the brand
assets live where the operator already keeps files; and the capability it adds is
one function - Markdown in, branded PDF out.

# The dependency, and the one thing that is new

## Its dependency is declared, and enabling is refused without it

An earlier draft of this filing said no shipped plugin depends on software
outside the engine, and proposed a three-state enabled/working/missing report.
**Both were wrong.** The release manager corrected it: the data plugin already
declares `deps => [qw(DBI DBD::SQLite YAML::PP)]`, and SM472 already built
exactly the right behaviour around that - *a plugin that cannot run is not
enabled*. Enabling is REFUSED, and the refusal names the missing module and its
Debian package.

SM472's own record says why refusing beats warning, and it was learned
expensively: the data plugin once enabled cleanly on a host without YAML::PP,
listed its empty set of tables happily, and answered HTTP 500 to every attempt
to declare one, because the parser is only reached once there is something to
parse. The field bisected five variations of the request before anyone said the
words "YAML::PP". Every signal was honest and none of them named the cause.

So this plugin declares its dependency and inherits that behaviour. No new
state, no new report, no `lazysite check` probe.

### The one real gap

`_plugin_dep_refusal` checks a dependency by `require`-ing it as a Perl module:

```perl
( my $file = "$m.pm" ) =~ s{::}{/}g;
next if eval { require $file; 1 };
```

**Pandoc is a binary, not a module.** `deps` cannot express it today, so the
extension this plugin needs is a second declaration - an executable, checked for
on PATH and executable, refused the same way and named the same way, with the
same Debian-package hint the module branch already produces.

That is a small, contained change to one function, and it is the ONLY
dependency work this plugin requires. It also pays for itself beyond pandoc:
any future plugin wrapping an external tool gets it.

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

1. ~~An executable form for a plugin's declared dependency~~ **DONE in
   0.11.7**: a plugin declares `bins` beside `deps`, and `_missing_deps`
   refuses to enable it when one is not on PATH, naming it as "a program, not a
   Perl module" so an operator does not go looking for a CPAN package. The
   dependency work for this plugin is finished; what remains below is the
   execution boundary.
2. ~~The bounded root~~ **PARTLY, and honestly**: see the residual risk below.
3. ~~The fixed argument list~~ **DONE**: list-form exec, nothing caller-supplied
   on the command line.
4. ~~Synchronous or queued~~ **SYNCHRONOUS**, with a timeout and a size cap.
   A queue is [[SM666]]/[[SM579]]; half of one here is how a site engine becomes
   a multipurpose tool.
5. ~~Named brand sets or one per site~~ **One folder per site**, one subfolder
   per brand, under the configured `brand_dir`.

# The residual risk, recorded rather than closed

The plan assumed this plugin would drive pandoc and could therefore pin
`--resource-path` and pass `--sandbox`. It drives **md-to-pdf**, which owns the
pandoc invocation and offers no passthrough for either. So:

- **What is bounded**: the brands base, via `MD_TO_PDF_BRANDS`, so a document
  naming a brand cannot pull a template from elsewhere on the host.
- **What is not**: an absolute path - or enough leading `../` - in a document's
  image reference is resolved by pandoc inside the wrapper. Converting is gated
  on `manage_content`, so the author already reads the content tree; the gap is
  between that and arbitrary host files.

The working directory looked like it closed this and does not. **Measured**:
converting the same page from two different working directories embedded the
same relative image both times, because the wrapper resolves relative references
against the *source file's* directory, not the cwd. The scratch directory the
plugin uses buys predictable output, not containment, and the code says so
rather than implying otherwise.

Closing it needs a sandbox flag or an argument passthrough in md-to-pdf, which
is a change to the wrapper, not to lazysite.

# Related

SM472 (a plugin that cannot run is not enabled - the mechanism this uses),
[[SM675]] (a capability whose plugin is off says so), [[SM666]] (a persistent runtime, if conversion is queued),
[[SM693]] (the request-time floor this would sit on top of), the house
diagram/document practice: SVG to PDF via inkscape, never ImageMagick - a
reminder that this project already has opinions about how PDFs get made.

# Shipped

In 0.11.8, against md-to-pdf 1.0.20. `plugins/pandoc.pl` plus
`t/unit/plugins/40-the-pandoc-plugin-stays-inside-its-boundary.t`, which
asserts the four boundary properties and skips cleanly on a host without the
wrapper.
