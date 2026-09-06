---
id: SM762
title: "SM762: email bodies as markdown templates with the submission's fields in scope"
subtitle: "Filed from the sites agent's request of 2026-09-06; the operator asked for it to be put to dev. Verified against the engine: the smtp handler's body is generated and fixed - three config fields, one of them a subject prefix, and no template anywhere in the mail path."
brand: plain
standard-margins: true
status: candidate
status-note: "candidate 2026-09-06, awaiting the release manager's word. Not built. The request is archived at inbox/archive/2026-09-06-request-markdown-email-templates.md; this filing adds what the source says and the decisions the build would need."
---

# The need

The wording of a message to a customer is content, owned by whoever edits the
site's content. Today every notification from every form on every site is the
same generated shape, differing by a subject prefix, and no site can say
"thank you for asking about X - here is what happens next".

# What the source says (2026-09-06, main at SM760)

`plugins/form-smtp.pl` builds the body from the non-internal fields as
`label: value` lines (`_build_body`, ~line 259), wraps uploads as
multipart/mixed, and sends via sendmail or SMTP. Its config is `from`, `to`,
`subject_prefix`, the transport settings, and `attach`. There is no template,
no interpolation, no per-form wording. The agent's reading is correct.

The engine renders markdown in the page pipeline and has a variable
mechanism there; neither reaches the mail path.

# The shape (from the request; agreed)

A handler names a template; the template is markdown; the submission's
fields are in scope; the engine renders it to the body at send time, text
part and HTML part from one source.

# Decisions the build needs (the release manager's)

| # | Question | The request's lean | Note from the source |
| --- | --- | --- | --- |
| 1 | Where templates live | engine-owned, `lazysite/forms/templates/`, not the content tree | the pandoc plugin's `brand_dir` reasoning applies: a template in the docroot answers an anonymous request. Against: authors reach content, not `lazysite/`. A middle: templates under `lazysite/forms/templates/`, editable from the Forms manager page and over MCP by `manage_forms`, never served |
| 2 | Escaping | every value inserted as text, never markup; HTML part escaped | non-negotiable; and no value may reach a header |
| 3 | The subject | template it too, stricter | strip CR/LF and control characters; refuse the send if a value would put a newline in a header |
| 4 | Missing variables | refuse to send | for a message that must not go out malformed; a form that gained a field renders empty for that field only |
| 5 | Scope | the submission's fields; site name and a link back; nothing about the visitor beyond what they typed | agreed |

# Relationship

SM761 (confirmed opt-in) is the first message that needs a body worth
sending; each stands alone. SM184 (publish by email) is a different thing -
inbound mail, not outbound wording.
