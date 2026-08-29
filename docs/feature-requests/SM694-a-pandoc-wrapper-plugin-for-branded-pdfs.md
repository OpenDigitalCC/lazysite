---
id: SM694
title: A pandoc-wrapper plugin, so a page can be turned into a branded PDF
raised: 2026-08-29
raised-by: release manager
area: plugins
status: partial
status-note: "PARTIAL - the DEPENDENCY half shipped in 0.11.7 (a plugin declares `bins` beside `deps` and is refused enabling when the program is absent, named as "a program, not a Perl module"). THE PLUGIN ITSELF IS NOT BUILT: the execution boundary - a bounded root for what the Markdown may reference, a fixed argument list with nothing caller-supplied reaching pandoc, the read authority required to convert a page, and whether conversion is synchronous or queued - is still design work. OPEN. A plugin that, when enabled, exposes a function converting supplied Markdown to PDF through an installed pandoc wrapper, with brand files kept in the site's own files area. THE DEPENDENCY QUESTION IS ALREADY ANSWERED: SM472 built `a plugin that cannot run is not enabled` - a plugin declares `deps`, enabling is REFUSED when one is missing, and the refusal names the module and its Debian package. This plugin uses that, and needs ONE contained extension to it: `_plugin_dep_refusal` checks deps by `require`-ing them as Perl modules, and pandoc is a BINARY, so the declaration needs a second form - an executable checked on PATH, refused and named the same way. WHAT STILL NEEDS DESIGN is the execution side: a bounded root for anything the Markdown may reference, a fixed argument list with nothing caller-supplied reaching pandoc, the read authority required to convert a page (or it is an ACL bypass with a nice output format), and whether conversion is synchronous or queued."
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
2. The bounded root for anything the Markdown may reference.
3. The fixed argument list, with nothing caller-supplied reaching pandoc.
4. Whether conversion is synchronous or queued, which depends on [[SM666]].
5. Named brand sets or one per site.

# Related

SM472 (a plugin that cannot run is not enabled - the mechanism this uses),
[[SM675]] (a capability whose plugin is off says so), [[SM666]] (a persistent runtime, if conversion is queued),
[[SM693]] (the request-time floor this would sit on top of), the house
diagram/document practice: SVG to PDF via inkscape, never ImageMagick - a
reminder that this project already has opinions about how PDFs get made.

# Not started
