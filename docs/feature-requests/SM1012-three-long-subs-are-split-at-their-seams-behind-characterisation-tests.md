---
id: SM1012
title: "SM1012: Three long subs are split at their seams, behind characterisation tests"
subtitle: "WORK-PLAN-0154 P20. _render_form (562 lines), main (733) and render_content (435) were moved whole by SM944; splitting them is not a move. A plan: measures, seams, order, the proof per step, risks, sizes and the questions for a ruling. No code."
brand: plain
standard-margins: true
status: partial
raised: 2026-10-12
raised-by: developer, WORK-PLAN-0154 P20 ("plan first"), 2026-10-12
area: processor
status-note: "Plan filed 2026-10-12 (WORK-PLAN-0154 P20); ruled 2026-10-12, _render_form now, hold main. Built: the deparse tools in tools/ (n450); the _render_form characterisation, t/unit/processor/112 (n451); S1-S4 (n452-n455). Next: S5, S6. render_content after; main held."
---

# Why a plan and not a move

SM944 moved the three subs whole and said each split was a separate change: S11
"one 562-line sub; splitting it is a later, separate change" (SM944 :68); S16
lists `render_content` (435) with "HIGH: the TT boundary every page crosses"
(:73); and "`main` is 733 lines on its own; splitting a sub is not a move and
is not part of this item" (:96). (A, read.)

A split is not a move. SM944's proof - every one of 227 subs deparses
identically before and after (SM944 :335) - cannot hold for the sub being
split, whose own deparse must change. This plan says what proves each step
instead.

Grades: (A) read in the code at main b5ab1ce4 (forms.pm, render.pm and the script are unchanged since n370, 5a858243, where they were measured); (B) read in
a record (the 0.15.5 gate's `coverage.txt`, whose line numbers were checked to
match this tree at `sub main {` .pl:800, `sub _render_form {` forms.pm:211 and
`sub render_content {` render.pm:86) or inferred from code read.

# Measures

Counted per line range: a line is code unless blank or `^\s*#`; keywords counted
on code lines (block and postfix forms alike; a keyword inside a string would be
counted, so the branch counts are approximate). (A)

```datatable
columns: Measure | _render_form | main | render_content
widths: 4.5cm | 3.5cm | 3.5cm | X
bold: 1
tone: light
---
Where | forms.pm:211-772 | lazysite-processor.pl:800-1532 | render.pm:86-520
Lines (code / comment / blank) | 562 (300 / 236 / 26) | 733 (327 / 349 / 57) | 435 (165 / 250 / 20)
if / elsif / unless / else | 22 / 27 / 6 / 6 | 55 / 1 / 6 / 1 | 5 / 0 / 1 / 0
Ternaries; `&&` / `||` | 18; 8 / 4 | 10; 18 / 14 | 9; 4 / 12
Loops (for, while) | 6, 1 | 3, 0 | 2 (+1 postfix), 0
return / next / last | 2 / 4 / 2 | 25 / 1 / 1 | 1 / 1 / 1
Callers | convert_fenced_form forms.pm:141 (inside `s{}{}e`); tests call it as `main::_render_form` | handle_one_request .pl:413, return value discarded | layout.pm:503 (with the before_render hook); pipeline.pm:659, :673, :791
Statements covered (0.15.5 gate, B) | 188/189 (99.5%) | 223/227 (98.2%) | 70/72 (97.2%)
Branch outcomes covered (B) | 73/82 (89.0%) | 125/140 (89.3%) | 31/34 (91.2%)
Uncovered branch lines (B) | 246, 255, 272, 351, 433, 616, 617, 660, 705 | 822, 824, 829, 883, 945, 947, 1112, 1134, 1145, 1184, 1253, 1337, 1391, 1415, 1466 | 107, 159, 488
Calls in the gate run (B) | 143 | 1033 | 694
```

File rows in the same `coverage.txt` (stmt / branch / cond / sub): forms.pm
97.5 / 86.3 / 65.8 / 100 (:20); lazysite-processor.pl 93.6 / 81.5 / 68.8 / 100
(:14); render.pm 97.1 / 90.3 / 78.3 / 100 (:31). (B) `dist/config/coverage-floor`
names `floor=75`, `branch_floor=62` and three per-CGI branch floors; no part of
the processor has a floor of its own (P19). (A)

## The phases, their state and their tests

### `_render_form` (forms.pm:211-772)

Phases (A): F1 guard, no `$meta->{form}` returns a comment (:214-218); F2 the
time/token placeholders (:232-233); F3 the per-line loop (:238-654) - step
delimiter (:241-244), field split (:245-255), submit (:257-262), the rule
tokeniser `while` (:267-355), tokens to `%rules` (:356-391), placeholder
(:392-396), the value and prefill gate (SM856/SM869, :412-453), required and
max (:455-458), effective pattern (:467-469), the server rule onto
`@server_rules` (:491-514), field HTML by kind - file :517, textarea :535,
select :548, radio :562, checklist :574, input :611 - and the wrap (:650-653);
F4 `_write_form_rules` (:656), which writes `forms/<name>.rules` (:184-209); F5
empty steps dropped, `$multi`, `$enctype` (:658-668); F6 multi-step assembly
(:674-695); F7 the `_page` field and the outcome banner from the closed `%SAID`
map (:704-752); F8 the `END_FORM` heredoc (:753-771).

State (A): reads `$meta->{form}`, `$meta->{query_params}`; the aliased globals
(forms.pm:33) `$FORM_TS_PLACEHOLDER`, `$FORM_TK_PLACEHOLDER`, `%RENDER_QUERY`
(declared pipeline.pm:613, localised per render :618) and `$LAZYSITE_DIR`;
`%ENV{REDIRECT_URL}` (:216, :347, :440, :704) and `QUERY_STRING` (:709).
Crosses phases: `$form_name`, `$ts`, `$tk`, `@steps`, `@server_rules`; within
one field, eleven lexicals (`$name`, `$label`, `%rules`, `$value`, `$ph_attr`,
`$val_attr`, `$req_attr`, `$max`, `$req_mark`, `$eff_pat`, `$field_html`) pass
from the parse half to the HTML half. Side effects: three WARN log lines and
the sidecar file.

Loop control is local (A): the two `last` (:272, :354) are inside the
tokeniser's own `while`; the four `next` (:243, :246, :255, :261) are in the
loop's head, before any proposed seam.

Tests (A): direct calls in t/unit/processor/80 and 83; through
`convert_fenced_form` in t/unit/processor/07 and 48 and t/unit/forms/01, 18,
19, 21; prefill and banner in t/unit/processor/88-91, 94, t/unit/forms/09, 15,
31; t/integration/32, 53, 60, 119; t/journey/03. Lint 156 reads `%SAID` from
forms.pm by path.

### `main` (lazysite-processor.pl:800-1532)

Phases (A): M1 `local %ENV`, URI decode, query parse (:803-835); M2 early
answers - `/lazysite` forbidden, instance JSON, OAuth well-known gate,
ai-partner JSON (:837-938); M3 per-request config, `apply_trust_gate`,
`handle_manager_path` (:940-961); M4 path resolution - `sanitise_uri`, `.brief`
404, content root (writes `$REQUEST_CROOT` :1012), md/url/html paths, system
page fallback, private twin, alias cache slot, stats (:970-1063); M5 the ACL and
auth gates, 302/403, `%AUTH_CONTEXT` (:1065-1203); M6 the payment gate
(:1205-1236); M7 the source alternate (:1238-1276); M8 cacheability -
per-viewer, preview, declared query params, nocache, `try_serve_cache`
(:1278-1346); M9 render, `.md` then `.url` (:1348-1401); M10 fallbacks - static
html, content static, engine asset, registry, alias redirect, remap, 404
(:1403-1531).

State (A): eighteen lexicals cross phases (`$uri`, `%query_params`, `$base`,
`$croot`, the three paths, `$static_html_path`, the two stat arrays,
`$auth_protected`, `$auth_result`, `$auth_peek`, `%site_vars_peek`,
`$payment_protected`, `$protected`, `$has_query_request`, `$declared_params`).
Writes `$REQUEST_CROOT`, `%AUTH_CONTEXT`, `%PAYMENT_CONTEXT`,
`%PREVIEW_CONTEXT`, `%ACCESS_REC{ar,s}` and `%ENV` keys (`LAZYSITE_LOG_*`
:944-947, `LAZYSITE_NOCACHE` :1302/:1327/:1338). Reads the file-scope `my`
variables `$LAZYSITE_URI` (:136) and `$HOST_CACHE_DIR` (:207). Prints headers
and bodies itself at :854-902, :930-936, :1125-1135, :1255-1267, :1516-1521.
The 25 `return`s are almost all "a response was printed, stop". Its return value
is discarded; a die inside it becomes a 500 only if nothing was emitted
(`$ACCESS_REC{s}` undefined, .pl:418-427).

Tests (A): every test that uses `run_processor` - about 70 t/integration, about
30 t/unit/processor, t/journey/01, 04, 05; t/unit/processor/18 pins the helpers
already taken out of it.

### `render_content` (render.pm:86-520)

Phases (A): R1 the Template object, under `_cache_umask` (:87-108); R2 site and
page vars, groups, editor flag (:110-115); R3 manager capabilities, scopes,
home domain (:121-161); R4 language, writes `$RESPONSE_LANG` (:172-185); R5 the
`$vars` stash literal (:187-409); R6 the `before_render` hook (:426); R7 code
blocks to placeholders (:429-441); R8 TAGS neutralised (:453-456); R9
`$tt->process`, the raw body on error (:458-463); R10 one-pass restore
(:487-488); R11 the multiplied-block warning (:501-517); R12 return (:519).

State (A): reads `$TT_COMPILE_DIR`, the three request contexts, `$DOCROOT`,
`$LAZYSITE_DIR`; writes `$RESPONSE_LANG`; changes the umask for R1. `$vars`
crosses R5, R6 and R9; `@code_blocks` and `$cbk` cross R7 to R11.

Tests (A): t/lint/48 and 83, t/unit/processor/60, 62, 71, 87 and
t/unit/manager/161 read the stash construction from render.pm by path;
behaviour tests t/unit/processor/27, 28, 47, 85, 88, 90, 91;
t/integration/03, 11, 16, 17, 19, 21, 26; t/unit/manager/160, 165, 202, 204.

# The seams proposed

Each new sub stays where its parent is (forms.pm, render.pm, the script), so
lint 215's part rules are met without changing what is `our`. (A: lint 215
:15-25 forbids a part from naming the script's file-scope `my` variables.)

```datatable
columns: Step | Extract | From | Returns | Note
widths: 1.2cm | 4.5cm | 2.6cm | 3.5cm | X
bold: 1
tone: light
---
S1 | `_form_rule_tokens($spec)` | forms.pm:267-355 | a token list | the whole `while`, so its `last`s stay local; one WARN (:347) moves with it
S2 | `_form_rules_from_tokens(@tokens)` | :356-391 | `%rules` | pure
S3 | `_form_field_value($name, \%rules, $meta)` | :412-453 | `$value` | the SM856/SM869 gate; reads `%RENDER_QUERY`
S4 | `_form_server_rule(...)` | :491-514 | one rule hash | pure
S5 | `_form_field_html($kind, \%field)` | :516-648 | the field HTML | one sub per kind behind a table, or one sub; Q3
S6 | `_form_outcome_banner($form_name, $meta)` | :704-752 | the banner HTML | lint 156 reads `%SAID` by path: it follows
S7 | `_tt_engine()` | render.pm:87-108 | the Template object | same per-call construction; no memoising (that is a behaviour change)
S8 | `_render_manager_facts($meta)` | :121-161 | caps, scopes, home | pure apart from the reads
S9 | `_render_lang($meta)` | :172-185 | `($site_lang, $page_lang, \@languages)` | the `$RESPONSE_LANG` write stays in the parent, visible
S10 | `_render_stash(...)` | :187-409 | `$vars` | the seven by-path readers follow it in the same branch
S11 | `_tt_process_protected($tt, $body, $vars)` | :429-517 | the body | the placeholder protection as one unit
S12 | `_early_answer($uri)` | .pl:837-938 | handled? | each answer prints; a true return means stop
S13 | `_resolve_paths($base, ...)` | :970-1063 | a hash of paths and stats | `$REQUEST_CROOT` write stays in the parent
S14 | `_gate_auth(\%req)` / `_gate_payment(\%req)` | :1065-1236 | handled? plus the protected flags | the 302/403/402 paths print
S15 | `_serve_fallback(\%req)` | :1403-1531 | nothing (it always answers) | the last call in main
```

After S1-S6 `_render_form` is the loop and the assembly, about 150 lines; after
S7-S11 `render_content` is about 40; after S12-S15 `main` is M1, M3, M7-M9 and
the calls, about 250 (B, estimated from the ranges).

# Order

1. **`_render_form` first (S1-S6).** Fewest callers (one, plus two tests), the
   best statement coverage (99.5%), and its output is a string: the easiest
   identity to prove.
2. **`render_content` (S7-S11).** Every page crosses it, but it returns
   `($body, $vars)`, which can be captured and compared whole.
3. **`main` last (S12-S15).** The most cross-phase state, the hot path, and it
   answers by printing; it needs the request harness the first two do not.

One branch per step, stacked; a step that cannot be proved stops the stack
there.

# The proof per step

**Before any extraction, per sub: a characterisation test, committed first,
alone.** It records the sub's observable output over a corpus and is the gate
for every later step of that sub. (B: the existing suite was SM944's gate
because a move cannot change behaviour; a split can, and the suite checks
behaviours, not identity.)

- `_render_form`: every `:::form` block in starter/, docs/ and the t/ fixtures,
  each rendered with and without a query (prefill), with and without each
  outcome; the record is the HTML and the `.rules` sidecar bytes, with the
  time/token placeholders left as placeholders (they are, until output).
- `render_content`: the fixture pages through `render_content` with fixed
  `%AUTH_CONTEXT`/`%PAYMENT_CONTEXT`/`%PREVIEW_CONTEXT` (anonymous, member,
  manager, preview); the record is the body and the sorted `$vars` with code
  refs reduced to their names, plus `$RESPONSE_LANG`.
- `main`: a request matrix through `run_processor` - one request per phase
  exit (each early answer, `.brief`, each gate's 302/403/402, the source
  alternate, cache hit, `.md`, `.url`, each fallback, 404); the record is
  status, sorted headers (Date and nonces masked) and a body digest, plus the
  `%ACCESS_REC` fields.
- **Each uncovered branch line in the table above gets a case first**, so the
  characterisation reaches every outcome the extracted block holds (9 + 15 + 3
  lines).

**Then, per extraction step:**

- **Whole-tree deparse**: every processor sub other than the parent and the
  new one deparses identically (the SM944 S16 method, `tmp/sm944-deparse-all.pl`).
- **Block against sub**: the new sub's deparse against the original block
  wrapped with the same lexicals as parameters (the SM944 S33 method,
  `tmp/sm944-s33-deparse-handler.pl`), where the block has one exit. It does
  not apply to S12, S14 and S15 (blocks that `return` from `main`), nor to S5
  and S10, whose results are built across a boundary: those rest on the
  characterisation test alone, which is why it comes first.
- The characterisation test, the full suite and the by-path lints, unchanged.
- **Sabotage**: one deliberate change in each new sub, seen to fail the
  characterisation test, then reverted (a backup under tmp/).
- **For `main` and `render_content`, the bench**: `render_cache_hit_ms`
  interleaved, six rounds in both orders, as SM944 S16 did; a slower cache hit
  stops the step.

The deparse tools are untracked under the project's tmp/ (A: none is in the
tree; lint 215 :27 explains why the lint itself does not use Deparse). Q2.

# Risks

- **Loop control crossing a sub.** A `next` or `last` that leaves a sub warns
  ("Exiting subroutine via next") and changes flow. The seams avoid it (the
  `last`s are inside S1's own loop); the characterisation test with warnings
  fatal catches one that slips. (A for where they are.)
- **Dynamic scope.** `main`'s `local %ENV` (.pl:803) and `%RENDER_QUERY`'s
  `local` (pipeline.pm:618) reach the new subs because they are called inside
  that scope; a sub called later (a deferred closure) would not see them. None
  is proposed. (A)
- **`$1` and friends.** `_render_form` is called from inside `s{}{}e`
  (forms.pm:141) with `$1`; a new sub that runs a match before reading a
  capture would see its own. The arguments are copied at entry today; keep it
  so. (A for the call.)
- **Output ordering in `main`.** The early-answer subs print; a sub that
  returns "handled" after printing nothing would fall through to the 404. The
  matrix covers each exit.
- **By-path readers.** Seven tests and lints read render.pm's stash text and
  lint 156 reads `%SAID`: each must follow its code in the same branch, and
  each must be seen to fail with a sabotage in the new place (SM944's rule).
- **Hot path cost.** Four more sub calls per page in `main` and five in
  `render_content`; small, but measured, not assumed.
- **Coverage moves.** The per-file numbers shift as code moves between subs;
  no file has a floor of its own today (P19), so a drop would not fail the gate
  - it must be read off `coverage.txt` per step.

# Sizes

```datatable
columns: Work | Size
widths: 9cm | X
bold: 1
tone: light
---
Characterisation tests, three, with the uncovered-branch cases | M
S1-S6 `_render_form` | M
S7-S11 `render_content` | M
S12-S15 `main` | L
The deparse and capture tools into tools/ (if Q2 says so) | S
Whole | L
```

# Questions for a ruling

1. **Is this worth doing now?** Each sub is already covered at 97-99.5% of
   statements; the gain is reading cost and smaller future diffs, not a defect
   fixed. Recommendation: do `_render_form` (S1-S6) now, as it is the cheapest
   and the one a field feature touches most often (prefill, rules); hold
   `main` until a change has to go through it.
2. **The deparse and capture tools: commit them to tools/, or keep them in
   tmp/?** A proof that rests on an untracked script cannot be rerun by a
   reviewer. Recommendation: commit them, with the characterisation harness.
3. **S5: one sub per field kind (six, behind a table) or one `_form_field_html`?**
   Recommendation: one sub per kind - each is 12-40 lines and a new kind
   becomes a row.
4. **The characterisation records: committed fixtures, or generated from the
   base commit at test time?** Recommendation: committed, so a change in
   output is a visible diff in review; regenerated only on a ruled change.
5. **Per-part coverage floors (P19) before or after?** Recommendation:
   before, so a step that loses coverage in its file fails the gate rather
   than being read by hand.

# Ruling (2026-10-12)

The release manager ruled, in these words: "_render_form now, hold main". The
open questions, answered from that ruling:

1. **Now?** `_render_form` now; hold `main`. `render_content` comes after
   `_render_form`, and `main` is decided after seeing them.
2. **The tools:** commit the deparse and move comparison tools from tmp/ into
   tools/, each with a short usage header, and with tests of the tools
   themselves where that is cheap. They are `tools/deparse-subs.pl` (every
   processor sub deparsed; `--compare` two trees, or a tree and a saved listing,
   and name the subs that differ - exit 0 only when exactly the `--expect` set
   differs) and `tools/deparse-block.pl` (the block of an old file, wrapped as a
   sub with its free variables as parameters, against the sub extracted from
   it). t/unit/processor/111 runs each on a pair of trees that are the same and
   a pair that are not.
3. **S5:** one sub per field kind.
4. **The characterisation records:** committed.
5. **P19 floors first.** P19's per-part coverage floors are being built
   separately; this work does not wait for them and does not change
   `dist/config/coverage-floor`. Until they land, a step that loses coverage in
   its file is not failed by the gate, so each step's coverage is read by hand
   (Risks, "Coverage moves"). DEPENDENCY: once P19 lands, the floors hold this
   work's files.

# Done when

Each of the three subs is a sequence of named calls over the seams above; the
characterisation test for each passes unchanged across every step; whole-tree
deparse shows no other sub changed; the cache-hit bench is unchanged.
