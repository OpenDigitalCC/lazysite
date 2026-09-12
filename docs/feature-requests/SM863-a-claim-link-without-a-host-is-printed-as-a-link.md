---
id: SM863
title: "SM863: a claim link with no host is printed under the words 'send this link', and two different causes produce the same unusable output"
subtitle: "`_claim_url` accepts the site base only if it matches `^\\w+://[^/\\s]+`, and falls back to a bare path otherwise. On the CLI that happens two ways - no `site_url` at all, and a `site_url` of `https://${SERVER_NAME}`, which collapses to `https://` because there is no SERVER_NAME in a command-line environment. Both print `/claim?u=...` beneath a sentence telling the operator to send it to someone."
brand: plain
standard-margins: true
status: partial
status-note: "SHIPPED 2026-09-12 for 0.13.15, in part. DONE: `_claim_link_lines` names a path as a path and says which of the two causes applies (no site_url, or one that resolves only under the web server), every printer uses it - setup-sysop, claim-create and account-approve's CLI, the last of which was interpolating a now-absent `url` - and on the API `url` is absolute or absent while `path` always carries the relative form. The 'Manager account created' wording is fixed in the same block: it now names the account and the group. t/tools/74 covers all three site_url states plus the API contract. NOT DONE: offering a known alias host from the domains store as a labelled suggestion. The primary host is recorded as the literal '(default)' so there is no canonical name to read, and an alias is a real hostname but not necessarily the right one - so it needs a decision about whether a suggestion the operator must confirm is better than none, and that was not worth taking in a release cut to a deadline."
raised: 2026-09-12
raised-by: release manager (running setup-sysop)
area: auth
---

# What was reported

> "small issue with setup-sysop: `Send this single-use self-service link (expires
> in 24h) to 'sjm' to set their own password: /claim?u=<name etc>` - it doesn't
> show the full path / host"

# Reproduced, in the three states `site_url` can be in

`tmp/probe-claim-url.sh`, run against a fresh docroot for each:

```
no site_url at all
  Send this single-use self-service link (expires in 24h) to 'sjm' ...
    /claim?u=sjm&c=lzc_b03a4dcd...

site_url: https://${SERVER_NAME}
  Send this single-use self-service link (expires in 24h) to 'sjm' ...
    /claim?u=sjm&c=lzc_c70667de...

site_url: https://example.test
  Send this single-use self-service link (expires in 24h) to 'sjm' ...
    https://example.test/claim?u=sjm&c=lzc_49693cfa...
```

The third case is the discriminating measure: the mechanism works. What fails is
resolving the host, and the output does not distinguish "resolved" from "could
not resolve".

# Why it happens, and why the second case is the one that bites

`_claim_url` (tools/lazysite-users.pl:1163):

```perl
my $url  = _site_base_url('');
my $base = ( $url =~ m{^\w+://[^/\s]+} ) ? $url : '';
return "$base/claim?u=" . _urlenc($user) . '&c=' . _urlenc($claim);
```

and `_site_base_url` substitutes `${SERVER_NAME}` from `%ENV`:

```perl
$base =~ s/\$\{SERVER_NAME\}/$ENV{SERVER_NAME} || $ENV{HTTP_HOST} || $host_fallback/ge;
```

`_claim_url` passes `$host_fallback` as the **empty string**. So a `site_url` of
`https://${SERVER_NAME}` - the form that is correct for a site served on more
than one host, and which works perfectly under the CGI - becomes `https://` on
the command line, fails the absolute test, and takes the same fallback as a site
with no `site_url` at all.

**The fallback itself is right.** Guessing a hostname and printing it as part of
a credential-bearing URL would be worse: the operator would send a link to the
wrong host and not know. The comment at :1159 says as much - "else a relative
path the sysop prefixes with the site's address".

**What is wrong is that only the source says so.** The operator is told "send
this link" and handed something that is not one, with no statement that the host
is missing, which of the two reasons applies, or what to set. The
[[feedback_absence_is_a_finding]] shape, in an output an operator acts on
immediately.

# The same print block says "Manager account created", and it was read as a name

Reported immediately after, by the same operator: *"i ran setup-sysop with a
specific user, why did manager also get created?"*

**Nothing was.** Measured in `tmp/probe-setup-sysop-creates.sh` -
`setup-sysop --user sjm` in a fresh docroot creates exactly one account:

```
=== accounts (list)
    sjm
```

No `manager` account, and no `manager` group either - the seeded groups are
`sysops`, `site-admins`, `content-editors`, the `cap-*` and `ch-*` backends and
so on, and the one this run used is **`sysops`**.

What the operator read is the first line of the block:

```
Manager account created (no password set).
```

That is a sentence about a ROLE and parses as a NAME. Three things are wrong
with it at once, and they compound:

- It does not name the account it just created. The name appears two lines
  later, as `Username: sjm`, after the link - so the line that reports the
  outcome is the one line without the subject in it.
- "Manager" is **SM659 residue**. The command was `setup-manager` and is now
  `setup-sysop` precisely because a role account called `manager` was the wrong
  default; the message still uses the old vocabulary for the thing SM659
  renamed.
- The group it actually used is `sysops`, so the noun in the message does not
  match the group in the message either.

It should name what happened: the account, the group, and that no password was
set. `Sysop account 'sjm' created in group 'sysops' - no password set.`

Filed together with the host problem because it is the same six lines of output
and one change fixes both; they are separate faults with one cause, which is
that this block reports its own work loosely.

# Where else this surfaces

- `setup-sysop` and the other setup verb that print a claim link.
- `claim-create` ("Generate setup link" / "Reset credential").
- **[[SM858]]'s `account-approve` returns `url => _claim_url(...)`** - so the API
  hands back a key *named* `url` whose value may be a path. A caller cannot tell
  without pattern-matching it, and the expo's self-service flow is exactly this
  call. Read from the source, not yet measured on a live instance; 1314E-05 asks
  the site agent to report what they actually receive.

# The fix

Not to guess a host. Three parts:

1. **Say which it is.** When the base could not be resolved, the CLI prints the
   path as a path and says what to prefix it with, rather than under the word
   "link" - and names the cause, because "no `site_url` is set" and "`site_url`
   resolves only under the web server" want different actions from the operator.
2. **Offer what is known, marked as a suggestion.** An alias host from the
   domains store is a real hostname the operator can recognise; the primary is
   recorded as the literal `(default)`, so there is no canonical host to read -
   which is why this cannot simply be derived. A suggestion the operator confirms
   is honest; a guess printed as the answer is not.
3. **On the API, do not put a path in a key called `url`.** Return the absolute
   URL in `url` only when it is absolute, and the relative form in its own key,
   so a caller can tell without parsing. That is an interface change and belongs
   to the release manager to time.

# Related

[[SM858]] (whose reply carries this value, and whose expo flow depends on it),
SM673 (the claim flow), [[feedback_absence_is_a_finding]],
[[feedback_a_boolean_has_four_states]] (resolved / not resolved / not configured
- three states sharing one output).
