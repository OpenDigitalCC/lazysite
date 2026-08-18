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

# The reference fixture

Written from outside by the site agent as the reference implementation,
after this was filed. The sequence, every step load-bearing:

```
1  mkcol  /zz-gate/
2  put    /zz-gate/seen.png     identical bytes to every other probe file
3  GET    /zz-gate/seen.png     anonymously - POPULATES the front-end cache
4  set_permissions {path: /zz-gate/, read: [nobody]}
                                 MUST report content_moved
5  put    /zz-gate/never.png    AFTER protection. Never fetched by anyone
6  GET    /zz-gate/seen.png     anonymously
7  GET    /zz-gate/never.png    anonymously
```

The verdict is read from **steps 6 and 7 together**, never either alone:

```datatable
columns: seen | never | Diagnosis
widths: 2.2cm | 2.2cm | X
bold: 1
tone: medium
---
200 | **302** | Front-end cache residue. Bounded, self-clearing. NOT an exposure
200 | **200** | Genuine extension-based bypass - protected content is being served
302 | 302 | Fully gated, nothing to report
---
```

::: widebox
**Step 4 is the whole filing, and the assertion is the fix.** Applying
protection through the engine's own call moves the content; writing
`acls.json` does not. **Assert on `content_moved`** - if it is absent or
zero, the fixture has not established the condition it is about to
measure. That single assertion is what would have caught this, and it is
already structural (SM313) rather than a matched warning string.
:::

Step 3 is equally non-optional in the other direction: without the
pre-protection fetch there is no cache to tell apart from a bypass, both
files gate, and the probe passes while proving nothing.

# What the fixture cannot tell you

Recorded because a fixture overstating its reach is how this started.

- It proves what happened to two files in one folder at one moment, not
  that the front end is safe generally.
- A `302` on the never-fetched file means the residue is **bounded and
  self-clearing** ([[SM331]]), not that it is harmless.
- It says nothing about which front-end template is in play. Check
  `X-Lazysite-Front` separately.

# Measured

On edge/0.10.14, 2026-08-18, stock proxy template:

```
/zz-g2/seen.png    fetched before protecting   200  served
/zz-g2/never.png   written after protecting    302  gated
```

Same folder, same ACL, same extension, seconds apart.

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
