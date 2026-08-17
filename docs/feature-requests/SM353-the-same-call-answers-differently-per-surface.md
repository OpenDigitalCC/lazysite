---
title: "SM353 - The same call answers differently depending on the surface"
subtitle: "`ok` is the number 1 on the control API and the boolean true on MCP. `describe-capabilities` returns a `groups` key on one surface and not the other. The gating redirect declares `content-type: text/x-perl`. Three small things, one shape."
brand: plain
status: filed
---

# SM353 - three inconsistencies, none of them large

Filed together because they are the same class and none justifies its own
number. Each is cheap to fix and each costs a caller more than its size
suggests.

## 1. `ok` has a different type per surface

```
control API   describe-capabilities  ->  "ok": 1
MCP           describe_capabilities  ->  "ok": true
```

Same field, same call, same account, same instance.

A caller written against one surface and pointed at the other behaves
differently: `if (res.ok === true)` succeeds on MCP and fails on the API,
while `if (res.ok)` passes on both. The failure is silent, it is
type-dependent rather than value-dependent, and it appears only when
someone ports code between channels - which is precisely what the parity
work invites them to do.

The register already records this shape: [[SM268]]'s recurring theme was
*"two surfaces disagreeing about one question"*, and [[SM291]] was a
malformed boolean that cleared a flag while returning `ok:1`. Booleans
crossing this boundary have caused real defects.

Pick one. `true` is the better choice - it is what JSON Schema declares
and what MCP already emits - but consistency matters more than which.

## 2. `describe-capabilities` returns different keys per surface

```
API holds:  account, capabilities, groups, scope, why
MCP holds:  account, capabilities,         scope, why
```

The `capabilities` maps are identical - checked key by key, no
differences in names or values. Only `groups` differs, present on the API
and absent on MCP.

This is the document that tells a caller what it may do. An MCP caller
cannot see its own group membership; an API caller can. Whichever is
correct, both should say the same thing, because a caller reasoning about
its own grant should not get a different answer depending on how it asked.

## 3. The gating redirect declares a Perl content type

```
HTTP/2 302
content-type: text/x-perl
cache-control: no-store
location: /login?next=%2Fzz-surv%2Fprobe.png
```

The redirect is right. `no-store` is right. `next=` preserving the path is
right. The content type is the CGI's own leaking into the response.

Harmless today because the body is empty and clients follow the
`Location`. Worth fixing because it is wrong on every gated request on
every site, it is the kind of thing a scanner or a strict client will flag,
and it advertises the implementation language on a security boundary for
no reason.

## Verification

- `ok` has the same JSON type on every surface, for every action and tool.
- A lint asserts it, since this will drift again otherwise - the register
  records three defects from hand-maintained lists and this is the same
  category.
- `describe-capabilities` and `describe_capabilities` return the same key
  set.
- A 302 to the login page carries no `text/x-perl` content type.

## Related

[[SM268]] (two surfaces disagreeing about one question, as a recurring
class), [[SM291]] (a boolean crossing a surface boundary and clearing a
flag), [[SM350]] (the API's missing action reference, which is what makes
this kind of difference hard to notice), and
`inbox/four-surface-validation-0.10.12-2026-08-17.md`.
