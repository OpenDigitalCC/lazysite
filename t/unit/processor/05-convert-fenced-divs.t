#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site);

my $docroot = tempdir( CLEANUP => 1 );
setup_minimal_site($docroot);
load_processor($docroot);

# --- basic fenced div ---
{
    my $out = main::convert_fenced_divs("::: widebox\nContent here.\n:::\n");
    like(   $out, qr/<div class="widebox">/, 'opening div tag' );
    like(   $out, qr/Content here\./,        'content preserved' );
    like(   $out, qr/<\/div>/,               'closing div tag' );
}

# --- valid class names accepted ---
for my $class ( qw(widebox textbox marginbox examplebox my-class) ) {
    my $out = main::convert_fenced_divs("::: $class\ntest\n:::\n");
    like( $out, qr/class="$class"/, "class '$class' accepted" );
}

# --- invalid class name rejected ---
{
    my $out = main::convert_fenced_divs("::: bad<class>\ntest\n:::\n");
    unlike( $out, qr/<div/, 'invalid class name does not produce div' );
}

# --- nested markdown preserved inside div ---
{
    my $out = main::convert_fenced_divs(
        "::: textbox\n**Bold** and *italic*\n:::\n");
    like( $out, qr/\*\*Bold\*\*/,  'bold markdown preserved' );
    like( $out, qr/\*italic\*/,    'italic markdown preserved' );
}

# --- multiple divs ---
{
    my $in  = "::: widebox\nFirst\n:::\n\n::: textbox\nSecond\n:::\n";
    my $out = main::convert_fenced_divs($in);
    my @divs = ( $out =~ /<div /g );
    is( scalar @divs, 2, 'two divs produced' );
}

# --- include/oembed classes pass through unchanged ---
{
    my $in  = "::: include\n/path\n:::\n";
    my $out = main::convert_fenced_divs($in);
    unlike( $out, qr/<div class="include">/,
        'include class NOT wrapped in div (dedicated converter)' );
    like( $out, qr/:::/, 'include block preserved' );

    my $in2  = "::: oembed\nhttps://example.com\n:::\n";
    my $out2 = main::convert_fenced_divs($in2);
    unlike( $out2, qr/<div class="oembed">/,
        'oembed class NOT wrapped in div (dedicated converter)' );
}

done_testing();
