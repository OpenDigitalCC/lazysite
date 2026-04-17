---
title: lazysite Feature Test
subtitle: Validates all processor features and serves as a live demonstrator
ttl: 60
register:
  - llms.txt
  - sitemap.xml
tt_page_var:
  page_greeting: Hello from a page variable
  page_base_url: https://example.com/downloads
---

## Test results key

A passing test shows the resolved value. A failing test shows a literal
`[% tag %]` or broken markup.

---

## 1. Site variables

These come from `lazysite/lazysite.conf` and are available on every page.

- site_name: [% site_name %]
- site_url: [% site_url %]
- version (remote fetch): [% version %]

**Expected:** resolved values, not literal tags.

---

## 2. Page variables (`tt_page_var`)

Defined in this page's front matter.

- page_greeting: [% page_greeting %]
- page_base_url: [% page_base_url %]

**Expected:** `Hello from a page variable` and `https://example.com/downloads`.

---

## 3. TT concatenation

<div>[% filename = "release-" _ version _ ".tar.gz" %][% full_url = page_base_url _ "/" _ filename %]</div>

- filename: [% filename %]
- full_url: [% full_url %]

**Expected:** `release-VERSION.tar.gz` and full URL with base and filename joined.

---

## 4. TT conditional

<div>[% IF version %]Version is set: [% version %][% ELSE %]Version is not set.[% END %]</div>

**Expected:** "Version is set:" followed by the version number.

---

## 5. HTML link with TT variable in href

<a href="[% page_base_url %]/file.tar.gz">Download file</a>

**Expected:** a working link with the full URL, not a literal tag.

---

## 6. Markdown headings

## H2 heading
### H3 heading
#### H4 heading

**Expected:** rendered headings at correct levels. H1 is reserved for the
page title in the layout.

---

## 7. Markdown text formatting

**Bold text**, *italic text*, `inline code`, ~~strikethrough~~.

> Blockquote paragraph.

**Expected:** all formatting applied correctly.

---

## 8. Markdown lists

Unordered:

- Item one
- Item two
  - Nested item
  - Another nested

Ordered:

1. First
2. Second
3. Third

---

## 9. Markdown table

| Feature | Status | Notes |
| ------- | ------ | ----- |
| Site vars | Working | From lazysite.conf |
| Page vars | Working | From tt_page_var |
| Tables | Working | Via Text::MultiMarkdown |
| Code blocks | Working | Pre-processed before TT |

**Expected:** a rendered table with borders/styling.

---

## 10. Fenced code block

```bash
#!/bin/bash
echo "Hello from a code block"
echo "Version: [% version %]"
curl -sO [% page_base_url %]/file.tar.gz
```

**Expected:** the `[% ... %]` tags inside the code block should appear
literally - code blocks are protected from TT processing.

---

## 11. Fenced code block with multiple languages

```perl
my $version = "[% version %]";  # should be literal
print "Hello from Perl\n";
```

```yaml
version: [% version %]  # should be literal
site: lazysite
```

**Expected:** both blocks render as code with literal TT tags preserved.

---

## 12. Fenced div (styled block)

::: widebox
This content is inside a `widebox` div. The class maps to a CSS rule in
the site stylesheet.
:::

::: textbox
This content is inside a `textbox` div.
:::

**Expected:** content wrapped in `<div class="widebox">` and
`<div class="textbox">`.

---

## 13. Definition list with HTML link in dt

<dl>
<dt><a href="[% page_base_url %]/release-[% version %].tar.gz">release-[% version %].tar.gz</a></dt>
<dd>A test file entry using TT variables in both the link href and text.</dd>
<dt><a href="https://example.com/static">Static link</a></dt>
<dd>A definition list entry with a plain static link.</dd>
</dl>

**Expected:** both `<dt>` entries render as working links with resolved
version numbers.

---

## 14. Markdown link (internal)

[Back to home](/)

[Docs section](/docs/)

**Expected:** clean links without extensions.

---

## 15. Markdown link (external)

[lazysite on GitHub](https://github.com/OpenDigitalCC/lazysite)

**Expected:** working external link.

---

## 16. Image

**Expected:** an `<img>` tag. The image may not exist - a broken image
icon is acceptable here.

---

## 17. Inline HTML passthrough

<div class="custom-class">
This paragraph is inside a raw HTML div. Markdown <strong>bold</strong>
inside an HTML block may not render depending on the parser.
</div>

**Expected:** the div renders, strong may or may not apply.

---

## 18. Remote page variable (url: prefix)

If configured in front matter with `url:`, a remote value would appear here.
This test uses a static value to confirm the pipeline works without a network
dependency.

- page_greeting (static): [% page_greeting %]

**Expected:** `Hello from a page variable`.

---

## Summary

If all sections above show resolved values rather than literal `[% tags %]`,
the processor is working correctly. Code blocks (section 10 and 11) should
show literal tags - that is correct behaviour.
