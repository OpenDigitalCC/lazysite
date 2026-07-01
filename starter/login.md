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

<style>
  /* Single-column stack (label above input). Deliberately NOT a 2-column grid:
     the page is Markdown, which wraps the form's fields in <p>, so a grid that
     relies on label/input being separate grid items mis-aligns (password ends up
     beside the 2FA field). A block stack is immune to that wrapping. */
  .login-form {
    max-width: min(360px, 100%);
    margin: 1rem 0;
  }
  .login-form label {
    display: block;
    font-weight: 600;
    margin: 0.7rem 0 0.2rem;
  }
  .login-form input[type="text"],
  .login-form input[type="password"] {
    display: block;
    width: 100%;
    max-width: 100%;
    box-sizing: border-box;
    padding: 0.4rem 0.55rem;
    border: 1px solid var(--theme-colours-border, #ccc);
    border-radius: 3px;
    background: var(--theme-colours-surface, #fff);
    color: var(--theme-colours-text, inherit);
    font: inherit;
  }
  .login-context {
    background: var(--theme-colours-surface, #f0f4ff);
    border-left: 3px solid var(--theme-colours-accent, #0066cc);
    padding: 0.5rem 0.75rem;
    border-radius: 3px;
    font-size: 0.9rem;
    margin-bottom: 1rem;
    max-width: min(480px, 100%);
    box-sizing: border-box;
  }
  .login-form input:focus { outline: 2px solid var(--theme-colours-accent, #0056b3); outline-offset: 0; }
  .login-form .login-submit { margin-top: 1rem; }
  .login-form button {
    padding: 0.45rem 1.25rem;
    font: inherit;
    cursor: pointer;
    border: 1px solid var(--theme-colours-accent, #0056b3);
    background: var(--theme-colours-accent, #0056b3);
    color: var(--theme-colours-on-accent, #fff);
    border-radius: 3px;
  }
  /* brightness shift adapts to any accent, no second hardcoded colour needed */
  .login-form button:hover { filter: brightness(0.92); }
  .auth-error {
    color: #b00;
    background: #fee;
    border: 1px solid #fcc;
    padding: 0.5rem 0.75rem;
    border-radius: 3px;
    max-width: 420px;
    box-sizing: border-box;
    margin: 1rem 0;
  }
  .demo-creds code {
    font-family: ui-monospace, Menlo, Consolas, monospace;
    background: var(--theme-colours-surface, #f0f0f0);
    padding: 0.1em 0.4em;
    border-radius: 3px;
  }
  /* SM052: .login-context-url replaces a <code> wrapper that
     was eating the TT expression inside it. render_content's
     code-block protection regex treats <code>...</code> as
     literal and skips TT evaluation. This span looks the same
     but isn't caught. */
  .login-context-url {
    font-family: ui-monospace, Menlo, Consolas, monospace;
    background: var(--theme-colours-surface, #f0f0f0);
    padding: 0.1em 0.35em;
    border-radius: 3px;
    word-break: break-all;
  }
</style>

[% IF query.error == 'mfa' %]
<p class="auth-error">Enter your two-factor code to finish signing in.</p>
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
  <span class="login-context-url">[% query.next | html %]</span> requires you to sign in.
</p>
[% END %]

<div class="login-context" data-ls-auth-out style="display:none">
  <p><strong>You are already signed in.</strong></p>
  <p><a href="/">Go to the site</a> &middot; <a href="/cgi-bin/lazysite-auth.pl?action=logout">Sign out</a></p>
</div>

<form method="POST" action="/cgi-bin/lazysite-auth.pl?action=login" class="login-form" data-ls-auth-in>
  <input type="hidden" name="next" value="[% query.next | html %]">
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
