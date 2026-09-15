# Validating page source

```
lazysite validate --docroot "$LAZYSITE_SITE" page.md      # one or many files
lazysite validate --json page.md                          # for parsing
lazysite validate --strict page.md                        # warnings count too
```

No server is needed; this reads the file. It is the fastest check there is, and
it should run before any render.

## Exit codes

| | |
| --- | --- |
| 0 | nothing, or warnings only |
| 1 | at least one ISSUE (or with `--strict`, any warning) |
| 2 | bad usage - not a verdict on the page |

An ISSUE means the page is wrong. A WARNING is a judgement the author may have
made deliberately, which is why it does not fail the run: report warnings, do
not refuse to publish over them.

## Pass `--docroot` whenever there is a site

Two checks cannot answer without one, and they say so rather than passing:

- `db-binding-unchecked` - a `db:` table binding whose descriptor could not be
  read. With a docroot it becomes a real answer: the table is missing, or it is
  not published (the second is the one that costs an afternoon - the page shows
  no rows while the API happily returns them).
- `form-binding-unchecked` - whether a named form is bound to a delivery
  handler. Unbound, the form renders and silently does not deliver.

## The kinds you will actually see

**Issues** - the page is wrong:

| Kind | What happened |
| --- | --- |
| `front-matter-unterminated` | `---` opened and never closed; the whole page is front matter |
| `template-parse` | a `[% ... %]` expression the engine cannot parse; every variable on the page renders literally |
| `raw-html-page` | `api:`/`raw:` plus an HTML content type - it serves as plain text |
| `invalid-form-rule` | a word in a field's rules that is not a rule; it is ignored at render time |
| `db-table-missing`, `db-table-not-published` | the binding will render nothing |

**Warnings** - worth saying, not worth refusing:

| Kind | Why it matters |
| --- | --- |
| `component-fence-unmatched`, `fence-close-unmatched` | an unclosed `::: name` stays in the page as literal text. The line number counts from the top of the FILE |
| `document-in-page`, `chrome-in-page`, `style-block-in-page` | a whole HTML document, a `<nav>`/`<footer>`, or a `<style>` block in page content - each belongs to the layout or the theme |
| `hand-authored-form`, `form-mailto`, `form-third-party` | a form that ships dead, leaks an address, or routes visitor data off the instance |
| `form-unnamed`, `form-unbound` | a `:::form` that renders and does not deliver |
| `public-credential`, `public-postcode`, `public-phone` | something that may not be meant to be public |
| `no-title` | no `title:` in front matter |

## Reading the JSON

```json
{ "valid": false, "issues": 1, "warnings": 2,
  "files": [ { "file": "page.md",
    "issues":   [ { "kind": "...", "severity": "issue", "message": "...", "line": 12 } ],
    "warnings": [ ... ] } ] }
```

`severity` and `file` are on each message, so messages from several pages can
be gathered into one list without losing which was which. `line` is present
where the check knows one.
