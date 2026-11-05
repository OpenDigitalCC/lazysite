---
provenance: lazysite-starter
starter_role: infrastructure
title: Sign in
auth: none
search: false
---

[%# SM1328: Odoo is named by the site's odoo_display_name; with none, the text names nothing. -%]
[% IF odoo_display_name %]This site's sign-in is your [% odoo_display_name | html %] login: the user name and
password you use for [% odoo_display_name | html %], and the code from your authenticator app if
[% odoo_display_name | html %] asks for one. Signing out here signs you out of [% odoo_display_name | html %] too.
[% ELSE %]Sign in with your user name and password, and the code from your authenticator app
if you are asked for one. Signing out here ends that sign-in too.
[% END %]

::: odoo-signin
:::
