---
provenance: lazysite-starter
title: Reset your password
auth: none
search: false
---

<style>
  .reset-form {
    max-width: min(440px, 100%);
    margin: 1rem 0;
    display: grid;
    grid-template-columns: 9rem 1fr;
    gap: 0.6rem 0.75rem;
    align-items: center;
  }
  .reset-form label { text-align: right; }
  .reset-form input[type="text"] {
    width: 100%; max-width: 100%; box-sizing: border-box;
    padding: 0.4rem 0.55rem; border: 1px solid #ccc; border-radius: 3px; font: inherit;
  }
  .reset-form .reset-submit { grid-column: 2; }
  .reset-form button {
    padding: 0.45rem 1.25rem; font: inherit; cursor: pointer;
    border: 1px solid #0056b3; background: #0056b3; color: #fff; border-radius: 3px;
  }
  .reset-form button:hover { background: #003d80; border-color: #003d80; }
</style>

<p>Enter your username or email. If an interactive account with an email on
file matches, a one-time link to set a new password is sent. This link works
once and expires in 24 hours.</p>

<form method="POST" action="/cgi-bin/lazysite-auth.pl?action=forgot" class="reset-form">
  <label for="identifier">Username or email</label>
  <input type="text" name="identifier" id="identifier" required autocomplete="username">

  <div class="reset-submit">
    <button type="submit">Send reset link</button>
  </div>
</form>
