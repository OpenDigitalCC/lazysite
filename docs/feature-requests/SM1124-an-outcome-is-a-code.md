---
id: SM1124
title: "SM1124: an outcome is a code, never a sentence"
subtitle: "A no-JS refusal redirects with a short code and the page owns the wording, so a crafted link can no longer make a site's own page print someone else's words."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: security review (content spoofing, low severity), 0.15.9 walk finding F-3
area: forms
status-note: "SHIPPED on n626: plugins/form-handler.pl %REFUSAL_SAID, lazysite-processor/forms.pm _form_outcome_banner; t/unit/forms/67, t/lint/156. A security fix: content spoofing, low severity."
---

# What happened

The 0.15.9 walk, finding F-3 (security: content spoofing, low severity):

> the refusal sentence travels in the `outcome` query parameter, and the page
> prints any text placed there. `?form=zz59-x&outcome=zz59+probe+text` shows
> "zz59 probe text" under the page's content. It is HTML-escaped (`<b>` comes
> out as `&lt;b&gt;`), so it is not script injection. But anyone can send a link
> that makes a site's own page display their wording (a phone number, "your
> account is suspended"). Suggest an outcome code mapped to engine text, or a
> flash message.

A form posted without JavaScript is answered with a 303 back to its page. A
success already travelled as a code (`ok`, `ok-processing`, SM579), but a
refusal travelled as its sentence in `outcome=`, and the page printed whatever
`outcome=` held, escaped, in the error style.

# What shipped

The redirect carries a code, never prose.

- `plugins/form-handler.pl` holds one table, `%REFUSAL_SAID`, of code to
  sentence. Every refusal it shows the submitter is raised through `refuse`
  with a code: the timing refusals (`too-fast`, `expired`, SM888 A7), the rate
  limit (`rate`, SM1115), a contentless submission (`empty`), the upload limits
  (`no-uploads`, `too-many-files`, `file-too-large`, `file-type`), an
  over-long field (`field-long`), each declared-rule breach (`field-required`,
  `field-email`, `field-url`, `field-number`, `field-max-length`, `field-max`,
  `field-min`, `field-pattern`), a form with no engine modules or no active
  delivery (`unavailable`, `undelivered`), and the catch-all (`error`).
- A sentence with a number or a field's name in it takes it as a separate
  parameter, each of a fixed shape: `retry=N` (digits only, at most 60 shown),
  `n=N` (a number), `field=NAME` (one plain token). The page inserts them into
  the sentence template.
- `lazysite-processor/forms.pm` holds the same table as `%REFUSED` and
  t/lint/156 holds the two to each other. A code the table does not hold, or a
  parameter not of its shape, shows one generic sentence, "Your submission could
  not be accepted. Please try again." The outcome and the parameters are never
  printed. A `field=` is used only if the form on the page declares that field.
- The JSON (fetch) path is not a URL anyone can forge into a link and still
  returns the full message in its body.
- Every sentence keeps its wording. The exception is the two file refusals on
  the no-JS path, which named the uploaded file: a name cannot travel in a URL
  and be printed, so that page says "A file is too large (max N KiB)." and
  "A file is of a type this form does not accept." The JSON path still names the
  file.

t/unit/forms/67 forges `outcome=`, `retry=`, `n=` and `field=` text and finds
none of it on the page, drives each real refusal through the handler with a real
POST and reads the sentence on the page the redirect lands on, and checks that
`retry=` inserts digits only. The characterisation record of the form renderer
(t/unit/processor/112) was re-recorded: the hostile `outcome=` cases now show
the generic sentence.
