#!/usr/bin/perl
# SM856: a form field can carry a value, so a code the URL holds is not retyped.
#
# `query_params:` puts a URL value on the page, escaped, and a page can print it,
# branch on it or head a section with it. The form renderer emitted `type`,
# `name`/`id`, `maxlength`, `min`/`max`, `pattern`, `placeholder` and `required`
# - and no `value`, with no rule that would set one. So the one place the value
# was needed was the one place it could not go, and an applicant holding a card
# retyped eight characters the URL already carried.
#
# TWO RULES, and the second is the one that matters:
#
#   value:"ODX-0000"   a literal default
#   prefill:c          the value of query parameter `c`, REFUSED unless the page
#                      declares `c` in query_params:
#
# The allowlist is the gate: prefill reaches nothing query_params has not already
# admitted. What must NOT follow is a db: binding reading query.* - a visitor
# steering a query against the site's tables - which is refused today and stays
# refused; this rule exists so that nobody needs it.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor site_tempdir setup_test_site run_processor);

load_processor( site_tempdir() );

subtest 'a literal default' => sub {
    my $html = main::_render_form( "code | Your code | required max:12 value:\"ODX-0000\"\n", { form => "t" } );
    like( $html, qr/<input type="text" name="code"[^>]*\svalue="ODX-0000"/,
        'value: puts the literal in the field' );
    like( $html, qr/maxlength="12"/, 'and the other rules still apply' );
    like( $html, qr/\srequired/,     'including required' );
};

subtest 'from the URL, through the allowlist' => sub {
    local %main::RENDER_QUERY = ( c => 'ODX-4417' );
    my $meta = { form => "t", query_params => ['c'] };
    my $html = main::_render_form( "code | Your code | required max:12 prefill:c\n", $meta );
    like( $html, qr/value="ODX-4417"/, 'the declared parameter fills the field' );
};

subtest 'an undeclared parameter is an author error, not an empty field' => sub {
    local %main::RENDER_QUERY = ( c => 'ODX-4417' );
    my $meta = { form => "t", query_params => ['other'] };
    my $html = main::_render_form( "code | Your code | prefill:c\n", $meta );
    unlike( $html, qr/value="ODX-4417"/,
        'a parameter the page never declared does not reach the field' )
        or diag( 'prefill: must reach nothing query_params: has not admitted - '
            . 'the allowlist is the gate, and this is the whole security case.' );
    # The field itself, not the form: _form, _page, _ts, _tk and the honeypot
    # all carry a value attribute of their own and always have.
    my ($field) = $html =~ /(<input[^>]*name="code"[^>]*>)/;
    ok( $field, 'the field rendered' );
    unlike( $field, qr/\svalue=/, 'and no empty value is emitted in its place' );
};

subtest 'the literal is the fallback, the URL wins when it is there' => sub {
    my $meta = { form => "t", query_params => ['c'] };
    {
        local %main::RENDER_QUERY = ();
        my $html = main::_render_form( "code | C | value:\"NONE\" prefill:c\n", $meta );
        like( $html, qr/value="NONE"/, 'no parameter in this request: the literal stands' );
    }
    {
        local %main::RENDER_QUERY = ( c => 'FROM-URL' );
        my $html = main::_render_form( "code | C | value:\"NONE\" prefill:c\n", $meta );
        like( $html, qr/value="FROM-URL"/, 'a parameter present: it wins' );
    }
};

subtest 'a hostile value cannot leave the attribute' => sub {
    # SM868: DRIVEN THROUGH THE REAL QUERY PATH, not a hand-set hash.
    #
    # This used to do `local %RENDER_QUERY = ( c => 'a" onfocus="alert(1)' )` -
    # a RAW payload in a hash that production only ever fills from
    # parse_query_string, which escapes. So the fixture disagreed with the
    # reader, and that disagreement is what hid the double-escape: the sink was
    # escaping a value this test had (uniquely) supplied unescaped.
    my $d = site_tempdir();
    open my $fh, '>', "$d/hostile.md" or die $!;
    print {$fh} <<'PAGE';
---
title: Apply
query_params:
  - c
form: apply
---

:::form
code | C | prefill:c
:::
PAGE
    close $fh;

    my $out = run_processor( $d, '/hostile',
        QUERY_STRING => 'c=a%22%20onfocus%3D%22alert(1)' );

    # The payload's own characters survive INSIDE the value - that is what an
    # escape is - so the assertion is that no attribute called onfocus exists,
    # which needs a real quote after the `=` rather than an entity.
    unlike( $out, qr/onfocus="/, 'the quote does not close the attribute' );
    like( $out, qr/value="a&quot; onfocus=&quot;alert\(1\)"/,
        'and it is escaped exactly once' );
    unlike( $out, qr/&amp;quot;/, 'not twice' );

    my $lit = main::_render_form( "code | C | value:\"x&y\"\n", { form => "t" } );
    like( $lit, qr/value="x&amp;y"/, 'and an ampersand in a literal is escaped too' );
};

# THE INVARIANT THE SINK NOW RELIES ON, pinned so it cannot quietly go.
#
# The sink escapes a `value:` literal and does NOT escape a query value,
# because parse_query_string already did. That is correct and it is also a
# dependency at a distance: if parse_query_string ever stopped escaping, the
# sink would emit a visitor's raw value into an attribute. Nothing in the sink
# could detect that. So it is asserted here, next to the code that depends on
# it, rather than trusted.
subtest 'parse_query_string escapes, which is why the sink does not' => sub {
    my $q = main::parse_query_string('c=a%22b%3Cc%26d');
    is( $q->{c}, 'a&quot;b&lt;c&amp;d',
        'a parsed query value arrives HTML-escaped, covering both the attribute '
            . 'and the textarea sink' )
        or diag( 'If this changed, the prefill sink must escape again - see the '
            . '$from_query branch in _render_form.' );
};

subtest 'the value reaches the browser through a real render' => sub {
    my $d = site_tempdir();
    setup_test_site($d);
    open my $fh, '>', "$d/apply.md" or die $!;
    print {$fh} <<'PAGE';
---
title: Apply
form: apply
query_params:
  - c
---

:::form
code | Your code | required max:12 prefill:c
name | Your name |
:::
PAGE
    close $fh;

    my $out = run_processor( $d, '/apply', QUERY_STRING => 'c=ODX-9001' );
    like( $out, qr/value="ODX-9001"/, 'the rendered page carries the code' )
        or diag( 'This is the whole point: the applicant scans the QR and the '
            . 'field is already filled.' );
    like( $out, qr/name="code"/, 'in the field it belongs to' );
};

# --- SM868: escaped ONCE, whichever source the value came from ---------------
#
# Found on edge by the site agent, in this feature, the day it shipped:
#
#   visitor arrives at   /apply?code=Smith %26 Sons
#   in the served HTML   value="Smith &amp;amp; Sons"
#   browser displays     Smith &amp; Sons
#
# parse_query_string escapes &<>"' as it STORES a parameter - the same hash is
# the `query.*`/`params.*` stash, so it has to - and this sink escaped it again.
#
# WHY MY ORIGINAL TESTS ABOVE PASS ANYWAY, which is the part worth keeping:
# every one of them uses a value like ODX-4417, and alphanumerics are a FIXED
# POINT of HTML escaping. A test value that cannot change under the transform
# cannot detect a doubled transform. The security assertions could not see it
# either - over-escaping is safe, so "the payload did not execute" holds in
# both the correct and the broken build.
subtest 'a value with a character that needs escaping survives intact' => sub {
    my $d = site_tempdir();
    my $fh;
    open $fh, '>', "$d/apply.md" or die $!;
    print {$fh} <<'PAGE';
---
title: Apply
query_params:
  - code
form: apply
---

:::form
code | Your code | prefill:code
:::
PAGE
    close $fh;

    # THE REAL PATH, not a hand-set hash: %26 is an ampersand, and it must
    # travel through parse_query_string exactly as a visitor's link does.
    my $out = run_processor( $d, '/apply', QUERY_STRING => 'code=Smith%20%26%20Sons' );

    like( $out, qr/value="Smith &amp; Sons"/,
        'the attribute carries the value escaped ONCE, so a browser shows "Smith & Sons"' )
        or diag( 'Escaped twice: parse_query_string escapes on the way in, for '
            . 'the TT stash, and this sink escaped it again. Nothing is exposed '
            . '- over-escaping is safe - but every prefilled name, company or '
            . 'address containing & < > " or \' displays as entity text, and '
            . '"Smith & Sons" is not an exotic input for the case this was built '
            . 'for.' );
    unlike( $out, qr/&amp;amp;/, 'and is not double-escaped' );
};

subtest 'a literal, which IS raw, is still escaped' => sub {
    # The discriminating half. The sink now has two sources in different
    # states, so a fix that simply stopped escaping would open the other one.
    my $html = main::_render_form( qq(co | Company | value:"Smith & Sons"\n), { form => 't' } );
    like( $html, qr/value="Smith &amp; Sons"/,
        'a value: literal comes from the form definition raw, and is escaped here' )
        or diag( 'If this fails, the fix removed escaping from the source that '
            . 'genuinely needs it rather than from the one that did not.' );
    unlike( $html, qr/&amp;amp;/, 'once, not twice' );
};

subtest 'a textarea follows the same rule' => sub {
    local %main::RENDER_QUERY = ( note => 'Jones &amp; Co' );    # as stored
    my $meta = { form => 't', query_params => ['note'] };
    my $html = main::_render_form( "note | Note | textarea prefill:note\n", $meta );
    like( $html, qr/>Jones &amp; Co</, 'content escaped once' );
    unlike( $html, qr/&amp;amp;/, 'not twice' );
};

done_testing();
