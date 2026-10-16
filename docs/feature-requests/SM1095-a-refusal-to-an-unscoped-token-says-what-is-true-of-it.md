---
id: SM1095
title: "SM1095: a refusal to a token with no scope says what is true of it"
subtitle: "A domain refusal formatted an empty scope list as \"inside no scope\"; a caller naming no scope is now told it is not confined to a domain's content and what it does reach."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-16
raised-by: the 0.15.5 test plan, "Domain-reach wording" (T6)
area: manager
status-note: "SHIPPED on n605: Lazysite::Manager::Common::domain_reach_refusal; t/unit/manager/343."
---

# What happened

The 0.15.5 test plan: "A token naming no scope is told "A domain-confined
caller reaches only the domains whose content lies inside no scope: (default)"
- correct under SM976, but it reads as nonsense to an account whose brief says
"Content scope: whole docroot"."

`domain_reach_refusal` built one sentence for every caller and filled in the
scope with `no scope` when the list was empty.

# What shipped

SM976's rule (R3, "Keep for primary"): a token, grant or account naming no scope
is not confined to a domain's content; it reaches the primary and the domains
that serve the primary's content, and a domain with a content root of its own
needs a scope that covers that root. A caller with no scope is now refused in
those words:

    You cannot reach the domain 'alpha.test'. This caller names no scope, so it
    is not confined to a domain's content and reaches only the instance's
    default domain and the domains that serve its content; a domain with a
    content root of its own needs a scope that covers that root. It reaches:
    (default), mirror.test.

A caller that has scopes keeps the confined-caller sentence naming them. The
refusal's `kind` and `domains` are unchanged.

t/unit/manager/343.
