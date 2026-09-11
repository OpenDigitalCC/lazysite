---
title: Form helpers
subtitle: Write custom dispatch targets for lazysite forms.
register:
  - sitemap.xml
---

## Overview

The built-in handler types (`smtp`, `file`, `table`, `connector`) cover most
needs. For anything more custom, send the form through a
[connector](/docs/connectors) to a URL you control - a small CGI script that
receives JSON and performs your action.

This page documents the JSON contract so you can write those scripts.

## Helper contract

A helper must:

1. Read JSON from STDIN
2. Perform its action
3. Return JSON on STDOUT with `Status:` and `Content-Type:` headers

### Input

JSON object with field names as keys. Internal fields (`_form`, `_ts`,
`_tk`, `_hp`) are excluded - only user-submitted fields are sent.

```json
{
  "name": "John Smith",
  "email": "john@example.com",
  "message": "Hello there"
}
```

### Output on success

```
Status: 200 OK
Content-Type: application/json

{"ok":1}
```

### Output on failure

```
Status: 500 Internal Server Error
Content-Type: application/json

{"ok":0,"error":"Description of error"}
```

## Minimal Perl skeleton

```perl
#!/usr/bin/perl
use strict;
use warnings;
use JSON::PP qw(encode_json decode_json);

eval {
    my $json = do { local $/; <STDIN> };
    my $form = decode_json($json);

    # --- Your logic here ---
    # $form->{name}, $form->{email}, etc.

    print "Status: 200 OK\r\n";
    print "Content-Type: application/json\r\n\r\n";
    print encode_json({ ok => 1 });
};
if ($@) {
    warn "my-helper: $@";
    print "Status: 500 Internal Server Error\r\n";
    print "Content-Type: application/json\r\n\r\n";
    print encode_json({ ok => 0, error => "$@" });
}
```

## Registering as a handler

Make a connector for the helper's URL on the Connectors page - a URL on its
own is enough, and `http://` is accepted for a service on this host - and
permit **public** invocation, since a visitor's submission is what triggers
it:

```json
{ "url": "http://localhost/cgi-bin/my-helper.pl", "modes": { "public": 1 } }
```

Then a `connector` handler naming it, on the Handlers page (or with
`save_handler` / `handler-save`), which lands in `lazysite/forms/handlers.conf`:

```yaml
handlers:
  - id: my-helper
    type: connector
    name: My custom helper
    enabled: true
    connector: my-helper
```

And bind the form to the handler, which writes the form's `.conf` file:

```yaml
targets:
  - handler: my-helper
```

The connector's `format: json` (the default) sends the contract documented on
this page; `format: slack` sends a Slack-compatible `{"text": "..."}` body.

## Testing with curl

```bash
echo '{"name":"Test","email":"test@test.com"}' | \
  DOCUMENT_ROOT=/path/to/public_html \
  perl cgi-bin/my-helper.pl
```

## Examples

### Write to a log file

```perl
open(my $fh, '>>', '/var/log/form-submissions.log');
print $fh encode_json($form) . "\n";
close($fh);
```

### POST to a webhook

```perl
use LWP::UserAgent;
my $ua = LWP::UserAgent->new(timeout => 10);
$ua->post('https://hooks.example.com/endpoint',
    Content_Type => 'application/json',
    Content      => encode_json($form));
```

## Notes

- Helpers run as the web server user - ensure file permissions match
- A helper that answers anything but 2xx is a failed call: it is recorded
  in the connector's call record and the audit trail, and the other handlers
  on the form still run
- A redirect is not followed - the connector records it as refused, because
  its credential would travel with it
- Multiple helpers can be configured for the same form
- [Forms overview](/docs/forms) - full form setup guide
- [SMTP configuration](/docs/forms-smtp) - the built-in email helper
