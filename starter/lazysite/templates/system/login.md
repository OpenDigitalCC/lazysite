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
[% ELSIF query.error == 'passkey-only' %]
<p class="auth-error">Your account signs in with a passkey. Use "Sign in with a passkey" below.</p>
[% ELSIF query.error == 'passkey' %]
<p class="auth-error">That passkey was not accepted. Try again, or sign in another way.</p>
[% ELSIF query.error == 'passkey-unavailable' %]
<p class="auth-error">This site cannot check passkeys at the moment (a library is missing on the server). Sign in another way.</p>
[% ELSIF query.error %]
<p class="auth-error">Invalid username or password.</p>
[% END %]

[% IF query.claimed %]
[% IF query.claimed == 'passkey' %]<p class="login-context">Your passkey is set. Use "Sign in with a passkey" below.</p>[% ELSE %]<p class="login-context">Your password is set. Sign in below.</p>[% END %]
[% END %]

[% IF query.reset %]
<p class="login-context">If an interactive account with an email on file matches, a one-time reset link has been sent.</p>
[% END %]

[% IF query.next %]
<p class="login-context" data-ls-auth-in>
  <span class="login-context-url">[% query.next %]</span> requires you to sign in.
</p>
[% END %]

[%# SM1322 (ruling 49): data-ls-auth-check has the chrome script ask the server whether the
    session is still honoured; a refused or stale one shows the sign-in below instead.
    Ruling 85: a session it honours may still be one ?next= does not admit, so the panel
    offers "Sign in as someone else": the sign-out, landing back on this form with next. %]
<div class="login-context" data-ls-auth-out data-ls-auth-check style="display:none">
  <p><strong>You are already signed in.</strong></p>
  <p><a href="/">Go to the site</a> &middot; <a href="/account">Your account</a> &middot; <a href="/cgi-bin/lazysite-auth.pl?action=logout">Sign out</a></p>
  <p><a href="/cgi-bin/lazysite-auth.pl?action=logout&amp;then=signin[% IF query.next %]&amp;next=[% query.next | uri %][% END %]" data-ls-signin-other>Sign in as someone else</a></p>
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

[%# SM1352: a passkey signs in without the form above. The script (lazysite-account.js)
    shows this only to a browser that can use one; the server offers it only when it can
    check one (CryptX). The answer is posted as a form, so the landing and every refusal
    are the password sign-in's own. The installed app signs in through this same page. %]
[% IF passkeys %]
<div class="login-passkey" data-ls-account="passkey-signin" data-ls-auth-in hidden>
  <form method="POST" action="/cgi-bin/lazysite-auth.pl?action=passkey-login" data-ls-passkey-form>
    <input type="hidden" name="next" value="[% query.next %]">
    <input type="hidden" name="pk_id">
    <input type="hidden" name="pk_client_data">
    <input type="hidden" name="pk_authenticator_data">
    <input type="hidden" name="pk_signature">
    <div class="login-submit">
      <button type="button" data-ls-passkey-go>Sign in with a passkey</button>
    </div>
  </form>
  <p class="lz-account-status" data-ls-status role="status" aria-live="polite"></p>
</div>
[% END %]

[%# SM1299 (ruling 38), SM1369 X4: a site whose sign-in is an identity provider's offers it
    here too, carrying any next through to the provider's page; the local form above stays.
    Each option's label is the provider's (SM1328: the name the site gives the system, or none),
    and its class names the provider (login-<id>). %]
[% FOREACH o IN login_options %]<p class="login-[% o.id | html %]" data-ls-auth-in><a href="[% o.path | html %][% IF query.next %][% o.sep | html %]next=[% query.next | uri %][% END %]">[% o.label | html %]</a></p>[% END %]

[% IF smtp_configured %]<p data-ls-auth-in style="margin-top:0.5rem;font-size:0.9rem;"><a href="/forgot">Forgot password?</a></p>[% END %]
