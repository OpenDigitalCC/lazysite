---
id: SM1277
title: "SM1277: the page shows an Odoo write whose answer never came"
subtitle: "Ruling 10b: the visitor sees the unknown changes and can check again. The browser helper draws what a write left unknown into the page's [data-ls-odoo-unknown], as text, with Check again, and It was made / It was not made only for a person the answer says may say."
brand: plain
standard-margins: true
status: shipped
raised: 2026-10-23
raised-by: "the release manager, ruling 10b (2026-10-23)"
area: odoo
status-note: "SHIPPED (0.16.3) on n733: LazysiteOdoo.resume and showUnknown in starter/assets/lazysite-odoo.js; write() and confirm() draw an unknown answer into [data-ls-odoo-unknown]. t/unit/odoo/111 (t/lib/odoo-unknown-harness.js)."
---

# What was asked

Ruling 10b (2026-10-23): resuming is offered on the page, where the visitor sees the
unknown changes and can check again. The brief: the binding's page script
(`starter/assets/lazysite-odoo.js`) shows the unknown changes with "check again", and
shows the assume choices only to someone who may use them.

# What shipped

- **`LazysiteOdoo.resume(run, opts)`**:
  - `POST {run, resume: true}` with the token, through the helper's one-retry rules
    (a stale token, a sign-in);
  - `opts.assumeDone` / `opts.assumeNotDone` (a key or a list) become `assume_done` /
    `assume_not_done`.
- **`LazysiteOdoo.showUnknown(node, answer, opts)`** draws what an answer left unknown.
  An apply's answer gives the changes whose outcome is `unknown`. A resume refused
  `unknown-outcome` gives its `changes`.
  - Everything is drawn by `textContent`, so a key that is markup shows as its
    characters.
  - "It is not known whether Odoo made this change", then each change (key, action,
    model) and **Check again**.
  - **It was made** / **It was not made** for each change, only when the answer says
    `may_assume`. The server decides who may say (SM1275), and the page only follows
    what it was told.
  - Each button resumes the run and draws the next answer in the same place: settled,
    refused again with the same choices, or a new run left unknown.
  - `data-ls-odoo-state` is `unknown`, `settled` or `stale`, and `opts.onAnswer` is
    told each answer.
- **`write()` and `confirm()`** draw an answer that names a run left unknown into the
  page's `[data-ls-odoo-unknown]` element, when the page has one. A page without one
  gets the answer as before.
  - The element's attribute is skipped by `params()`.
  - `\bdata-ls-odoo\b` already brings the helper onto a page that carries it.
- **Docs**: the helper's header, its markup contract, and `starter/docs/odoo.md`, *The
  browser helper*.

# Tests

t/unit/odoo/111, under node with a stand-in DOM (`t/lib/odoo-unknown-harness.js`):

- `resume()` sends the run, `resume: true`, the token and each assume list;
- a write left unknown is drawn into the slot:
  - saying it is not known, naming only the unknown change;
  - for its maker: It was made, It was not made, Check again;
- for one who may not say: Check again alone, which sends no assume list, and a
  refusal `unknown-outcome` is drawn again without the choices;
- It was made sends `assume_done` and draws the settled answer;
- It was not made sends `assume_not_done`, and a new run left unknown is the one
  checked next;
- a key that is markup makes no element;
- a page with no slot is answered as before.

With lazysite-odoo.js at SM1278, the harness fails at once: `resume is not a function`.
