---
title: Form helpers
subtitle: Write custom dispatch targets for lazysite forms.
register:
  - sitemap.xml
  - llms.txt
---

## Overview

Form helpers are CGI scripts that receive form data as JSON POST from
the form handler and perform an action (send email, write to database,
call an API). The form handler dispatches to helpers configured in the
form's `.conf` file.

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

## Registering as a target

Add the helper to the form's `.conf` file:

```yaml
targets:
  - type: smtp
    url: http://localhost/cgi-bin/lazysite-form-smtp.pl
  - type: api
    url: http://localhost/cgi-bin/my-helper.pl
    format: json
```

Use `type: api` with `format: json` for custom helpers. The handler
POSTs the JSON to the URL.

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
- The handler does not check the helper's response - failures are
  logged but do not prevent other targets from dispatching
- Multiple helpers can be configured for the same form
- [Forms overview](/docs/forms) - full form setup guide
- [SMTP configuration](/docs/forms-smtp) - the built-in email helper
