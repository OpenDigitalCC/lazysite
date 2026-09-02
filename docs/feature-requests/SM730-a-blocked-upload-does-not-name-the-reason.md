---
id: SM730
title: "SM730: a blocked upload says \"Blocked target\" without naming the reason"
subtitle: "The brand-folder extension guard fires correctly on the real upload path - proved in the field at last - but its refusal says only that something was blocked, where the capability refusals beside it name the rule. The same defect SM712 fixed one surface up."
brand: plain
standard-margins: true
status: shipped
---

# The guard works

Proved by the edge testing agent, 2026-09-02, through the real `file-upload`
endpoint in an authenticated cookie session with the manager's CSRF token -
which is why it could not be proved from any token surface in the two previous
rounds:

- `probe.tex` → refused, `errors:[{"error":"Blocked target","name":"probe.tex"}]`,
  `saved:[]`, not written.
- `probe.png` → accepted, `saved:[{"path":"lazysite/brands/probe.png"}]`.

**Server-side, on the path an operator actually uses.** That closes 9T-07, open
since 0.11.9, and it is the answer SM707 wanted: a brand template is executable
input and the manager refuses one.

# What is wrong with the refusal

**"Blocked target" names nothing.** Not the rule, not the extension, not the
folder it applies to. An operator uploading `logo.tex` learns that something
about their file was unacceptable and has to guess which.

Compare what sits one surface away, after SM712, in the same session's results:

> `Insufficient capability for data-tables (needs manage_data). Call
> describe-capabilities...`

That names the action, the capability and the remedy. The two refusals are the
same kind of event answered to very different standards, and the weaker one is
in the place with less context to fall back on - a file upload has no
`describe-capabilities` to send the reader to.

# Why this is not just wording

SM707 refuses `.tex`, `.latex`, `.sty`, `.cls` and `.lua` in the brand folder
because that text reaches `xelatex` and `\input{/etc/passwd}` would be read as
the CGI user. **That reasoning is invisible in "Blocked target".** An operator
who has legitimately prepared a LaTeX brand template is not told that the
refusal is deliberate, permanent and about safety - so the likely next step is
to try to work around it.

A refusal that explains itself is what stops a guard being treated as a bug.

# Shape of an answer

Name the reason and the rule, in the refusal the upload returns: the extension,
that it is disallowed in this folder, and why in one clause. The extension list
already exists in `Lazysite::Manager::Common`; the refusal simply does not
consult it when composing the message.

**Worth checking whether "Blocked target" has other callers** before changing
it. If it is the generic refusal for every blocked upload, the fix is to give it
a reason parameter rather than to special-case this one - and then the same
improvement lands wherever else it is used, which is the better outcome and the
reason to look first.
