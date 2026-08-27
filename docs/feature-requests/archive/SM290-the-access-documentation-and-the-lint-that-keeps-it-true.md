---
title: "SM290 - The access-control documentation, and the lint that keeps it true"
subtitle: "Writing it down is what we did last time. It rotted, and it was believed while rotten. Every statement of fact about the code gets pinned."
brand: plain
status: shipped
status-note: "SHIPPED on main (unreleased) 2026-08-12, phase 3 of WORK-PLAN-ACCESS-CONTROL, written straight after SM287/SM288 settled the grammars rather than waiting for SM286 step 1 (which changes where bytes live, not the model a user sees). access-control-model.md is now a REFERENCE - two mechanisms and which question each answers, the scope grammar, the subject grammar, the two policies, the per-channel table, the truth table, and how to verify it from outside - with the SM224 analysis kept as an APPENDIX, assembled rather than retyped so its reasoning could not be paraphrased away. Two superseded recommendations marked in place rather than left as live suggestions: finding 1 (rename set_permissions because it does not govern the public path - SM223 made the premise false) and the naming recommendation at the foot. FEATURES gains 'Limiting who can see content', including the sentence that was written nowhere: protection is opt-in, so a file nobody mentioned is public - and its now-false claim that an @group can never match a partner is gone. t/lint/36 pins every factual table against the source, and was verified by breaking the CODE four ways - root check moved before the prefix loop, nested-group expansion removed, a channel dropping the shared resolver, and the processor using _acl_denied on the public path - each caught with a precise message. Judgement, history and the appendix are deliberately NOT pinned."
---

# SM290 - documentation that cannot quietly stop being true

## The evidence for the lint half

Two wrong answers in one session, both from documentation rather than code:

- `docs/architecture/access-control-model.md` said a per-file ACL had no effect
  on an anonymous read, and flagged it as *"the single most important cell"*.
  SM223 had made that false three releases earlier. The correction was appended
  at the foot of the document and the table was never touched.
- The comment above `@user_groups` in `Lazysite::Auth::Acl` said a
  *"token/WebDAV partner carries none"*. False for WebDAV, sitting directly on
  top of the code that disproves it, and copied into the architecture document
  as a headline finding - where it survived the SM224 analysis, an adversarial
  security review, and a feature built on top of it. Roughly a year.

Both were believed by a reader who had every reason to trust them. **Prose about
code is unverified code**, and the only difference from a broken function is
that nothing fails when it is wrong.

## What to write

`docs/architecture/access-control-model.md` becomes the **reference**
: Today it is an SM224 *analysis* with corrections bolted on, which means a
  reader looking for "how does this work" lands in an argument about what it
  should have been. The reference states: the two mechanisms and which question
  each answers; the scope grammar (file / folder / root); the subject grammar
  (owner, user, `@group` with nested expansion); the two policies and how they
  differ on an empty list; and the per-channel resolution table. The historical
  analysis moves to an appendix, kept - it records a decision and its reasoning,
  which is worth having, just not on the path of someone with a question.

`docs/FEATURES.md` Part III
: documents authorization as **authoring** permissions and is silent on the
  visitor-facing half. It gains: that a site can limit who sees a page, a file,
  a folder or the whole site; that pages are governed by
  `auth:`/`groups:`/`auth_default` and paths by `acls.json`; that **gated**
  bounces to the login page while **draft** returns 404 and leaves the sitemap,
  feeds and search; and that protection is **opt-in**, so a file nobody
  mentioned stays public. That last sentence is the one an operator most needs
  and is currently written nowhere.

`docs/manager-ui-guide/`
: the Protect-this-section walkthrough with its Negative row, already
  menu-complete by `t/lint/32`.

## The lint

Every statement of fact about the code gets a guard, in the manner of
`t/lint/31` (the processor's ACL copy matches the shared one) and `t/lint/32`
(the guide covers the nav):

- the **per-channel group-resolution table** is asserted against the actual
  assignments in `lazysite-dav.pl`, `lazysite-mcp.pl` and
  `lazysite-manager-api.pl`. This is precisely the drift that produced SM288,
  and it is a table, so it is mechanically checkable;
- the **scope grammar** is asserted against what `_acl_entry_for` resolves, so a
  scope that is documented but unreachable - SM287's root, exactly - fails the
  build rather than misleading a reader;
- the **policy table** is asserted against the processor's draft and gated
  behaviour, including the empty-list asymmetry;
- the **surface table** fails if a surface gains or loses an ACL verb
  ([[SM289]]).

Comments get the same treatment where they carry a claim about another file: the
one that caused SM288 is now a table of what each channel sets, which is the
form a lint can check.

## Care needed

**A lint that only checks a heading exists is worse than none** - it reports
green while the prose beneath it lies. Assert the *content*: the channel names
and what each resolves from, not that a section called "channels" is present.
`t/lint/31` is the model, because it strips comments before matching so a file
cannot pass by describing the problem it exhibits.

**Do not pin prose that is judgement.** The reasoning, the trade-offs and the
history must stay free to be rewritten. Only the factual rows are pinned, and
the document should make the boundary visible so an editor knows which parts
they can improve without fighting a test.

## Acceptance

- A reader can answer "who can see this, and how do I change it" from one
  document without opening the source.
- FEATURES states the visitor-facing capability, all four scopes, both policies,
  and the opt-in default.
- Every factual table in the reference is asserted against the code, and each
  assertion is verified to FAIL when the code is changed underneath it.
- The SM224 analysis survives as history, off the main path.
- A new surface, channel or scope cannot ship without the table failing.

## Related

`WORK-PLAN-ACCESS-CONTROL.md` (phase 3), [[SM287]], [[SM288]], [[SM289]],
[[SM224]] (the analysis this promotes to a reference), [[SM258]] (the same
idea applied to the CHANGELOG and filing statuses), `t/lint/31`, `t/lint/32`.
