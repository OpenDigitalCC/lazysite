---
title: Sign in
auth: none
search: false
query_params:
  - error
  - next
---

[% IF query.error %]
<p class="auth-error">Invalid username or password.</p>
[% END %]

<form method="POST" action="/cgi-bin/lazysite-auth.pl?action=login"
      class="auth-form">
  <input type="hidden" name="next"
         value="[% query.next | html %]">
  <div class="form-field">
    <label for="username">Username</label>
    <input type="text" name="username" id="username"
           required autocomplete="username">
  </div>
  <div class="form-field">
    <label for="password">Password</label>
    <input type="password" name="password" id="password"
           required autocomplete="current-password">
  </div>
  <div class="form-field form-submit">
    <button type="submit">Sign in</button>
  </div>
</form>

Demo credentials: `demo` / `demo`

Try the [members area](/members) to see auth in action.
