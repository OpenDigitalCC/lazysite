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
    local %main::RENDER_QUERY = ( c => 'a" onfocus="alert(1)' );
    my $meta = { form => "t", query_params => ['c'] };
    my $html = main::_render_form( "code | C | prefill:c\n", $meta );
    # The payload's own characters survive INSIDE the value - that is what an
    # escape is - so the assertion is that no attribute called onfocus exists,
    # which needs a real quote after the `=` rather than an entity.
    unlike( $html, qr/onfocus="/, 'the quote does not close the attribute' );
    like( $html, qr/value="a&quot; onfocus=&quot;alert\(1\)"/,
        'it is escaped as the other attributes are' );

    my $lit = main::_render_form( "code | C | value:\"x&y\"\n", { form => "t" } );
    like( $lit, qr/value="x&amp;y"/, 'and an ampersand in a literal is escaped too' );
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

done_testing();
