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

<style>
  .claim-form {
    max-width: min(440px, 100%);
    margin: 1rem 0;
    display: grid;
    grid-template-columns: 8rem 1fr;
    gap: 0.6rem 0.75rem;
    align-items: center;
  }
  .claim-form label { text-align: right; }
  .claim-form input[type="password"] {
    width: 100%;
    max-width: 100%;
    box-sizing: border-box;
    padding: 0.4rem 0.55rem;
    border: 1px solid #ccc;
    border-radius: 3px;
    font: inherit;
  }
  .claim-form input:focus { outline: 2px solid #0056b3; outline-offset: 0; }
  .claim-form .claim-submit { grid-column: 2; }
  .claim-form button {
    padding: 0.45rem 1.25rem;
    font: inherit;
    cursor: pointer;
    border: 1px solid #0056b3;
    background: #0056b3;
    color: #fff;
    border-radius: 3px;
  }
  .claim-form button:hover { background: #003d80; border-color: #003d80; }
  .auth-error {
    color: #b00;
    background: #fee;
    border: 1px solid #fcc;
    padding: 0.5rem 0.75rem;
    border-radius: 3px;
    max-width: 440px;
    box-sizing: border-box;
    margin: 1rem 0;
  }
</style>

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
