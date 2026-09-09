---
title: Your account
auth: manager
search: false
---

<!-- SM807: TITLED FOR THE PAGE THAT IS ACTUALLY READ.
     The layout renders the front-matter title as the h1 before the body, so
     an account without manage_config - which stays here rather than being
     forwarded (SM775) - was shown its own account landing under the heading
     SITE SETTINGS, and the field read that as still landing on the settings
     page. An account WITH manage_config never reads this heading: it is
     replaced before paint by the redirect below.

     The first attempt at this invented a `page_title_when_no_config` front
     matter key, which nothing reads - a declaration the code ignores, which
     is the thing this project keeps filing against. -->

[% IF manager_caps.manage_config %]
<p>Redirecting to <a href="/manager/config">Configuration</a>...</p>

<script>
// SM724: keep the query - ?account=1 is where a sign-in with no destination
// lands, and the account sheet opens from it on the page this redirects to.
location.replace('/manager/config' + location.search + location.hash);
</script>
[% ELSE %]
<!-- SM775: AN ACCOUNT THAT CANNOT READ THE CONFIGURATION IS NOT SENT TO IT.
     /manager/ redirected to /manager/config unconditionally, so an account
     without manage_config arrived at a heading and an empty body: the page
     renders, its reader is refused, and nothing said so. It read as a broken
     manager to the very account the start-page feature exists for.

     A sign-in with no destination lands at fallback_landing(), which is this
     page with ?account=1, and the account sheet lives in the layout. So the
     two arrivals now agree by STAYING here - rather than by both being
     forwarded to a page one of them cannot read. -->
<div class="mg-card">
  <div class="mg-card-header">
    <span class="mg-card-title">Your account</span>
    <span class="mg-card-subtitle">what this account can open</span>
  </div>
  <div class="mg-card-body">
    <p>Site settings are managed by an account holding <strong>Configuration</strong>.
    This account does not hold it, so the settings page would show you nothing.</p>
    <p>Your own details are on the
    <a href="#" onclick="mgOpenAccount();return false;">account sheet</a>, and the
    pages you can open are listed in the menu.</p>
  </div>
</div>

<script>
// The sheet opens on arrival when the URL asks for it, exactly as it does on
// every other manager page - this page is now one of the places you can land.
if (/[?&]account=1(?:&|$)/.test(location.search)) { mgOpenAccount(); }
</script>
[% END %]
