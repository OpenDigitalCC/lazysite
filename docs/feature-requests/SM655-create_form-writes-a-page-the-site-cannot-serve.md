---
title: "SM655: `create_form` saves the caller's path verbatim, so the idiomatic call writes an extensionless file and the form ships dead"
subtitle: "Site agent, 2026-08-26: three separate checks report success and only fetching the URL reveals the 404 - the sanctioned tool failing the way the hand-written HTML it exists to prevent fails"
brand: plain
standard-margins: true
status: candidate
status-note: "FILED FROM AN INBOX BRIEF (archived at inbox/archive/), reported by the site agent 2026-08-26 and RE-VERIFIED ON MAIN 2026-08-27: _create_form still calls action_save( $a->{path}, ... ) with the caller's path untouched, while its neighbour _create_page normalises and appends the extension (_norm_slug with md => 1). ONE LINE OF ASYMMETRY BETWEEN TWO ADJACENT SUBS. `create_form {\"path\": \"/zz-r12-formflow\"}` writes a file with NO EXTENSION: list_files shows ext:\"\", page_status reports exists:true, read_file returns valid page source with front matter and the :::form block - and a public GET returns 404. delete_page cannot remove it ('File not found'); delete_file can. WHY THIS IS WORSE THAN A PATH-HANDLING NIT: extensionless page paths are the idiom everywhere else on this surface (read_page \"/about\", page_status \"/about\"), and create_form's own schema says 'Page to add the form to (created if absent)' - which reads as a page path, not a filename. So the idiomatic call silently produces a dead form and THREE checks report success. THE IRONY IS EXACT: create_form's description exists to stop agents hand-writing <form> HTML because 'it has no delivery handler and ships dead'. Called the idiomatic way, the sanctioned tool ships dead too - different cause, same result. Passing an explicit .md would presumably work; that is a workaround, not a defence, since nothing in the schema, the description or any reply says the extension is required. NOTE: the brief carried a SECOND defect - bind_form creating a registration nothing could remove - which is SM632 and is already closed; only the create_form half remains, and it is the whole of this filing."
---

# What the idiomatic call produces

`create_form {"path": "/zz-r12-formflow", "name": "zz_r12_formflow"}` returns
`ok:true` with a `next:` instruction.

| Check | Result |
|---|---|
| `list_files` | `{"name":"zz-r12-formflow","ext":"","size":139}` - no `.md` |
| `page_status` | `exists: true` |
| `read_file` | valid page source - front matter with `form:`, plus the `:::form` block |
| **public GET** `/zz-r12-formflow` | **404** |
| `delete_page` | *"File not found"* - cannot remove what `create_form` made |
| `delete_file` | succeeds, on the exact path |

Everything an agent would check to confirm success reports success. The only
signal is fetching the URL, which is the one step a tool that returned `ok:true`
does not suggest.

# The cause

    # _create_page   normalises, then saves with the extension
    $slug = _norm_slug( $slug, dots => 1, md => 1, trail => 1 );
    return action_save( "/$slug.md", $user, $fm . $body, undef );

    # _create_form   saves the caller's path verbatim
    my $save = action_save( $a->{path}, $user, $content, undef );

`_create_form` never calls `_norm_slug` and never appends `.md`. The two subs
are neighbours in the same file and disagree about what a page path is.

# Why the idiom matters

Every other tool on this surface takes an extensionless page path - `read_page
"/about"`, `page_status "/about"`. `create_form`'s own schema describes the
argument as *"Page to add the form to (created if absent)"*, which reads as a
page path.

So an agent following the surface's own conventions gets a dead page, and an
agent that happens to pass `.md` gets a working one, with nothing anywhere
explaining the difference. That is a trap rather than a limitation.

# The irony, which is also the argument for priority

`create_form` exists so agents stop hand-writing `<form>` HTML - because
hand-written HTML *"has no delivery handler and ships dead"*. The sanctioned
alternative, called the way the surface teaches, also ships dead. Different
cause, identical outcome, and the agent has done everything it was told.

# The fix

Normalise in `_create_form` exactly as `_create_page` does. One line, and the
two neighbours stop disagreeing.

Worth a test asserting that a form created at an extensionless path is
publicly fetchable - `ok:true`, `page_status` and `read_file` all passed here,
so the test has to be the public GET or it proves nothing.
