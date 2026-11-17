#!/usr/bin/perl
# SM1469 R1: `type:hidden` renders a hidden input carrying its value:/prefill:
# value, with no label and no visible wrapper. Fails against the old code, which
# ignored the unknown token and rendered a visible text field.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(load_processor site_tempdir);

load_processor( site_tempdir() );

subtest 'a literal value' => sub {
    my $html = main::_render_form(
        "campaign | Campaign | type:hidden value:\"spring\"\nname | Name | required\n", { form => 't' } );
    like( $html, qr/<input type="hidden" name="campaign" id="campaign" value="spring">/,
        'a hidden input with the value' );
    unlike( $html, qr/<label for="campaign"/, 'no label for it' );
    unlike( $html, qr/type="text" name="campaign"/, 'no visible field for it' );
    like( $html, qr/<input type="text" name="name"/, 'the other field is untouched' );
};

subtest 'from the URL, through the allowlist' => sub {
    no warnings "once";
    local %main::RENDER_QUERY = ( ref => 'R-77' );
    my $html = main::_render_form( "ref | Ref | type:hidden prefill:ref\n",
        { form => 't', query_params => ['ref'] } );
    like( $html, qr/<input type="hidden" name="ref" id="ref" value="R-77">/, 'prefill fills it' );
};

subtest 'the value is escaped' => sub {
    my $html = main::_render_form( "x | X | type:hidden value:\"a&quot; onfocus=&quot;1\"\n", { form => 't' } );
    my ($f) = $html =~ /(<input type="hidden" name="x"[^>]*>)/;
    ok( $f, 'rendered' );
    unlike( $f, qr/value="[^"]*"[^>]*onfocus=/, 'the value cannot leave its attribute' );
};

done_testing;
