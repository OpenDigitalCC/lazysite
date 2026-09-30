---
id: SM921
title: "SM921: the shipped tel pattern does not compile, so every tel field validates nothing"
subtitle: "Measured in a browser: an input carrying the engine's default tel pattern accepts the single letter S. `[\\d\\s()+.-]{6,20}` is a valid Perl regex and an invalid HTML pattern - browsers compile the attribute with the `v` flag, under which bare parentheses and a bare hyphen in a character class are a syntax error, and the spec's answer to an uncompilable pattern is to ignore the attribute in full. An author's own `pattern:` fails the same way, and is separately truncated at its first space."
brand: plain
standard-margins: true
status: candidate
raised: 2026-09-30
raised-by: site agent, from an owner's test on a live form ("just typed S in and allowed")
area: forms
---

# Two independent faults, both silent

## 1. The shipped default does not compile

`lazysite-processor.pl` renders, for a `tel` field with no `pattern:` of its own:

    $pat = '[\d\s()+.-]{6,20}' if !defined $pat && $type eq 'tel';

Confirmed in the source at the line the report names. Measured in a browser on
0.14.4 against an input carrying exactly that pattern:

    pattern [\d\s()+.-]{6,20}     value "S"     patternMismatch = FALSE

Browsers compile `pattern` with the **`v` flag** (`unicodeSets`), under which a
set of punctuation characters must be escaped inside a character class -
parentheses and the hyphen among them. The pattern is therefore a syntax error,
and the HTML specification's response to a pattern that will not compile is to
ignore the attribute entirely. No console error reaches the author.

Measured side by side, which is what makes this actionable rather than a theory:

```datatable
columns: Pattern | value "S"
widths: 7cm | X
text: 2
bold: 1
tone: medium
---
`[\d\s()+.-]{6,20}` (shipped) | **accepted**
`[0-9\s+.-]{6,30}` (parens removed, hyphen bare) | **accepted**
`[0-9\s\(\)\+\.\-]{6,30}` (fully escaped) | **rejected**
```

The middle row is the one that saves the next person an hour: removing the
parentheses is not enough, because the bare `-` before `]` is also reserved.

## 2. An author's `pattern:` is truncated at the first space

Rules are matched one whitespace-separated token at a time, and the pattern rule
is `elsif ( $r =~ /^pattern:(.+)/ )` - so `(.+)` reaches the end of the TOKEN,
not the end of the line. Confirmed in the source.

    phone | Phone | tel pattern:[0-9 ()+.-]{6,30}

renders `pattern="[0-9"`. That IS a valid regex, so nothing is ignored and
nothing is reported: the field simply refuses almost every value, and the author
has no way to see why. The list rules (`select:`, `radio:`, `checklist:`) take the
rest of the line and the docs say to put them last; `pattern:` reads as though it
behaves the same and does not.

# Why this is worse than a phone box

`pattern:` is the ONLY validation the form grammar offers beyond `required`,
`email` and `maxlength`. A form asking for a reference, a postcode, an account
code or a phone number has this and nothing else. Today:

  - a pattern containing a space is quietly cut in half, and over-rejects;
  - a pattern containing the punctuation you would naturally write is quietly
    discarded, and under-rejects.

Both produce a form that looks validated and is not - which is the shape this
release spent two days on in three other places (SM916, SM917, SM918).

# What would fix it

  1. **Escape the shipped default.** `[0-9\s\(\)\+\.\-]{6,20}`, measured to work.
     And widen the bound: `+33 (0) 1 89 48 00 40` is 21 characters, so a French
     number written the way that country writes it fails `{6,20}` even once the
     pattern compiles.
  2. **Let `pattern:` take the rest of the line**, as the list rules do - or
     document that it may not contain a space. The first is what an author
     expects; the second is a one-line docs change and leaves the trap.
  3. **Refuse an uncompilable pattern rather than emitting it.** The processor
     cannot run the browser's `v`-flag compiler, so this cannot be exact - but the
     specific shapes that break it are enumerable (a bare `(`, `)`, `-`, `[`, `]`,
     `{`, `}` inside a character class), and catching those turns a silent nothing
     into a message. `lazysite check` is the natural home if the render path should
     not carry it.

Item 3 is the one that stops this recurring for the next pattern somebody writes,
and it is also the one that needs a decision: a render-time refusal changes what a
page does, and a check-time warning does not.

# Not established

Whether any live site is relying on the broken default in a way a fix would
change. Escaping it turns a field that accepted anything into one that rejects
letters, which is the intent - but on a site whose visitors have been entering
free-text phone numbers that is a behaviour change on a live form rather than
purely the repair of a silent fault, and it wants naming in the release notes
either way.

# Related

[[SM888]] (A5, the other place the form grammar met a real page),
[[SM905]] (the grammar's most recent additions),
[[feedback_a_declaration_the_code_ignores]],
[[feedback_verify_what_renders_not_the_source]].
