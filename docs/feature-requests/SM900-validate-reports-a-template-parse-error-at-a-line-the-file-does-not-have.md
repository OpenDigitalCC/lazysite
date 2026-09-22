---
id: SM900
title: "SM900: `validate` reports a template parse error at a line the file does not have"
subtitle: "The 0.14.4 W11 walk: an unclosed `[% IF %]` on file line 11 was reported as `zz-w11-broken.md:7:` and 'input text line 7'; the unclosed fence on the same run was reported at 8, which was right. Two checks on one page, two origins for 'line'. The template check counts in a body that has had the front matter and every code-block line removed before the parser saw it; the fence check adds the front-matter offset back."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-22
raised-by: sites agent, from the W11 walk on the shipped 0.14.4 deb
area: validation
status-note: "FILED, not built. VERIFIED AGAINST THE SOURCE: Lazysite::Validate::_check_fences adds _fm_line_offset($fm) to its line, so a fence is reported at the file line, as reference/validating.md says. The template check is Lazysite::Manager::Common::page_parse_issues, which receives the body with the front matter already stripped (Validate.pm:452; page_parse_refusal does the same strip for the write path), then DROPS every fenced and indented code-block line before handing the text to Template (the @keep loop), and reports the parser's 'line N' as it stands. So N is a line in a text that exists only inside that function: after the front matter, and with the code blocks gone. On a page with a five-line front matter and no code above the fault the two errors are five apart; with a code block above the fault they drift further. The same number reaches the write-path refusal ('the page template does not parse (line N)'), so a manager save and an MCP write_file are told the wrong line too."
---

# What was measured

W11, on the 0.14.4 `lazysite-common` deb, `tools/lazysite-cli.pl validate` on
a page with an unclosed `::: panel` and an unclosed `[% IF foo %]`:

| Check | Reported line | File line | Origin |
| --- | --- | --- | --- |
| `component-fence-unmatched` | 8 | 8 | top of the file — right |
| `template-parse` | 7, "input text line 7" | 11 | after the front matter, code blocks removed — wrong |

`reference/validating.md` says fence lines count from the top of the file. It
says nothing about the template line, because until now nobody had put the
two on one page.

# The mechanism, read from the code

`Lazysite::Validate` strips the front matter, then:

- `_check_fences` counts lines in the body and adds `_fm_line_offset($fm)`
  back (`Validate.pm:124-131`), so the reader's cursor lands on the file line
  — SM488's rule.
- the template check is `Lazysite::Manager::Common::page_parse_issues($body)`
  (`Validate.pm:452`), which first removes every line inside a ``` fence or an
  indented code block (`Common.pm` `@keep`), joins what is left, hands *that*
  text to `Template->process`, and reports the parser's `line N` unchanged
  (`Common.pm:1174`).

So `N` counts lines of a text that exists only inside that function. It is
short by the front matter's length, and shorter again by every code-block
line above the fault.

The write path shares it: `page_parse_refusal` strips the front matter and
calls the same function, and the refusal a manager save or an MCP
`write_file` gets — *"the page template does not parse (line N)"* — carries
the same number.

# What would close it

| Ref | Change | Where |
| --- | --- | --- |
| V1 | `page_parse_issues` keeps, beside `@keep`, the FILE line each kept line came from, and maps the parser's `line N` through it before reporting. The front-matter offset is then a parameter (the validator and the write path both know it), so the reported line is the file line on both surfaces. | `lib/Lazysite/Manager/Common.pm` |
| V2 | One test with a front matter, a code block above the fault and the fault below it, asserting the file line — the case that separates the two origins. | `t/unit/…` |
| V3 | `reference/validating.md` says every line number is a file line, for every check — and a lint that the two checks agree on a page carrying both would keep it so. | docs |

# What is NOT claimed

- That the check is wrong about *whether* the page parses. It is right; only
  the location is off.
- Any occurrence outside the W11 walk. One measurement, on the shipped deb.

# Related

[[SM488]] (line numbers count from the top of the file — the rule the fence
check follows), [[SM492]] (the fence check), [[SM887]] (the `validate` verb
and the skill it ships in).
