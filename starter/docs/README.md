---
title: README
subtitle: Repo documentation
---

# lazysite

Pure Markdown content management for Apache and HestiaCP.

Drop `.md` files in your docroot and they are served as fully rendered HTML
pages - no build step, no CMS, no database. Pages are generated on first
request and cached as static HTML.

## Why lazysite

Most content management approaches force a choice between a dynamic CMS
(database, runtime, security surface) and a static site generator (build
pipeline, toolchain, deploy step). lazysite sits between the two.

Content management
: Write pages in Markdown. Drop files in the docroot. Pages are live
  immediately - no publishing step, no build, no deploy command.

Design and content are separated
: The Template Toolkit layout owns the site design. Content authors work
  only in `.md` files. Designers work only in `view.tt`. Neither needs
  to touch the other's files.

Version control ready
: Everything is a file - Markdown sources, the layout template, the
  processor. The entire site lives in a VCS repository. Content changes,
  design changes, and code changes all have full history.

Fast by default
: Pages are dynamic only on the first request. After that, Apache serves
  plain cached `.html` - no interpreter, no processing, no overhead.
  The best blend of a static site and a dynamic system.

No build or make step
: Write a `.md` file, save it, it is live. Delete the cached `.html` to
  republish after edits. That is the entire workflow.

No database
: Files are the source of truth. Nothing to back up separately, nothing
  to migrate, nothing to corrupt.

Content is portable
: Plain `.md` files are not locked to this system. They work with any
  Markdown processor, any static site generator, any editor. Switching
  tools later does not mean rewriting content.

Works with any deployment workflow
: rsync, git pull, sftp, FTP, scp - however files reach the server,
  lazysite picks them up. It integrates easily into CI/CD pipelines
  or manual workflows equally well.

Cache is transparent
: Generated `.html` files are readable, standard HTML. They can be
  inspected, debugged, or served independently if needed.

Resilient
: If the processor fails for any reason, previously cached `.html` files
  continue to be served unaffected.

Easy to audit
: The processor is a single readable Perl script with no framework
  dependencies beyond three standard Debian packages.

Works alongside static files
: Mix hand-crafted `.html` files and `.md` files in the same docroot
  freely. lazysite only activates when no matching file exists.

## Web server support

lazysite uses standard CGI and error handler mechanisms available in most
web servers.

- Apache 2.4 - supported, HestiaCP installer provided
- Apache without HestiaCP - configure `FallbackResource` manually
- Nginx - use `error_page 403 404` to point to the CGI script
- Any web server with CGI support and configurable error handlers should work

## Motivations

lazysite grew out of a specific frustration with the available options for
managing a small set of sites on a personal hosting infrastructure.

### Starting point: SSI

The starting point was Apache Server Side Includes. SSI is elegant for what
it does - a standard mechanism built into Apache for composing pages from
fragments, with no runtime dependency beyond the web server itself. Header,
footer, navigation as separate files, included at serve time. Fast, simple,
no moving parts.

The problem is content management. SSI handles page composition well but
has nothing to say about how you author or manage the content that goes into
those pages. You end up writing HTML directly, which is fine for templates
but poor for page content. Any non-trivial site accumulates HTML files that
are tedious to write and update.

### What was needed

The requirements that shaped lazysite:

Speed
: Pages should be fast. Not "fast enough" - actually fast. A CGI process on
  every request is not fast. Static file serving is fast. The caching model
  means the CGI fires once per page, then Apache serves static HTML. The
  common case is a file read, not a process fork.

Simplicity
: No database. No admin interface. No framework to learn. No build pipeline
  to maintain. Drop a file, get a page. The entire system is one Perl script
  that can be read and understood in an afternoon.

Markdown
: Content should be written in Markdown. Not because Markdown is perfect,
  but because it is the established lingua franca for structured plain text.
  It works in any editor, versions cleanly in git, and is readable without
  rendering. Pandoc-style fenced divs for the cases where you need a
  styled wrapper without writing HTML.

Control where you want it
: The layout template is a file you own and edit directly. The CSS is your
  CSS. The HTML structure is yours. lazysite renders Markdown into a slot in
  your template - it does not impose a theme, a component model, or a
  styling convention. If you know HTML and CSS you are not constrained.

Sensible defaults
: The parts you do not want to think about should work without configuration.
  Caching. Cache invalidation on file edit. Subdirectory creation with correct
  permissions. A starter 404 page. A starter layout. These should all just
  work on first install.

Same method everywhere
: A page authored for one site should work on any other site running lazysite.
  The front matter format, the fenced div syntax, the URL structure - all
  consistent. Moving content between sites is a file copy.

Version control as the content store
: The entire site - content, templates, variables, processor - lives in a git
  repository. Every change has history. Deploying is a file copy. Rolling
  back is a file copy. No database export/import, no CMS backup, no
  proprietary format.

### Integration with HestiaCP

HestiaCP is the control panel in use on the hosting infrastructure. It has
a web template system that generates Apache vhost configs. lazysite plugs
into this as a named template - apply it to a domain, rebuild, and the
processor and starter files are installed automatically. The same installer
also produces clean configurations for standalone Apache outside HestiaCP.

The HestiaCP integration is additive. lazysite works without it.

### What emerged during development

Several things were not in the original plan but followed naturally:

Remote sources via `.url` files - pulling documentation directly from a
GitHub repository rather than duplicating it. The documentation lives with
the code, the site always shows the current version.

Template Toolkit variables fetched from remote URLs - a version number from
a `VERSION` file, release metadata from a GitHub API endpoint, baked into
the cached page at render time rather than fetched client-side.

The registry system - `llms.txt` and `sitemap.xml` generated from page front
matter, updated automatically when pages are rendered. Adding a new registry
format requires only a template file.

oEmbed - embedding PeerTube and other video providers with a one-line syntax,
the iframe baked into the cache.

The link audit tool - a maintenance utility that emerged from the need to
identify orphaned pages and broken links as the site grew.

The Docker staging workflow - a natural consequence of the file-based
architecture. Stage in a container, rsync the source files to production,
let the cache warm on first visit.

Each of these followed from the same principle: the mechanism should be
simple, the output should be static where possible, and the operator should
retain control.



lazysite suits a specific use case. These alternatives may be a better fit
depending on your requirements.

Hugo
: A static site generator. Build step produces a complete static site from
  Markdown sources. Fast, mature, large ecosystem. Better choice if you want
  a full build pipeline, complex themes, multi-language support, or are
  comfortable with a Go toolchain. No server-side processing after build.

Pico CMS
: A flat-file PHP CMS. Drop Markdown files in a directory and pages appear -
  similar philosophy to lazysite but PHP-based with a plugin ecosystem and
  admin themes. Better choice if you want a richer authoring experience or
  plugins for things like search, without a database. Requires PHP on every
  request.

Jekyll
: Ruby-based static site generator, well-established in the GitHub Pages
  ecosystem. Good choice if your content lives on GitHub and you want free
  hosting with automatic builds on push. Build step required.

WordPress
: Full CMS with database, admin UI, and vast plugin ecosystem. Better choice
  for non-technical authors, multi-user publishing workflows, e-commerce, or
  any site needing dynamic content beyond what static caching provides.

Publii
: Desktop app that generates a static site. Good choice if authors prefer a
  GUI and the site is maintained by one person. No server-side processing.

lazysite is most appropriate when content is managed via VCS, authors are
comfortable with Markdown and a text editor, and the simplicity of no
database and no build step is valued over a richer feature set.

### Migrating from Pico CMS

Pico content migrates directly to lazysite with minimal changes. Pico uses
the same Markdown files with YAML front matter:

```yaml
---
Title: My Page
Description: A short description
---
Content here.
```

To migrate:

- Copy your Pico `content/` files to the lazysite docroot
- Rename `Title:` to `title:` and `Description:` to `subtitle:` in front matter
  (lazysite uses lowercase keys)
- Remove any Pico-specific front matter keys that have no equivalent
- Replace Pico theme templates with a `view.tt` template

A one-liner to lowercase the common front matter keys across all files:

```bash
find public_html -name "*.md" | \
  xargs sed -i 's/^Title:/title:/;s/^Description:/subtitle:/'
```

### Migrating from Hugo

Hugo Markdown content uses the same front matter format. The content files
themselves require no changes. What does need replacing is the Hugo template
system - Hugo uses Go templates, lazysite uses Template Toolkit. The
`view.tt` file replaces your Hugo `baseof.html` or equivalent base template.



- Requests for pages with no matching file trigger Apache's 404/403 handler
- The handler runs `lazysite-processor.pl` which looks for a `.md` or `.url` source file
- If found, the Markdown is converted to HTML and rendered through a
  Template Toolkit layout
- The result is cached as `.html` alongside the source
- Subsequent requests are served directly from the static cache

## Requirements

- Apache 2.4 with CGI support and `FallbackResource` configuration
- Debian / Ubuntu (or any Linux with the Perl modules below)
- `libtext-multimarkdown-perl`
- `libtemplate-perl`
- `libwww-perl` (for remote `.url` sources and oEmbed)
- `JSON::PP` (Perl core - no separate install needed)

HestiaCP is supported with a dedicated installer. For other environments
see the manual installation section below.

## Installation

### HestiaCP

The installer registers lazysite as a HestiaCP web template. Once installed,
apply it to any domain from the control panel and the processor and starter
files are deployed automatically on rebuild.

```bash
git clone https://github.com/OpenDigitalCC/lazysite.git
cd lazysite
sudo bash install.sh
```

Then in HestiaCP:

1. Edit your domain
2. Set the web template to `lazysite`
3. Save and rebuild

### Manual Apache installation

For Apache without HestiaCP, install the Perl dependencies and configure
the vhost manually:

```bash
apt install libtext-multimarkdown-perl libtemplate-perl libwww-perl
```

Copy `lazysite-processor.pl` to your `cgi-bin/` directory and make it executable:

```bash
cp lazysite-processor.pl /var/www/example.com/cgi-bin/
chmod 755 /var/www/example.com/cgi-bin/lazysite-processor.pl
```

Copy the starter files to your docroot:

```bash
mkdir -p /var/www/example.com/public_html/lazysite/templates/registries
mkdir -p /var/www/example.com/public_html/lazysite/themes
cp starter/lazysite.conf           /var/www/example.com/public_html/lazysite/
cp starter/registries/*.tt         /var/www/example.com/public_html/lazysite/templates/registries/
cp starter/404.md                  /var/www/example.com/public_html/
cp starter/index.md                /var/www/example.com/public_html/
```

Add to your Apache vhost configuration:

```apache
DirectoryIndex index.html index.htm
FallbackResource /cgi-bin/lazysite-processor.pl

<Location /lazysite>
    Require all denied
</Location>

<Directory /var/www/example.com/public_html>
    Options -Indexes +ExecCGI
    AllowOverride All
</Directory>
```

Ensure the web server user can write to the docroot:

```bash
chown ispadmin:www-data /var/www/example.com/public_html
chmod g+ws /var/www/example.com/public_html
```

The setgid bit (`s`) ensures new subdirectories created by the processor
inherit the `www-data` group automatically.


## Getting started

### Local development

Clone the repository and run the built-in development server:

    git clone https://github.com/OpenDigitalCC/lazysite.git
    cd lazysite
    perl tools/lazysite-server.pl

Open http://localhost:8080/ to browse the starter site. No Apache
configuration required for local development.

### After installing on a server

1. Install a view from [lazysite-views][views] or write your own `view.tt`
2. Edit `public_html/lazysite/nav.conf` to define your site navigation
3. Edit `public_html/index.md` for your home page content
4. Add pages by dropping `.md` files anywhere in the docroot

Pages are available immediately at their extensionless URL:

    public_html/about.md            -> https://example.com/about
    public_html/services/hosting.md -> https://example.com/services/hosting
    public_html/services/index.md   -> https://example.com/services/

Directory index pages are served when a trailing slash URL is requested.
Create `dirname/index.md` for any directory that needs an index page.

### Using an AI assistant

`starter/docs/ai-briefing.md` (available at `/docs/ai-briefing` on a
running site) covers the full system. Feed it to an AI assistant at the
start of a session to enable help with view design, page authoring, and
configuration without needing to explain the system each time.

In Claude Projects, save it as a project document. For other AI tools,
paste it as context at the start of the conversation.

## Security

### Path traversal

`sanitise_uri` rejects null bytes, `..` path segments, and suspicious
characters before constructing filesystem paths. After construction, each
path is verified with `realpath` to confirm it resolves within `$DOCROOT`.
Symlinks pointing outside the docroot are rejected.

The same check is applied inside `write_html` before any file is written,
guarding against symlink-based overwrite attacks on the cache output path.

### Template Toolkit injection

All values extracted from YAML front matter - including `title`, `subtitle`,
and `tt_page_var` entries - have TT directive markers (`[%` and `%]`) stripped
before entering the template context. `register` list items are stripped at
parse time. This prevents authored content from injecting TT directives into
the rendering pipeline.

### Environment variable interpolation

The `${VAR}` interpolation in `lazysite.conf` is restricted to an explicit
allowlist: `SERVER_NAME`, `REQUEST_SCHEME`, `SERVER_PORT`, `HTTPS`,
`REDIRECT_URL`, `DOCUMENT_ROOT`, `SERVER_ADMIN`. Request-supplied headers (`HTTP_*` variables)
are not interpolated regardless of what appears in `lazysite.conf`.

### Fenced div class names

The class name following `:::` is validated against `/\A[\w][\w-]*\z/` before
use. Blocks with class names containing characters outside word characters and
hyphens are rejected - the content renders without a wrapper div and a warning
is written to the error log.

### oEmbed JSON parsing

oEmbed provider responses are parsed with `JSON::PP` (Perl core module) rather
than regex extraction. The `html` field from the parsed response is injected
into the page. Provider responses are trusted as-is - restrict `%OEMBED_PROVIDERS`
in `lazysite-processor.pl` to known hosts if untrusted providers are a concern in
your deployment.


## Docker

A Docker Compose setup provides a self-contained lazysite environment.
See [Development](/docs/development) for the full Docker workflow.

## Uninstall

    sudo bash uninstall.sh

Removes Hestia template files only. Deployed domain files are not touched.

## File reference

    public_html/
      lazysite/
        lazysite.conf         <- site configuration
        nav.conf              <- navigation (Label | /url format)
        templates/
          view.tt             <- view template
          registries/
            llms.txt.tt
            sitemap.xml.tt
            feed.rss.tt
            feed.atom.tt
        themes/               <- additional themes
      assets/
        css/
        img/
        js/
      cgi-bin/
        lazysite-processor.pl
      404.md
      index.md

## Further reading

- [Configuration](/docs/configuration) - views, nav.conf, lazysite.conf, themes
- [Authoring](/docs/authoring) - Markdown, front matter, TT variables
- [Development](/docs/development) - dev server, troubleshooting, build tools
- [API mode](/docs/api) - raw mode, JSON endpoints, query strings

## Licence

MIT

## AI assistance

lazysite was developed interactively with Claude (Anthropic). Architecture,
design decisions, security review, and deployment were directed by the author.
Claude assisted with code generation, documentation, and iterative refinement
throughout development.

[views]: https://github.com/OpenDigitalCC/lazysite-views
[github]: https://github.com/OpenDigitalCC/lazysite
[tt2docs]: https://template-toolkit.org/docs/
