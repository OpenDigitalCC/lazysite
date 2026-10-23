---
provenance: lazysite-starter
title: Set your password
auth: none
search: false
query_params:
  - u
  - c
  - error
  - min
---

[% IF query.error == 'https' %]

<p class="auth-error">A password can only be set over a secure (HTTPS)
connection. This link has not been used: open it again with an address that
begins <code>https://</code>, or ask your site operator for one that does.</p>

[% ELSIF query.error && query.error != 'short' %]

<p class="auth-error">That setup link is invalid or has expired. Setup links
work once and are short-lived &mdash; ask your site operator for a new one.</p>

[% ELSE %]

[% IF query.error == 'short' %]
<p class="auth-error">That password is too short. Choose one of at least
[% query.min %] characters. This link has not been used.</p>
[% END %]

<p>Set a password for <strong>[% query.u %]</strong>. This link works
once.</p>

<form method="POST" action="/cgi-bin/lazysite-auth.pl?action=claim" class="claim-form">
  <input type="hidden" name="username" value="[% query.u %]">
  <input type="hidden" name="claim" value="[% query.c %]">

  <label for="password">New password</label>
  <input type="password" name="password" id="password" required autocomplete="new-password">

  <div class="claim-submit">
    <button type="submit">Set password</button>
  </div>
</form>

[% END %]
