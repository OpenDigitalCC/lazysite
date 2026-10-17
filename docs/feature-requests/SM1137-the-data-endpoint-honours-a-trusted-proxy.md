---
id: SM1137
title: "SM1137: the data endpoint honours a trusted proxy"
subtitle: "lazysite-data.pl used only its own verified session, so a visitor the proxy had signed in was anonymous to a page's data call. It now agrees with the wrapper."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-17
raised-by: left open by the unification of the identity readers (SM1130, SM1131), noted by the release manager's batch
area: auth
status-note: "SHIPPED on n632 (claude/n632-a-marked-directory-group-grants): lazysite-data.pl; t/integration/272."
---

# What happened

SM1130 made a trusted proxy's identity win over a lazysite cookie, in
`lazysite-auth.pl` only. `lazysite-data.pl`, the endpoint a page's own JavaScript
reads a table through, verifies a session cookie of its own and treats a request
without one as anonymous. On a site behind an identity provider, a visitor the
directory had signed in and who held no lazysite cookie read a page the proxy's
headers opened and got "no such table, or not available to you" from the data
call; a visitor with a stale cookie was the cookie's account and not the
directory's.

# What shipped

When `auth_proxy_trusted` is on, the peer is listed in `auth_proxy_trusted_from`
(`Lazysite::Util::proxy_identity`, SM1129) and the request names a user under the
configured header (`request_identity`, SM1131), that identity is the requester:
the cookie is not verified, merged or used as a fallback. The identity stays a
`proxy` identity for everything downstream (no wrapper sentinel is set), so the
capability rule of SM1135 applies: a write needs `manage_data` or `write_data`,
held by an account or by a group the operator marked `directory_grants`. A CSRF
token is minted for the proxy user. With no proxy user the session check is as it
was, and a peer outside the list, or the flag off, leaves the headers as nobody.

t/integration/272 runs the endpoint against a private table whose read rule
names one account and one group: a proxy user with no cookie reads; the proxy's
user beats a cookie for another, in both directions; the proxy's group, mapped,
satisfies `@staff`; a cookie alone behaves as before; an unlisted peer, the flag
off and a client-sent `X-Remote-User` are nobody; a token is minted for the proxy
user and verifies for that user only; a write succeeds through a marked group and
is refused through an unmarked one. The file was put back to its earlier version
and the test went red; the capability merge was switched off alone and the write
subtest went red.
