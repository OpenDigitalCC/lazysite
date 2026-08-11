---
title: "SM275 - The remaining docs-drift rows"
subtitle: "The audit rows that survived two rounds of splitting: feature descriptions, three that are true but read wrong, and one gap to confirm before working."
brand: plain
status: shipped
status-note: "SHIPPED 2026-08-11 (unreleased on main), and TWO OF THE FOUR ROWS WERE ALREADY CLOSED - which is why the filing said confirm before working. The /lazysite-assets mirror-on-apply gap: closed, _mirror_theme_assets IS called in package_apply (SitePackage.pm:451) by SM193; minutes to check against hours to fix. The SM133 static-fallback wording: closed, the processor comment already says explicitly that a verbatim serve does NOT process SSI. FIXED HERE: the SM120 source comment called the per-page theme: pin preview-only when FEATURES.md and the code both treat it as a general override - corrected, and 'preview-only' added to t/lint/08-retired-terms.t so the term cannot come back. The ::: include wording now states the content-root confinement, which is stricter than the earlier description implied. ORIGINAL: SPLIT from SM263 on 2026-08-11, which was itself split from SM254 on 2026-08-08. SM254 delivered the lint and the mechanically-checkable corrections; SM263 answered all four operator questions (three built, one withdrawn as wrong). These rows are what is left, and they are left because each needs a human judgement about wording rather than a check. Not started."
---

# SM275 - the remaining rows

## Why this exists as a third filing

This is the second split of the same audit, and the reason is the one the
operator gave the first time: carrying finished and unfinished work in one
record forces a later reader to pick through it working out what was done.
Two clean records beat one ambiguous one - and three beat two, if the third
is genuinely a different kind of work.

It is. What remains cannot be checked mechanically; each row is a judgement
about how a sentence reads.

## What remains

**The feature-description rows.** Descriptions in the docs that are
accurate about behaviour and misleading about purpose - they describe what
the code does rather than what the feature is for. Rewriting these is
editorial work, and getting it wrong makes the docs worse, not just
different.

**Three rows that are TRUE but read wrong.** Recorded during the audit as
"not a factual error, but a reader will conclude something false". These
are the most delicate: nothing is incorrect, so there is no test that can
catch a regression, and the fix is a wording change that a later editor
may innocently undo.

**The /lazysite-assets mirror-on-apply gap - CONFIRM BEFORE WORKING.** The
audit flagged that applying a site package may not mirror theme assets to
`/lazysite-assets`. SM193 added `_mirror_theme_assets` on apply, so this
row may already be closed. Two rows in this same audit turned out to be
overstated on inspection, which is the reason for the instruction: verify
against current code before writing anything.

## Method note, worth keeping

Two of the original audit's rows were wrong on inspection, and one of
SM263's four questions was withdrawn because the premise was mistaken - a
build channel and a site `update_channel` answer different questions, and
both defaults were correct. An audit's own rows are evidence, not
findings. Confirm each before acting.

## Related

SM254 (the lint and the mechanical corrections), SM263 (the four decided
questions), SM193 (the asset mirror, which may already close one row).
