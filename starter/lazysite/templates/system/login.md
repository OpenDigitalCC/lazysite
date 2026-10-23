---
provenance: lazysite-starter
title: Sign in
auth: none
search: false
query_params:
  - error
  - next
  - claimed
  - reset
---

[% IF query.error == 'mfa' %]
<p class="auth-error">Enter your two-factor code to finish signing in.</p>
[% ELSIF query.error == 'unavailable' %]
<p class="auth-error">Sign-in is unavailable: the site cannot read its account records. This is a fault on the server, not your password. The site operator can see the cause in the site log.</p>
[% ELSIF query.error == 'address' %]
<p class="auth-error">Sign-in is not available from your address.</p>
[% ELSIF query.error %]
<p class="auth-error">Invalid username or password.</p>
[% END %]

[% IF query.claimed %]
<p class="login-context">Your password is set. Sign in below.</p>
[% END %]

[% IF query.reset %]
<p class="login-context">If an interactive account with an email on file matches, a one-time reset link has been sent.</p>
[% END %]

[% IF query.next %]
<p class="login-context" data-ls-auth-in>
  <span class="login-context-url">[% query.next %]</span> requires you to sign in.
</p>
[% END %]

<div class="login-context" data-ls-auth-out style="display:none">
  <p><strong>You are already signed in.</strong></p>
  <p><a href="/">Go to the site</a> &middot; <a href="/account">Your account</a> &middot; <a href="/cgi-bin/lazysite-auth.pl?action=logout">Sign out</a></p>
</div>

<form method="POST" action="/cgi-bin/lazysite-auth.pl?action=login" class="login-form" data-ls-auth-in>
  <input type="hidden" name="next" value="[% query.next %]">
  <label for="username">Username</label>
  <input type="text" name="username" id="username" required autocomplete="username">
  <label for="password">Password</label>
  <input type="password" name="password" id="password" autocomplete="current-password">
  <label for="code">2FA code</label>
  <input type="text" name="code" id="code" inputmode="numeric" autocomplete="one-time-code" placeholder="if 2FA is enabled">
  <div class="login-submit">
    <button type="submit">Sign in</button>
  </div>
</form>

[% IF smtp_configured %]<p data-ls-auth-in style="margin-top:0.5rem;font-size:0.9rem;"><a href="/forgot">Forgot password?</a></p>[% END %]
