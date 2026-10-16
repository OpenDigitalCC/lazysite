---
id: SM1094
title: "SM1094: an unreadable auth_groups message quotes what it read"
subtitle: "The access-key-unreadable message for a value that is not a list named the value inside its own example, so `auth_groups: [` read as garbage; it now quotes the value and shows the correct forms apart from it."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: the 0.15.5 test plan, row S9 (T5)
area: validation
status-note: "SHIPPED on n605: lib/Lazysite/Validate.pm and its marked copy lazysite-processor/front-matter.pm; t/unit/lib/201."
---

# What happened

The 0.15.5 test plan, row S9: "`auth_groups: [` unterminated: 403 signed out,
"Access Denied" to an editor and to ai-ui-tester; validate_page reports
`access-key-unreadable`. Its message reads "write [[] or a '- [' line below
it" - the raw value is spliced in and reads garbled."

For a value that is not a list, `read_access_keys` built its reason as
`write [$inline] or a '- $inline' line below it`. With the value `[` the
examples became `[[]` and `'- ['`, which are not forms anyone can follow.

# What shipped

The reason now reads, for `auth_groups: [`:

    'auth_groups' has the value '[', which could not be read as a list - write
    auth_groups: [editors], or one "- editors" line per group below it

The value is quoted as read; the two correct forms are examples with a generic
group name, on their own. The code, `access-key-unreadable`, is unchanged.

The reader is a marked copy of the processor's (ADR 0001, t/lint/220), so the
gate's own log line changed with it. The other keys sharing the message were
checked: `auth` and `payment` already quote their value (`'payment: maybe' is
not one of required, none`), and the other `auth_groups` reasons name the key
or the offending entry in quotes. Only the one-value reason spliced.

t/unit/lib/201 holds it for `[`, a bare name and an unterminated list;
t/integration/125's wording check follows the new text.
