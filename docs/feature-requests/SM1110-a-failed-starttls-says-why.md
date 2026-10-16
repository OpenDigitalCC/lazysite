---
id: SM1110
title: "SM1110: a failed STARTTLS says why"
subtitle: "A certificate for the wrong name is reported with the names it is for and the host connected to."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: release manager, 2026-10-16 (0.15.7 test plan)
area: mail
status-note: "SHIPPED on n615: plugins/form-smtp.pl _starttls, starttls_failure; t/unit/forms/64."
---

# What happened

From the same results (U7):

    STARTTLS fails on a hostname mismatch with only 'STARTTLS failed'... the
    message should say 'certificate is for isp.cloudient.net, not
    mail.explore.lazysite.io'.

# What shipped

The STARTTLS step watches the verify callback for the certificate's names
(subject alternative names, else the common name) without changing its verdict.
A name mismatch reads `STARTTLS failed: certificate is for A, B, not HOST
(hostname verification failed)`; any other certificate failure carries the TLS
library's reason; a server that answers STARTTLS with a refusal is quoted
(`the server replied 454 ...`). The Validate action reports the same sentence for
a refused certificate and keeps its "may not offer STARTTLS" advice for a server
that never got that far.

t/unit/forms/64 drives all three against a local server that offers STARTTLS
with a generated certificate.
