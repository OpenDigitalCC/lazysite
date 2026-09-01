---
id: SM708
title: A literal template open in page script blanks every substitution on the page
raised: 2026-09-01
raised-by: site agent (familyhq.explore), filed to the dev inbox 2026-08-31
area: rendering
status: partial
status-note: "PARTIAL. DEFECT 2 IS ANSWERED AT THE WRITE PATH: a page whose template body does not parse is REFUSED before it is saved, by _page_parse_refusal at write_file, replace_text and _create_page. The refusal had to be built before the save rather than as a _validate_page issue, because issues on that path are ADVISORY - action_save runs first and the issues are attached to the result, so the page would already be on disk. Only /parse error/ refuses; a missing INCLUDE is a file error and may resolve at render. Fenced AND four-space-indented code blocks are stripped first, because the processor protects <pre><code> and starter/docs/ai-briefing-layouts documents [% INCLUDE %] in an indented block. Swept before shipping: 827 markdown files, zero refused. WHAT REMAINS: (a) the RENDER-time fallback is unchanged - it is still whole-body and still says so only in a log, so a page reaching the render path another way still voids every substitution; (b) the check covers MCP writes ONLY - the manager UI editor and WebDAV do not call _validate_page, so a page written through either is unguarded. DEFECT 1, protecting <script> from TT wholesale, is REFUSED rather than pending: the layout catalogue has zero interpolations inside <script> but the starter tree has two, one being the manager's own editor, which would stop knowing which file it is editing. SM709 is the same boundary seen from the security side and shipped separately."
---

# What happens

Page and partial bodies are TT-processed with the auth stash, so `[% auth_user %]`
resolves in ordinary content. If a body contains a literal `[%` that is not a
valid directive, TT reads it as a directive open, scans to the next `%]`, and
fails to parse. The processor then takes a **whole-body** raw fallback
(`lazysite-processor.pl:6613-6618`):

```perl
$tt->process( \$protected_body, $vars, \$processed_body )
    or do {
    log_event( "ERROR", ..., "template error, using raw content", error => $tt->error() );
    $processed_body = $protected_body;
    };
```

So **one bad span anywhere on the page disables every `[% %]` on it**. The only
signal is a single ERROR log line; the page still renders, just with dead
template variables.

# The case that found it

familyhq wrote a guard in page JavaScript to detect an un-interpolated template
- the obvious defensive thing to write:

```js
u = /\[%/.test(u) ? "" : u;
```

That literal `[%` inside a regex broke the parse, so the whole body fell back,
so `[% auth_user %]` came out literal, so the guard blanked it. The page's JS
then saw an empty viewer: a "questions suggested for you" badge silently counted
ALL open questions and a "mentions me" filter matched nobody. Both looked like
feature bugs. Both were this.

# What the report did not know, and it sharpens the filing

**The protection mechanism already exists and this case falls outside it.**
Immediately above the fallback, `lazysite-processor.pl:6602-6611` lifts
`<pre><code>...</code></pre>` and `<code>...</code>` out of the body into
placeholders before TT runs, and restores them after. A literal `[%` in a fenced
code block is therefore already safe - which is why this never surfaced in
documentation pages, where an author writing about template syntax is the most
likely person to type one.

`<script>` gets no such treatment. So the rule the engine currently implements
is "template syntax is inert where it is being *displayed*, and live where it is
being *executed*", which is backwards from what an author would guess.

# Two separable defects

1. **`<script>` bodies are TT-processed.** Executable page script is the one
   place a literal `[%` is most likely to be deliberate and least likely to be a
   directive. Extending the existing placeholder protection to `<script>` is a
   small change to code that already does exactly this for `<code>`.

   It is not free: a page that today interpolates `[% auth_user %]` *inside* its
   script would stop resolving. familyhq does this deliberately, and it is the
   documented way an app page learns who is viewing. So this cannot be a blanket
   lift - it needs either an opt-out marker on the script tag, or a narrower
   protection than "the whole element".

2. **The fallback is whole-body and near-silent.** Even with (1) fixed, any
   parse failure still voids every substitution on the page rather than the span
   that failed, and says so only in a log nobody is watching. A page whose
   template variables all came out literal is a rendering failure; it currently
   reads as a page whose variables happen to be empty.

   Worth considering: surface it where an operator sees it. The manager already
   has a place to say a page did not render as intended.

# Why it hid

- `auth: required` pages are uncached and rendered per request, so an empty
  `[% auth_user %]` reads as "the variable is empty", not "the render failed".
- Downstream code degrades quietly rather than erroring.
- Nothing in the suite renders a page containing a literal `[%` outside a code
  block. A test that does is the first thing to write, whichever fix is taken.

# Not decided here

Which of the two to build, and in what order. (2) is the one that makes every
future instance of this visible; (1) is the one that stops the commonest cause.
They are independent.
