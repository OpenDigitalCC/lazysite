---
id: SM871
title: "SM871: a double quote inside a form field's value: literal truncates the value, and the remainder is parsed as further rules"
subtitle: "The rule tokeniser matches `name:\"([^\"]*)\"`, which stops at the first inner quote. So `value:\"before \\\" x\"` yields `before \\` - and the text after the truncation point is then tokenised as more rules, so a stray quote can silently switch on `required` or change `max`. The output is safe; the value and the field's behaviour are not what the author wrote."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-09-27 for 0.15.0, with one of this filing's own claims corrected. The quoted form is now `\"((?:[^\"\\\\]|\\\\.)*)\"` and only `\\\"` is unescaped afterwards - NOT every backslash, which is load-bearing: `pattern:` values carry regex escapes, and unescaping all of them would turn `\\d` into `d` and silently break every pattern in the tree. t/unit/forms/18 holds that as its own subtest. THE CORRECTION: this filing's headline example - `value:\"a\" required\"` sets `required` - does not reproduce. The flags are compared with `eq`, so the leftover token `required\"` matches nothing and is dropped. The hazard is real but it lands on the VALUED rules, which are matched with an unanchored regex; measured, `max:5\"` sets max, `min:2\"` sets min, `pattern:x\"` sets pattern. So the sharp case is `value:\"a \\\" max:5\"`, where a default value silently capped the field, and that is the subtest the sabotage proves. AN UNCLOSED QUOTE NOW WARNS and otherwise behaves exactly as before - the chunk is still tokenised on whitespace, deliberately, because abandoning the rest of the line would let a `required` written after a malformed value become optional, which is a form weakening itself over a typo. Sabotage-proved by restoring the old regex: four assertions fail, the invented maxlength among them. The trade is recorded at the code - a value whose last character is a backslash now reads as unclosed, which is the correct reading once `\\\"` means a quote, and it is warned about rather than silent. starter/docs/forms.md documents the escape."
raised: 2026-09-12
raised-by: site agent (1315B, found while attacking SM856)
area: forms
---

# What was found

The site agent, while trying to break SM868's fix rather than confirm it:

> "A `value:` literal containing an escaped double quote is **silently
> truncated**. Given `value:\"before \\\" onfocus=\\\"...\" x\"`, the rendered
> attribute is `value=\"before \\\"`. The value ends at the `\\\"` and the
> remainder is discarded, with no warning. The **output is safe** - the
> attribute is closed and nothing is injected - so this is a correctness and
> diagnostics point, not a security one."

They are right on all three counts, and the fault is worse than "discarded".

# Reproduced, and the remainder is not discarded - it becomes rules

`tmp/probe-literal-quote.pl`:

```
plain                    value=[hello]
an ampersand             value=[Tate &amp; Lyle]
an ESCAPED double quote  value=[before \]
a bare double quote      value=[say ]
an apostrophe            value=[O'Neill]
a quote then more rules   value=[a \]   maxlength=5   required
```

The last line is the one that matters. Given
`value:"a \" b" required max:5`, the value truncates to `a \` **and
`required` and `max:5` are still applied** - because the text left over after
the truncation point is fed back through the tokeniser as further rules.

So a stray quote does not only mangle a default. It can **switch on a rule the
author never wrote**: `value:"a" required"` sets `required`. A typo in a default
value changes whether the field is mandatory.

# Why

`lazysite-processor.pl:4223`, in the rule tokeniser:

```perl
elsif ( $rs =~ s/^([A-Za-z]+:)"([^"]*)"// ) { push @rule_tokens, "$1$2"; }
```

`[^"]*` cannot contain a quote, escaped or otherwise - the tokeniser has no
concept of an escape. It consumes up to the first inner `"`, pushes what it found
as the token, and leaves the rest of the line in `$rs`, which the loop then
happily tokenises.

This predates SM856: the quoted form is how `placeholder:`, `pattern:` and
`accept:` have always been written, so any of those containing a quote has the
same fault. SM856 made it reachable with a value an author is more likely to
write - a company name, an address - which is why it surfaced now.

# The fix

Two parts, and the second is the one this project would insist on.

1. **Understand an escape.** `s/^([A-Za-z]+:)"((?:[^"\\]|\\.)*)"//` and unescape
   `\"` to `"` in the captured value. That makes the documented form work.
2. **Say so when it cannot parse.** If a quoted rule does not close - or if what
   remains after one begins with a bare `"` - that is an author error, and the
   engine should log a WARN naming the field and the rule rather than silently
   producing a different form from the one written. SM856 set that precedent for
   an undeclared `prefill:` parameter in this very function; the same reasoning
   applies to a value it could not read.

**Not a security fix, and the filing should not be read as one.** `_esc_attr`
escapes whatever value survives, so the attribute always closes and nothing is
injected - the site agent verified that in a real browser, including the case
this filing is about. What is wrong is that the field does not behave as written.

# Worth noting about how it was found

The agent found this while trying to make SM868's fix fail, not while checking
that it worked. The check they were given asked whether a literal containing `&`
was still escaped; they went looking for a source that might skip `<` where a URL
value did not, and hit the tokeniser instead. That is the difference between
confirming a fix and attacking it, and it is the second defect in two days that
came out of the second approach.

# Related

SM856 (which made this reachable with a plausible value), [[SM868]] (the fix the
agent was attacking), [[SM869]] (the other SM856 follow-on),
[[feedback_missing_parameter_named_as_missing]] (say what could not be read,
rather than acting on a different reading).
