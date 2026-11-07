---
id: SM1408
title: "SM1408: a token's group refusal says what it is"
subtitle: "Every token deletes and changes only the groups it created, and the refusal called that caller domain-confined, which a token confined to no domain read as wrong. The rule stands; both refusals and delete_group's description now say a token is bound by it and the operator deletes or changes any group from the manager's Groups page."
brand: plain
standard-margins: true
status: shipped
raised: 2026-11-07
raised-by: "the lazysite developer agent, from edge testing of 0.16.7 (T-104, brief n774)"
area: users
status-note: "SHIPPED (0.16.8) on n774: the two refusals in Lazysite::Manager::Groups and delete_group's MCP description reworded; the rule is unchanged. t/integration/368."
---

# What happened

On the 0.16.7 edge run (T-104, R9 W1) `delete_group analytics-agent` over the
sysops token answered "'analytics-agent' was not created by this account. A
domain-confined caller deletes only the groups it created with group-set; ask
the operator". The token's grant reaches no particular domain, so the words
read as wrong. The refusal is right: `Lazysite::Manager::Groups` takes
`confined` from `request_domain_confined`, which is 1 for every token (and for
a cookie account whose groups bind a domain), and MCP passes `confined => 1`
for every grant. SM1387 and SM1050 made it so on purpose: a token makes and
manages its own groups, and any other is another domain's or the instance's.

# The change

The rule is kept. The words say who it binds and who it does not:

group-delete, delete_group
: "'NAME' was not created by this account. A token, or an account whose
  groups confine it to a domain, deletes only the groups it created (group-set,
  or set_group over MCP); the operator deletes any group from the manager's
  Groups page."

group-set, set_group
: "'NAME' exists and was not created by this account. A token, or an account
  whose groups confine it to a domain, changes only the groups it created
  (group-set, or set_group over MCP); choose another name, or the operator
  changes any group from the manager's Groups page."

The refusal is shared by both doors, so it names both doors' create action.
MCP's `delete_group` description said "A grant confined to some domains deletes
only the groups it created", the same misreading; it now says a token deletes
only the groups it created with set_group, whatever domains its grant reaches,
and the operator deletes any group from the Groups page.

The brief said "the Users page"; group deletion is on the manager's Groups page
(`starter/manager/groups.md`, SM1387), so the words name that page.

# Tests

t/integration/368-a-tokens-group-refusal-says-what-it-is.t: a token with no
domain scope, over the control API and over MCP, is refused group-delete and
group-set (delete_group, set_group) on a group it did not create, forbidden,
with the new words and without "domain-confined caller"; it still makes and
deletes its own group, and the other is still there; `delete_group`'s listed
description says the same. With the change reverted subtests 1, 2 and 4 fail.
