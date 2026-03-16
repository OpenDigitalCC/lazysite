# Page Authoring and Template Integration Guide

## Overview

Pages on this site are written in Markdown and processed automatically into
HTML. There is no manual publishing step. Drop a `.md` file in the docroot
and the page is available immediately at its extensionless URL.

The HTML is generated on first request and cached alongside the source file.
Subsequent requests are served directly from cache. If you edit a `.md` file,
delete the corresponding `.html` file to force regeneration.


## Writing Pages

### File location

Markdown files live in the docroot alongside the generated HTML:

```
public_html/
  about.md          <- source
  about.html        <- generated cache (do not edit)
  services/
    hosting.md
    hosting.html
```

### URL mapping

The URL is the file path without extension:

```
public_html/about.md             -> https://example.com/about
public_html/services/hosting.md  -> https://example.com/services/hosting
public_html/index.md             -> https://example.com/
```

Always link to pages without extensions:

```html
<a href="/about">About</a>
<a href="/services/hosting">Hosting</a>
```


## Page Structure

Every `.md` file must begin with a YAML front matter block:

```markdown
---
title: About Us
subtitle: Who we are and what we do
---

Page content starts here.
```

The front matter block is delimited by `---` lines and must be at the very
top of the file. The following fields are supported:

title
: The page title. Appears in the browser tab and the page header.
  Required - leave blank for untitled pages.

subtitle
: A short description shown below the title. Optional.


## Markdown

Standard Markdown is supported. A brief reference:

```markdown
## Section heading

### Subsection heading

A paragraph of text. **Bold** and *italic* inline.

- Unordered list item
- Another item
  - Nested item

1. Numbered list
2. Second item

[Link text](/page-url)

![Alt text](/assets/image.jpg)

> Blockquote text

`inline code`
```

Code blocks with language highlighting:

    ```javascript
    const x = 1;
    ```


## Styled Divs

Sections of content can be wrapped in named div elements for CSS styling.
Use the fenced div syntax:

```
::: classname
Content here. Standard Markdown works inside.
:::
```

This produces:

```html
<div class="classname">
<p>Content here. Standard Markdown works inside.</p>
</div>
```

The class name maps directly to a CSS class. Available classes are defined
in the site stylesheet. Any class name is accepted by the processor - work
with the site designer to agree class names before use.

Common classes:

- `widebox` - full-width coloured band
- `textbox` - 60% width highlighted box
- `marginbox` - margin pull quote
- `examplebox` - evidence or example highlight

Example usage:

```markdown
::: widebox
This statement spans the full width of the content area.
:::

Regular paragraph text continues here.

::: marginbox
"A short pull quote"

Source attribution
:::
```


## The 404 Page

The file `public_html/404.md` is the not-found page. It is written and
maintained like any other page:

```markdown
---
title: Page Not Found
subtitle: The page you requested could not be found
---

## Nothing here

The page you were looking for doesn't exist.
Try the navigation above or return to the [home page](/).
```

Delete `404.html` to regenerate it after edits.


## Cache Management

Generated `.html` files are cached in the docroot alongside their `.md`
source. The processor regenerates a page when the `.md` file is newer than
the `.html` file.

To force regeneration of a single page:

```bash
rm public_html/about.html
```

To force regeneration of all pages (for example after a template change):

```bash
find public_html -name "*.html" -delete
```


## For Site Designers: Template Integration

The processor uses a single Template Toolkit layout file to wrap all
generated content. The layout lives at:

```
public_html/templates/layout.tt
```

This file is the integration point. Replace the basic HTML in this file
with the full site design - navigation, header, footer, stylesheet links,
scripts, and so on.

### Available variables

The following variables are passed to the template for every page:

`[% page_title %]`
: The title from the page YAML front matter.

`[% page_subtitle %]`
: The subtitle from the page YAML front matter. May be empty.

`[% content %]`
: The converted page body as HTML. Output unescaped with `[% content %]`.

### Minimal template structure

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>[% page_title %]</title>
    <link rel="stylesheet" href="/assets/css/site.css">
</head>
<body>

<header>
    <nav>
        <a href="/">Home</a>
        <a href="/about">About</a>
    </nav>
    <h1>[% page_title %]</h1>
    [% IF page_subtitle %]
    <p class="subtitle">[% page_subtitle %]</p>
    [% END %]
</header>

<main>
[% content %]
</main>

<footer>
    <p>&copy; 2026 Example Ltd</p>
</footer>

<script src="/assets/js/site.js"></script>
</body>
</html>
```

### Template Toolkit reference

The template language is [Template Toolkit][tt2]. Key syntax:

```
[% variable %]                      Output a variable
[% IF condition %] ... [% END %]    Conditional block
[% INCLUDE filename %]              Include another template file
[% # comment %]                     Comment
```

Full documentation at [https://template-toolkit.org/docs/][tt2docs].

### After changing the template

Delete all cached `.html` files to force regeneration:

```bash
find public_html -name "*.html" -delete
```

Pages regenerate automatically on next request.


## File Reference

```
public_html/
  templates/
    layout.tt         <- site template (edit this)
  cgi-bin/
    md-processor.pl   <- processor (do not edit)
  404.md              <- not-found page source
  404.html            <- not-found page cache
  index.md            <- home page source
  index.html          <- home page cache
```

[tt2]: https://template-toolkit.org/
[tt2docs]: https://template-toolkit.org/docs/
