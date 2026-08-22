#!/usr/bin/perl
# SM466 / SM456: confirm what a VISITOR receives, from inside the grant.
#
# THE REPORTED GAP. Nothing could confirm that a public page renders its own
# layout. Every tool the field agent held answered a different question -
# preview_page renders through the manager, read_page returns source,
# page_status reports metadata - and per-Host routing is what makes those
# different questions rather than three views of one: the layout is chosen from
# the Host, so a docroot-shaped tool cannot report it.
#
# Fetching the page directly works and is not the answer. It is egress outside
# the grant model, and a result obtained that way cannot be attributed to any
# capability the partner holds - a grant cannot attribute its own access.
#
# preview_public ALREADY rendered as an anonymous visitor under the owning
# Host (SM441). It had the answer and did not say it. So this is not a new
# mechanism; it is the existing one reporting what it already knew, plus an MCP
# door so the field can reach it.
#
# READ FROM THE RESPONSE, NEVER THE CONFIGURATION, which is the whole point.
# "What should this domain use" was always answerable. SM441 was a case where
# the configuration said one thing and the visitor got another, and every tool
# that consulted the configuration agreed with the configuration.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Domains ();

# The renderer is not driven here - that needs a whole site - so the unit under
# test is the READING, which is where the new claim lives.
my $read = \&Lazysite::Manager::Domains::_rendered_presentation;

subtest 'a styled page reports the layout and theme the visitor got' => sub {
    my $body = '<html><head><link rel="stylesheet" '
        . 'href="/lazysite-assets/journal/dusk/theme.css"></head><body>x</body></html>';
    my ($got) = $read->( '', $body );
    is( $got->{rendered_layout}, 'journal', 'the layout is named' );
    is( $got->{rendered_theme},  'dusk',    'and the theme' )
        or diag( 'SM193 mirrors an active theme to '
            . '/lazysite-assets/<layout>/<theme>/, so the stylesheet a visitor '
            . 'loaded names both - which is evidence from the response rather '
            . 'than from the configuration.' );
    ok( !exists $got->{presentation_note}, 'with no note needed' );
};

subtest 'an UNSTYLED page says so, rather than saying nothing' => sub {
    my ($got) = $read->( '', '<html><body>no theme here</body></html>' );
    ok( !defined $got->{rendered_layout}, 'no layout is reported' );
    like( $got->{presentation_note}, qr/built-in fallback/,
        'and the reason is stated' )
        or diag( 'A missing field reads as "the check did not look". This IS '
            . 'the finding when a page is unstyled, so it is said out loud.' );
};

subtest 'the fields are always present, so absence is never ambiguous' => sub {
    for my $case ( [ 'styled', '<a href="/lazysite-assets/a/b/x.css">' ],
        [ 'unstyled', '<p>plain</p>' ] )
    {
        my ($got) = $read->( '', $case->[1] );
        ok( exists $got->{rendered_layout},
            "$case->[0]: rendered_layout is present in the answer" )
            or diag( 'A caller cannot tell "not styled" from "not checked" if '
                . 'the key is sometimes missing.' );
        ok( exists $got->{rendered_theme}, "$case->[0]: rendered_theme too" );
    }
};

subtest 'a path that is not an asset path is not mistaken for one' => sub {
    my ($got) = $read->( '', '<a href="/lazysite-assets/">index</a>' );
    ok( !defined $got->{rendered_layout},
        'a bare assets link names no layout' )
        or diag( 'Reporting a layout from a path that has none would be the '
            . 'same class of fault as the thing being fixed: an answer the '
            . 'evidence does not support.' );
};

done_testing();
