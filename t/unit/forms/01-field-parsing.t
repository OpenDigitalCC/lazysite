#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site);

# convert_fenced_form lives in lazysite-processor.pl; these tests pin the
# per-rule HTML output. The form-handler side (POST processing) is covered
# by integration/subprocess tests.

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);
load_processor($docroot);

my $meta = { form => 'test' };

# --- required rule ---
{
    my $out = main::convert_fenced_form(
        "::: form\nname | Name | required\nsubmit | Send\n:::\n", $meta);
    like( $out, qr/ required/, 'required attribute produced' );
}

# --- email rule ---
{
    my $out = main::convert_fenced_form(
        "::: form\nemail | Email | required email\nsubmit | Send\n:::\n", $meta);
    like( $out, qr/type="email"/, 'email type applied' );
}

# --- textarea rule ---
{
    my $out = main::convert_fenced_form(
        "::: form\nmsg | Message | textarea\nsubmit | Send\n:::\n", $meta);
    like( $out, qr/<textarea\b/, '<textarea> tag produced' );
}

# --- max rule ---
{
    my $out = main::convert_fenced_form(
        "::: form\nname | Name | max:100\nsubmit | Send\n:::\n", $meta);
    like( $out, qr/maxlength="100"/, 'maxlength attribute applied' );
}

# --- select rule ---
{
    my $out = main::convert_fenced_form(
        "::: form\ncolour | Colour | select:red,green,blue\nsubmit | Send\n:::\n",
        $meta);
    like( $out, qr/<select\b/,                    '<select> tag' );
    like( $out, qr/<option value="red">red/,      'option red' );
    like( $out, qr/<option value="green">green/,  'option green' );
    like( $out, qr/<option value="blue">blue/,    'option blue' );
    like( $out, qr/<option value="">-- Select --<\/option>/,
          'empty prompt option added' );
}

# --- default type is text ---
{
    my $out = main::convert_fenced_form(
        "::: form\nname | Name |\nsubmit | Send\n:::\n", $meta);
    like( $out, qr/type="text"/, 'default input type is text' );
}

# --- submit row renders a button ---
{
    my $out = main::convert_fenced_form(
        "::: form\nsubmit | Go\n:::\n", $meta);
    like( $out, qr/<button type="submit">Go<\/button>/, 'submit button' );
}

# --- every form gets hidden fields and honeypot ---
{
    my $out = main::convert_fenced_form(
        "::: form\nsubmit | Send\n:::\n", $meta);
    like( $out, qr/name="_form"/,  '_form hidden field' );
    like( $out, qr/name="_ts"/,     '_ts hidden field' );
    like( $out, qr/name="_tk"/,     '_tk hidden field' );
    like( $out, qr/name="_hp"/,     '_hp honeypot field' );
}

done_testing();
