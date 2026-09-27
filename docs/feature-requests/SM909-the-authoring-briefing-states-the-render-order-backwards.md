---
id: SM909
title: "SM909: the authoring briefing states the render order backwards, at the head of the section that teaches it"
subtitle: "The sites agent read six statements in the shipped briefings saying the body becomes HTML first and TT runs second, and one saying the opposite - the sentence that opens the section on Template Toolkit in page content, which is the first thing an author reads when they go looking. The reporter took the six on weight of evidence and said plainly they had not read the processor. The processor agrees with the six."
brand: plain
standard-margins: true
status: shipped
status-note: "SHIPPED 2026-09-27 for 0.15.0. VERIFIED IN CODE before the edit, which is what the filing added to the report: lazysite-processor.pl:3729 runs `convert_md` to produce $html_body, and render_template / render_content - where TT runs - receives that already-converted HTML at 3733 and 3737. So the order is markdown first, TT second, the six statements are right and the one was wrong. One sentence replaced with the formulation the rest of the corpus already uses. The value is not the sentence: the SM498 image rule, the fence rule and the link rule all FOLLOW from the real order, and a reader given the order backwards meets each of them as a separate surprising exception - which is how the reporter came to it, reviewing a site package whose author had hand-generated twelve listing cards rather than looping."
raised: 2026-09-27
raised-by: sites agent (inbox, 2026-09-27 16:50)
area: docs
---

# What was reported

`starter/docs/ai-briefing-authoring.md:287`, opening *Template Toolkit in page
content*:

> TT variables are expanded in the page content **before** Markdown conversion.

Against six statements saying the opposite, three of them in the same file: the
image rule at :339 ("the body becomes HTML **first** and TT runs **second**"), the
fence rule at :346, the link rule at :396, and three more in
`ai-briefing-practice.md`.

# What the code says

The reporter said explicitly they had not read the processor, and took the six
because they are specific and sourced. That was the right call and it needed
checking, because if the majority had been wrong the defect would have been much
larger than a sentence.

`lazysite-processor.pl`:

```perl
my $html_body = convert_md($converted3);          # 3729
...
$page = render_template( $meta, $html_body );     # 3737
```

Markdown first. TT second, over the rendered HTML. The six are right.

# Why it costs more than a sentence

Everything downstream of that line is a consequence of the real order: an image
whose source is computed cannot work, a fence's name cannot be computed, a link
the parser has already resolved cannot be. Read in the stated order those are
three unrelated traps to memorise, fifty lines apart. Read in the true order they
are one fact with three consequences, and the first one is enough to predict the
others.

# What shipped

The sentence, in the corpus's own words: "The page body is converted to HTML
first; TT runs second, over the rendered HTML."

`ai-briefing-practice.md` needed nothing - it already says this twice, and it is
re-imported from the sites agent's source at every pre-cut rather than edited
here.
