---
title: Site settings
auth: manager
search: false
---

<p>Redirecting to <a href="/manager/config">Configuration</a>...</p>

<script>
// SM724: keep the query - ?account=1 is where a sign-in with no destination
// lands, and the account sheet opens from it on the page this redirects to.
location.replace('/manager/config' + location.search + location.hash);
</script>
