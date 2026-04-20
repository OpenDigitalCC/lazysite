---
title: Members Area
subtitle: This page requires authentication.
auth: required
---

## Welcome, [% auth_user %]

You are signed in and viewing a protected page.

Your groups: [% IF auth_groups.size %][% auth_groups.join(', ') %][% ELSE %]none[% END %]

This page demonstrates the `auth: required` front matter key. Without
a valid login, you are redirected to the sign-in page.

### Demo credentials

Username: `manager`
Password: (none required on localhost)

[Sign out](/cgi-bin/lazysite-auth.pl?action=logout)
