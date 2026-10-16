---
id: SM1111
title: "SM1111: a failed sendmail says how it failed"
subtitle: "The sendmail failure decodes the wait status and quotes stderr; an import reply says handed to the mail transport."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: release manager, 2026-10-16 (0.15.7 test plan)
area: mail
status-note: "SHIPPED on n615: plugins/form-smtp.pl send_via_sendmail; lib/Lazysite/Manager/AccountImport.pm; t/unit/forms/65, t/integration/253."
---

# What happened

From the same results (U9):

    The sendmail method's failure is opaque. 'sendmail failed: exit 256' is the
    raw wait status (exit code 1), with no stderr.

    An import apply reported 'mailed 3, not mailed 0' while the same site's
    sendmail could deliver nothing, so 'mailed' means 'handed to the
    transport'. Worth saying so in the reply.

# What shipped

A failed sendmail reads `sendmail failed: exit code 1: <its first lines of
stderr>` or `killed by signal 9 (KILL)`; stderr is captured for the run and
restored after, and the tail is bounded to three lines and 300 characters.

The account-import reply says `handed to the mail transport N, not handed over
M`, its audit rows and the page say the same, and `mail.meaning` states that the
count is mails the transport accepted and delivery is not confirmed. The keys
(`mailed`, `mail.sent`, `mail.not_sent`) are unchanged.

t/unit/forms/65, t/integration/253.
