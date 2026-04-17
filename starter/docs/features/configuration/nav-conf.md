---
title: nav.conf
subtitle: Define site navigation as a plain text file.
tags:
  - configuration
  - navigation
---

## nav.conf

The navigation file defines a site navigation structure in plain text.
It is parsed into a TT array variable `nav` available in the view
template and page content.

### Location

    public_html/lazysite/nav.conf

Override the path with `nav_file:` in `lazysite.conf`:

    nav_file: lazysite/custom-nav.conf

The `nav_file` value is relative to the docroot.

### Syntax

    Label | /url
    Parent Label
      Child Label | /child-url
      Another Child | /another

- Each line is `Label | /url` separated by a pipe character
- Lines without a pipe are non-clickable parent labels (URL is empty)
- Indented lines (any whitespace) are children of the preceding
  top-level item
- Lines starting with `#` are comments
- Blank lines are ignored

### TT variable structure

Each nav item is a hash with:

- `label` - the display text
- `url` - the URL (empty string if no pipe)
- `children` - array of child items (each with `label` and `url`)

### Example

    Home | /
    Docs
      Getting Started | /docs/getting-started
      Configuration | /docs/configuration
      API Reference | /docs/api
    Blog | /blog
    About | /about

In the view template:

    [% FOREACH item IN nav %]
    <a href="[% item.url %]">[% item.label %]</a>
    [% IF item.children.size %]
    <ul>
    [% FOREACH child IN item.children %]
      <li><a href="[% child.url %]">[% child.label %]</a></li>
    [% END %]
    </ul>
    [% END %]
    [% END %]

### Notes

- Only one level of nesting is supported - children cannot have
  their own children
- An indented line before any top-level item is treated as a
  top-level item (orphan child)
- If the nav file does not exist, `nav` is an empty array
- [Views](/docs/features/configuration/views) - using `nav` in the
  view template
