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

[% ELSIF query.error && query.error != 'short' && query.error != 'passkey' && query.error != 'passkey-unavailable' %]

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

[%# SM1352: or a passkey, in place of the password, through this same link. The
    script (lazysite-account.js) shows this only to a browser that can make one. %]
[% IF passkeys %]
[% IF query.error == 'passkey' %]
<p class="auth-error">That passkey was not added. This link has not been used: try
again, or set a password above.</p>
[% ELSIF query.error == 'passkey-unavailable' %]
<p class="auth-error">This site cannot add passkeys at the moment (a library is
missing on the server). This link has not been used: set a password above.</p>
[% END %]
<div class="claim-passkey" data-ls-account="passkey-claim" hidden>
  <p>Or use a passkey: your phone or computer signs you in with your fingerprint,
  face or screen lock, and there is no password to remember.</p>
  <form method="POST" action="/cgi-bin/lazysite-auth.pl?action=claim" data-ls-passkey-form>
    <input type="hidden" name="username" value="[% query.u %]">
    <input type="hidden" name="claim" value="[% query.c %]">
    <input type="hidden" name="pk_id">
    <input type="hidden" name="pk_client_data">
    <input type="hidden" name="pk_authenticator_data">
    <input type="hidden" name="pk_public_key">
    <input type="hidden" name="pk_alg">
    <input type="hidden" name="pk_label" value="Added with the setup link">
    <div class="claim-submit">
      <button type="button" data-ls-passkey-go>Use a passkey instead</button>
    </div>
  </form>
  <p class="lz-account-status" data-ls-status role="status" aria-live="polite"></p>
</div>
[% END %]

[% END %]
