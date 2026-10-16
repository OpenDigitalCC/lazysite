---
id: SM1109
title: "SM1109: the sender is a setting, with a real default"
subtitle: "Form SMTP has a From address; empty, the sender is no-reply@ the host of site_url, and a refused RCPT names the sender."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: release manager, 2026-10-16 (0.15.7 test plan)
area: mail
status-note: "SHIPPED on n615: plugins/form-smtp.pl resolve_from; lib/Lazysite/Manager/Plugins.pm; t/unit/forms/63."
---

# What happened

From the same results (U6):

    The default sender webforms@localhost is refused by a real mail server ...
    the Form SMTP settings cannot change (the extension has no From field) ...
    Wanted: a site-level From on the Form SMTP extension (or site_url's host
    as the default), and the outbox naming the sender when RCPT fails.

The release manager ruled the default ("from default ok").

# What shipped

Every message the site sends passes through `plugins/form-smtp.pl`, so one
resolver, `resolve_from`, serves forms mail, notifications and account claim
mails. The sender is, in order:

1. the handler's own `from`;
2. the Form SMTP extension's new **From address** setting (`from` in smtp.conf),
   validated as exactly one address when it is saved;
3. `no-reply@` followed by the host of `site_url` (expanded; port and path are
   not part of it);
4. `webforms@localhost` only when `site_url` does not resolve to an absolute
   address - which is logged as a warning saying so.

A refused RCPT now reads `RCPT TO refused for <to> sending as <from>: <server
reply>`, so the outbox names the sender the server was shown.

t/unit/forms/63.
