---
title: "SM377: the ACL probe reports on a state the engine never leaves in place"
subtitle: "It records an ACL rule and leaves its own files in the document root. The engine protects content by MOVING it out. So the probe measures unprotected files, finds them served, and reports the site's protected content as exposed - in the same run where another check reports it correctly moved."
brand: plain
standard-margins: true
status: candidate
---

# The contradiction, in one deploy

On edge, 0.10.14, in a single `lazysite-hestia-update-all.sh` run:

```datatable
columns: Check | Verdict
widths: 7.4cm | X
bold: 1
tone: medium
---
`protected content is held outside the document root, with no public copy left beside it` | **ok**
outside-in ACL probe | **FAIL** - "a file the engine refuses is served to anonymous visitors ... the split is by FILE EXTENSION and not a stale cache"
---
```

Two checks, one tool, one run, flatly contradicting each other about the
same site.

A partner agent then settled it from outside with the control the probe
is meant to be making:

```datatable
columns: File | Result
widths: 7.4cm | X
bold: 1
tone: medium
---
fetched once BEFORE protecting | 200, served
written AFTER protecting, through the engine, never read | **302, gated**
---
```

Same folder, same ACL, same extension. The protected content is **not**
exposed.

# Why the probe says otherwise

`_acl_write` stores `acls.json` and nothing else.

The engine protects content by **moving it into the private store** -
that is what `lazysite-acl.pl re-apply` does, what the installer's
"re-applying access rules (moves protected content out of the docroot)"
step does, and what the passing check above asserts.

So the probe's own files stay in the document root. A front end that
serves statics by extension then serves them - **correctly, because
nothing ever protected them** - and the probe reads that as proof the
site's real protected content is reachable.

::: widebox
**The probe's late-file discriminator inherits the same flaw.** SM368
added it to tell "front end serves by extension" from "stale cache", by
writing a file after the gate and never fetching it. But that file is
written straight to the document root too, so it is served for the same
reason the others were - and the discriminator returns `extension`
every time, which is exactly what it did here.
:::

This is SM368's shape a second time, in the code that fixed it:
measurement and inference in one sentence, and the inference is the half
that sends an operator after a template that is not the problem.

# What is true, and what is not

The measurement is right: the front end **is** answering some extensions
without consulting the engine. That is the SM283 condition and it is
worth knowing.

The inference is wrong: it matters only for protected content **still in
the document root**. Once the engine has moved that content out, the
front end has nothing left to serve, which is precisely the state the
other check confirms.

# What NOT to do, recorded because it was tried

Suppressing the FAIL when the probe's files are unmoved looks like the
fix and is not: the probe **never** moves them, so that condition is true
on every run and the change would downgrade a genuine exposure to a
warning. It was written, tested against the logic, and reverted.

# The fix, and it needs a decision

Either the probe applies protection the way the engine does - calling
the same `action_acl_set` path `lazysite-acl.pl` uses, which returns a
structural `content_moved` flag (SM313) - so it tests the real state, or
it reports the front-end behaviour **without** the claim about protected
content, and leaves the exposure question to the check that already
answers it correctly.

The first is better and larger: `lazysite-check.pl` does not currently
load the Manager modules, and giving a check tool the power to move
content is a decision rather than a refactor.

# Verification

- The probe, run on a site whose protected content has been moved,
  does not report that content as reachable.
- A site with protected content genuinely left in the document root
  still fails, loudly - the current behaviour must not be lost.
- The two checks in one run cannot disagree about the same site.

# Related

[[SM368]] (the discriminator this inherits, and the same defect shape),
[[SM331]] (cache residue, the other candidate cause), [[SM283]] (the
front-end condition, which is real), [[SM313]] (`content_moved` as a
structural flag rather than a matched warning string).
