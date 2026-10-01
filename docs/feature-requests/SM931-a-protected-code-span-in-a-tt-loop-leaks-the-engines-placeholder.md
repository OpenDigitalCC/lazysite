---
id: SM931
title: "SM931: a protected code span in a TT loop publishes the engine's own placeholder text"
subtitle: "A page rendering 27 rows from a `json:` file published the literal string `CODEBLOCK_0_END` in 22 customer-facing cells. Code is protected from Template Toolkit before the render, correctly; the restore afterwards is a substitution without `/g`, so a loop that multiplies the placeholder gets exactly one copy back. Reproduced locally, and the repair the report proposes is not the right one - it corrupts a case the present code survives."
brand: plain
standard-margins: true
status: shipped
raised: 2026-09-30
raised-by: site agent, measured on a live page before and after (0.15.0)
area: processor
status-note: "SHIPPED (PENDING ref) 2026-10-01: ALL THREE ITEMS BUILT, in the filing's own order. (1) THE RESTORE IS ONE PASS with a callback, exactly as the filing corrected its own reporter - and the two cases that separate it from the report's `/g` are both tests: a protected block whose own text contains a later placeholder keeps that text, and a placeholder with no block is LEFT ALONE rather than replaced with the empty string (which would also hide a genuine leak from whoever is reading the page). (2) THE WARN IS EMITTED, naming the block and the COPY COUNT, and the test reads it from STDERR rather than trusting that it is there - `run_processor` discards STDERR, so a helper that threw the evidence away would have made this item untestable. Its silence is asserted too: a line that fired on every page carrying a code span would be noise, and noise is how a real one gets missed. (3) THE LIMITATION IS DOCUMENTED beside the two `[%`-in-`<script>` traps it shares a root with - and the first attempt edited the SERVED copy, which t/lint/89 refused because that page is GENERATED: the correction belongs in docs/practice/authoring-practice.md followed by `perl tools/import-field-practice.pl`, which is precisely the failure that lint exists to catch. The smaller finding is in too: FEATURES now lists `json:` among the tt_page_var sources. Four sabotages on this half, four refusals. THE CLAIM THAT DID NOT STAND IS KEPT AS A TEST rather than only as prose - a span containing `$1` and a Windows path passes through unchanged - and writing that test reproduced the report's own mistake one level up: the first version used `qr{...$1...}`, which interpolated `$1` away before the match ran, so it asserted nothing. It uses `index` with single-quoted needles now. NOT IN SCOPE, AND NOT A PARKED HALF: making a code span inside a loop both protected from TT and interpolated by it. Original ruling follows. RULED 2026-10-01: ALL THREE ITEMS, IN THE FILING'S OWN ORDER, and the combination stays unsupported. (1) THE RESTORE BECOMES ONE PASS with a callback, not the `/g` the report proposed - the filing already corrected its own reporter on this and the correction is the ruling: `/g` fixes the leak and corrupts a protected block whose own text contains a later placeholder, the realistic instance being this project's own documentation of this mechanism, while one pass fixes both because the regex engine resumes after inserted text rather than over it. A placeholder with no corresponding block must be left alone rather than replaced with the empty string. (2) SAY SO WHEN IT HAPPENS: after TT, a placeholder occurring more than once means the render multiplied protected content - one comparison and a log line, which is the difference between a five-minute diagnosis and finding it by reading rendered HTML, which is how this was found. The filing notes that on the stack this was found on that log line might not reach anybody; SM932 has since SHIPPED (b1556284) with syslog forwarding on by default at WARN and above, so a WARN here now has a second sink that does not depend on where a CGI's STDERR goes. (3) DOCUMENT THE LIMITATION beside the two `[%`-in-`<script>` traps that already have an entry in the authoring practice notes - same root, protection and substitution in a fixed order around TT. The smaller finding that stands is in scope too: FEATURES.md:97 omits `json:` from the tt_page_var sources though the processor builds it at :6129 and it is the most useful of them for a content-heavy page. NOT IN SCOPE, AND NOT A PARKED HALF: making a code span inside a loop both protected from TT and interpolated by it. The filing establishes that it cannot be both, that protecting it is the right default, and that the honest position is that the combination is unsupported - so the published behaviour after this is an author seeing their own unrendered `[% p.token %]`, never the engine's internal placeholder. If that is ever revisited it is a change to the order of protection and substitution around the render and wants its own filing. The report's other claim - that `$code_blocks[$i]` on the replacement side puts a `$` or a backslash 'at the mercy of that interpolation' - was measured FALSE by the filing and stays recorded as false: the replacement is interpolated once and not re-parsed, and all three of `s/(\\w+)/$1/g`, a Windows path and `print \"$&\\n\"` pass through unchanged under both the present code and the repair."
---

# Measured on a live page

A page rendering 27 rows from a `json:` data file across five `FOREACH` loops, each
row carrying a token in an inline code span:

```html
<td><strong>[% p.short_name %]</strong><br>[% p.name %]<br><code>[% p.platform_token %]</code></td>
```

Every other field rendered. The code span did not, in two different ways at once:

```datatable
columns: Row | What the page published
widths: 5.4cm | X
text: 2
bold: 1
tone: medium
---
First row of each table (5 of them) | the literal text `[% p.platform_token %]`
Every other row (22 of them) | the literal text `CODEBLOCK_0_END`
```

**Twenty-two cells on a customer-facing page carrying an internal placeholder
string.** The page was otherwise correct - all 27 rows present, every other column
right - so nothing about the output invited suspicion except the cells themselves.

**Grade: measured on the live site before and after removing the code span** - 27
rows both times, leaked placeholders 22 then 0, unrendered TT tags 5 then 0 - and
reproduced locally by me, in `tmp/codeblock-restore.pl`.

# One cause

`lazysite-processor.pl:7737-7748` protects code from TT before the render, which is
correct and deliberate - a documented code example must not be executed as a
template. There are **two** protect passes sharing one placeholder namespace,
`<pre><code>` blocks and then inline `<code>`, and both use `/g`:

```perl
$protected_body =~ s{(<code>)(.*?)(</code>)}{
    my $placeholder = "CODEBLOCK_" . scalar(@code_blocks) . "_END";
    push @code_blocks, "$1$2$3";
    $placeholder
}gse;
```

The restore, at **`:7757-7760`**, does not:

```perl
for my $i ( 0 .. $#code_blocks ) {
    $processed_body =~ s/CODEBLOCK_${i}_END/$code_blocks[$i]/;
}
```

The body is protected **once**, before TT. TT then duplicates the placeholder -
once per iteration - so by restore time one placeholder string appears 7 times and
exactly one is replaced. Reproduced: `no /g : restored=1 leaked=6`.

That accounts for both symptoms. The one restored copy shows the protected literal
(unrendered, because protection is the point) and the rest show the placeholder.

**It applies to fenced blocks too.** The report found it on inline `<code>`; both
protect passes share the same restore loop, so a fenced block inside a loop leaks
identically. Not observed in the field, and it follows from the same four lines.

# The repair, and it is not the one proposed

The report proposes adding `/g`. That fixes the leak and **breaks a case the
present code survives**, because the loop is the problem rather than the missing
flag: each iteration rescans text that earlier iterations inserted.

A protected block whose own text contains a later placeholder - the realistic
instance being our own documentation of this very mechanism - is corrupted:

```datatable
columns: Restore | Output for a block whose text is `CODEBLOCK_1_END`
widths: 3.2cm | X
text: 2
bold: 1
tone: medium
---
present (no `/g`) | `<code><code>second</code></code> and CODEBLOCK_1_END`
report's (`+/g`) | `<code><code>second</code></code> and <code>second</code>`
**one pass** | `<code>CODEBLOCK_1_END</code> and <code>second</code>` - correct
```

One pass with a callback fixes the leak **and** removes the ordering hazard,
because the regex engine resumes scanning after inserted text rather than over it:

```perl
$processed_body =~ s{CODEBLOCK_(\d+)_END}
                    { defined $code_blocks[$1] ? $code_blocks[$1] : "CODEBLOCK_${1}_END" }gse;
```

Validated in `tmp/codeblock-restore-fix.pl` on four cases - the loop leak, a span
containing `$1` and backslashes, the placeholder-in-content case above, and a
placeholder with no corresponding block (which must be left alone rather than
replaced with the empty string). The report's `/g` passes three and fails the
third.

# A claim in the report that does not stand

The report's second "smaller thing" says `$code_blocks[$i]` on the replacement side
puts a code span containing a `$` or a backslash "at the mercy of that
interpolation". **It does not.** The replacement is interpolated once, and the
resulting string is not re-parsed, so `s/(\w+)/$1/g`, `C:\path\new\test` and
`print "$&\n"` all pass through unchanged - tested, all three UNCHANGED under both
the present code and the repair.

Saying so explicitly because the next person to open `:7759` would otherwise spend
time on it. It was the right thing to flag and the wrong conclusion.

# `/g` is necessary and not sufficient

With the restore fixed, the page publishes `[% p.platform_token %]` twenty-seven
times instead of leaking placeholders twenty-two times. Better - an author sees
their own text and can act on it - but still not what they wanted, and the
underlying constraint remains: **inside a loop, a code span cannot be both
protected from TT and interpolated by it.** Protecting it is the right default, so
the honest position is that the combination is unsupported.

Three things, in the order they pay off:

1. **Fix the restore** (one pass, above). Publishing the engine's internal
   placeholder into page output is the worst available outcome and the one that
   cannot be explained to a site owner.
2. **Say so when it happens.** After TT, a placeholder occurring more than once
   means the render multiplied protected content. That is one comparison and a
   `log_event` - the difference between a five-minute diagnosis and finding it by
   reading rendered HTML, which is how this was found. Note [[SM932]]: on the
   stack this was found on, that `log_event` may not reach the operator, so the
   check is worth surfacing where a person will see it.
3. **Document the limitation** beside the two `<script>` traps that already have
   an entry in the authoring practice notes, because it is the same root -
   protection and substitution happening in a fixed order around TT.

# Where an author meets this

Not in a contrived page. Rendering a data file into a table is the documented
purpose of `json:`, and a token, a filename, a command or an identifier is exactly
the sort of value such a table carries - so reaching for backticks or `<code>` is
the natural thing to do. The author's workaround is not to mark it up as code,
which loses the monospacing and is otherwise fine.

# One smaller thing found alongside, which does stand

**`docs/FEATURES.md:97`** lists the `tt_page_var` sources as "literal / `url:` /
`scan:` / `${ENV}`". **`json:` is missing**, though it is implemented at `:6129`
and is the most useful of them for a content-heavy page. A capability the feature
table does not mention is one an author has to be told about by somebody who
already knows.

# Related

[[SM932]] (whether item 2's log line can be read), [[reference_lazysite_authoring_gotchas]],
and the `[%`-in-`<script>` pair in `lazysite-sites/AUTHORING-PRACTICE.md` - same
root, different surface. [[feedback_placeholder_tokens_read_as_data]].
