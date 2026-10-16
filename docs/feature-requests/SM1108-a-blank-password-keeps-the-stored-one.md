---
id: SM1108
title: "SM1108: a blank password keeps the stored one"
subtitle: "Saving an extension with an empty password field no longer clears the stored password, for every extension."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: release manager, 2026-10-16 (0.15.7 test plan)
area: auth
status-note: "SHIPPED on n615: lib/Lazysite/Manager/Plugins.pm action_plugin_save; t/unit/manager/348."
---

# What happened

From the 0.15.6/0.15.7 test-plan results, "Found while getting mail to send" (U5):

    A blank password clears the stored SMTP password. The Form SMTP field says
    'Leave blank to keep the current one'. An extension-save with password: ''
    answered changed: [..., 'password'], and the next send failed 'SMTP auth
    failed'.

The manager never sends a stored password back, so a form saved with the field
untouched posts it empty. `action_plugin_save` wrote the empty value over the
stored one.

# What shipped

`action_plugin_save` skips a `type: password` field whose value is empty or only
whitespace: nothing is written for it and it is not in `changed`. It is the save
that reads the schema, so the rule holds for every extension and not only Form
SMTP. A new value still lands and is reported changed. The same save still
writes the other fields of the form.

There is no explicit way to clear a password and none was added (the form never
offered one): a password is removed by editing the extension's config file.

t/unit/manager/348.
