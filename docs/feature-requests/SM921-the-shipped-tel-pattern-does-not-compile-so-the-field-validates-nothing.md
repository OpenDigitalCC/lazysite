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
status-note: "RULED 2026-09-30, NOT BUILT. Items 1 and 2 are repairs and need no decision; item 3 needed one and got it. RULING on item 3: an uncompilable pattern is REFUSED BY `validate_page` and WARNED BY `lazysite check`, and the RENDER PATH IS UNCHANGED. So an author writing a bad pattern is told while they are writing it, an operator running the check finds the sites already broken, and no live page changes what it does on upgrade. A render-time refusal was declined for that last reason: a site with a bad pattern in a page would start showing an error where a form used to render, which is a worse failure than the silent one for anybody mid-campaign. BUILD NOTE: the enumerable-shapes test (a bare `(`, `)`, `-`, `[`, `]`, `{`, `}` inside a character class) then has two callers, so it must be ONE helper with a lint that both use it - a second copy of this judgement is the ADR 0001 shape and would drift. ITEM 2 also ruled by the same pass: `pattern:` takes the rest of the line, as the list rules do, rather than documenting that it may not contain a space - the first is what an author expects and the second leaves the trap. ITEM 1 is the shipped default escaped to `[0-9\\s\\(\\)\\+\\.\\-]{6,20}` AND the bound widened, because `+33 (0) 1 89 48 00 40` is 21 characters. NAMING IN THE RELEASE NOTES IS PART OF THE WORK, not optional: escaping the default turns a field that accepted anything into one that rejects letters, which is the intent, but on a site whose visitors have been typing free text into it that is a behaviour change on a live form rather than purely a silent repair. GRADE: the escaped pattern is the reporter's browser measurement, not mine - I cannot run the `v`-flag compiler from here, and the build should re-measure it in a browser rather than trust this line."
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
and it is also the one that needed a decision: a render-time refusal changes what a
page does, and a check-time warning does not.

## Ruled 2026-09-30: both places somebody is looking, and not the render path

**`validate_page` refuses an uncompilable pattern; `lazysite check` warns about
one; the render path is unchanged.** Those are the two moments a person is
actually looking at this - writing the page, and auditing the site - and between
them they cover the new bad pattern and the fleet of existing ones.

The render path stays out of it deliberately. A render-time refusal would mean a
site with a bad pattern in a page starts showing an error where a form used to
render, on upgrade, with no warning: a worse failure than the silent one for
anybody mid-campaign, and it would land on exactly the sites this filing is about.

Item 2 was ruled the same way it is written: **`pattern:` takes the rest of the
line**, as the list rules do. Documenting the space limitation instead is a
one-line change that leaves the trap in place, and the trap is the defect.

**One thing the build must not do**: write the shape test twice. With two callers
it is one helper plus a lint that both use it, or it becomes the ADR 0001 problem
- two copies of one judgement, drifting.

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
