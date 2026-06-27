---
title: "SM116 - readable dark colour scheme for the content editor"
subtitle: "CodeMirror's Markdown highlighting is hard to read on the dark surface"
brand: plain
---

## What

In dark mode the file/content editor (CodeMirror) now has a dark background (SM109
phase 6b), but the **syntax-highlight colours** are the bundled light-theme palette,
which is hard to read on the dark surface. Give the editor a proper dark colour scheme
- a Markdown-appropriate token palette (headings, emphasis, links, code, lists) tuned
for contrast on the dark background, applied under `[data-theme="dark"]`.

## Why

Raised 2026-06-27. "Edit content in dark is hard to read - find alternative colour
scheme for markdown edit in dark." The structural dark (bg/text/gutters/cursor) landed
already; this is the token colours.

## Shape

- Define `[data-theme="dark"] .cm-*` token colours (cm-header, cm-strong, cm-em,
  cm-link, cm-url, cm-quote, cm-comment, cm-string, cm-variable, etc.) from a
  legible dark palette (e.g. One Dark / a tuned set), referencing tokens where it
  helps. Keep light mode on the existing bundled theme.
- Verify against a representative Markdown file (headings, bold/italic, links, code
  fences, lists, front matter) in both modes.

## Status

**SHIPPED in v0.4.36.** (see CHANGELOG)


Queued. Bounded CSS (a dark CodeMirror token palette under [data-theme=dark]); no JS.
Follows the structural dark-editor support already shipped.
