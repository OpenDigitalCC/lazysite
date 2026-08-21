---
title: "SM445: an expired session makes the button do nothing at all"
subtitle: "Not an error, not a message, not a redirect - the click is simply inert. The operator learns their session expired by refreshing on a hunch, and until then it reads as the feature being broken."
brand: plain
standard-margins: true
status: candidate
status-note: "REPORTED 2026-08-21 by the release manager, from configuring a domain on a live instance: 'the submit button did nothing. i refreshed and discovered session expired. i had no information to say that, it just felt like it has failed.' CONFIRMED IN THE SOURCE, and the mechanism is worse than a missing message. Every manager page posts through a helper of this shape: fetch(...).then(function (r) { return r.json(); }) - with NO response-status check and NO .catch(). When the session has expired the auth wrapper answers 401, and the body is not JSON, so r.json() REJECTS. The rejection is unhandled, the .then() never runs, and neither the success branch nor the error branch fires. showStatus is never called with anything. THAT IS WHY IT IS SILENT RATHER THAN WRONG: the code has an error branch and it is unreachable on this path, because the failure happens before the branch is chosen. Nothing distinguishes it from a dead button. FIVE PAGES share the shape and NOT ONE manager page handles 401 anywhere - grep finds no reference to it in starter/manager/. So this is every form on every page, not a gap on the Domains sheet. THE OPERATOR'S READING WAS REASONABLE AND WRONG, which is the cost: a button that does nothing means the feature is broken, so the next step is to report a defect or retry the work, not to refresh. The data was still in the form and would have survived a refresh; they could not know that. REMEDY, in order of value: (1) check response.ok before parsing and, on 401, say the session has expired and offer a refresh or sign-in - this alone fixes the report; (2) add a .catch() to the shared helper so a non-JSON or network failure says SOMETHING rather than nothing; (3) consider preserving the form contents across the re-authentication, since losing a filled-in domain sheet to a timeout is its own small injury. Items 1 and 2 are a few lines in one helper per page, or one shared helper. SAME CLASS AS THE WEEK'S OTHERS: SM436's check named DNS for a fault in the conf, SM442's control reported roots it could not distinguish from none, SM444's gate blamed coverage for a run that never measured it. This one does not misreport - it declines to report at all, which is the same defect with the volume at zero."
---

# What happens

```datatable
columns: Step | What the operator sees
widths: 6cm | X
bold: 1
tone: medium
---
Fill in the domain sheet, click submit | **nothing**
Look for an error | there is none
Look for a redirect to sign-in | there is none
Refresh, on a hunch | *session expired* - and the form is gone
```

::: widebox
The page has an error branch for this form and it cannot run. `r.json()`
rejects on the 401's non-JSON body, the rejection is unhandled, and the
`.then()` never executes - so neither the success nor the failure branch is
reached. **The failure happens before the branch is chosen.**
:::

# The shape, unchanged across five pages

```javascript
function post(action, obj) {
  return fetch(API + '?action=' + action, {
    method: 'POST', credentials: 'same-origin',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(obj || {})
  }).then(function (r) { return r.json(); });     // no r.ok check, no .catch
}
```

No manager page references `401` at all. This is every form on every page.

# Why the operator's reading was reasonable

A button that does nothing means the feature is broken. So the next move is to
report a defect, or to redo the work somewhere else - not to refresh. The form
contents were still there and would have survived, and there was no way to know
that.

Silence is the worst of the available failures here: an error says *try again*,
a redirect says *sign in*, and nothing at all says *this does not work*.

# Remedy

1. **Check `response.ok` before parsing.** On 401, say the session has expired
   and offer a refresh or sign-in. This alone answers the report.
2. **Give the shared helper a `.catch()`**, so a non-JSON body or a dropped
   connection says something rather than nothing.
3. **Consider keeping the form contents across re-authentication.** Losing a
   filled-in domain sheet to a timeout is a small injury of its own, and the
   timeout is not the operator's doing.

One and two are a few lines each, in one helper per page - or one helper
shared by all five.

# The class

```datatable
columns: Filing | The control said
widths: 4cm | X
bold: 1
tone: medium
---
SM436 | "add the DNS record" - for a fault in the conf
SM442 | roots it could not distinguish from none
SM444 | "coverage below the floor" - for a run that never measured it
SM445 | **nothing**
```

The first three misreport. This one declines to report, which is the same
defect with the volume at zero - and it is the one the operator noticed
fastest, because a wrong message can be argued with and silence cannot.
