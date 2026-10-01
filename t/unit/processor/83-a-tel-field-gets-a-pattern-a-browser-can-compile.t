#!/usr/bin/perl
# SM921, the render half: the shipped `tel` default compiles now, and an author's
# own `pattern:` survives a space.
#
# THE DEFECT WAS INVISIBLE IN BOTH DIRECTIONS. The shipped default
# `[\d\s()+.-]{6,20}` is a valid Perl regex and an invalid HTML pattern - browsers
# compile the attribute with the `v` flag, which refuses a bare `(`, `)` or a hyphen
# at the end of a character class, and the specification's answer to an uncompilable
# pattern is to ignore the attribute entirely. So the field accepted the single
# letter S, which is how an owner found it. In the other direction, `pattern:` was
# tokenised on whitespace, so a pattern containing a space was cut at the space -
# `pattern:[0-9 ()+.-]{6,30}` rendered `pattern="[0-9"`, which IS valid and refuses
# almost everything.
#
# One silent under-rejection and one silent over-rejection, in the only validation
# the form grammar offers beyond required/email/maxlength.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor site_tempdir);

load_processor( site_tempdir() );

subtest 'the shipped tel default is escaped, and wide enough for a real number' => sub {
    my $html = main::_render_form( "phone | Phone | tel\n", { form => 't' } );
    my ($pat) = $html =~ /name="phone"[^>]*\spattern="([^"]*)"/;
    ok( defined $pat, 'a tel field still gets a default pattern' );

    is( $pat, '[0-9\s\(\)\+\.\-]{6,30}',
        'every reserved character inside the class is escaped' );
    unlike( $pat, qr/\(\)/,
        'the bare parentheses are gone - they are what made the old default a '
            . 'syntax error, and a syntax error is IGNORED rather than reported' );
    unlike( $pat, qr/\{6,20\}/,
        'and the bound is no longer 20: `+33 (0) 1 89 48 00 40` is 21 characters, '
            . 'so a French number written the way France writes it failed it' );

    # The two halves of the fix are independent, and this is the half a test can
    # assert without a browser: the characters a `v`-flag compiler reserves inside
    # a character class are each written with a backslash.
    # index, not a regex: a backslash inside qr// with \Q is two levels of quoting
    # deep and the first draft of this loop looked for TWO backslashes and failed
    # against correct output.
    for my $c ( '(', ')', '+', '.', '-' ) {
        ok( index( $pat, "\\$c" ) >= 0, "$c is escaped" );
    }
};

subtest 'an author pattern containing a space arrives whole' => sub {
    my $html = main::_render_form(
        "phone | Phone | tel pattern:[0-9 ()+.-]{6,30}\n", { form => 't' } );
    my ($pat) = $html =~ /name="phone"[^>]*\spattern="([^"]*)"/;
    is( $pat, '[0-9 ()+.-]{6,30}',
        'the whole pattern reaches the attribute, space and all' );
    isnt( $pat, '[0-9',
        'and not the first token - which was valid, so nothing warned and the '
            . 'field refused almost every value' );
};

subtest 'the quoted form still means exactly what it meant' => sub {
    my $html = main::_render_form(
        qq(phone | Phone | tel pattern:"[0-9 ()+.-]{6,30}" required\n), { form => 't' } );
    my ($pat) = $html =~ /name="phone"[^>]*\spattern="([^"]*)"/;
    is( $pat, '[0-9 ()+.-]{6,30}', 'the quoted value is the pattern' );
    like( $html, qr/name="phone"[^>]*\srequired/,
        'and a rule AFTER a quoted pattern still applies - which is the spelling '
            . 'for a pattern that cannot go last' );
};

# THE TRADE, PINNED. Taking the rest of the line is what the option lists do and
# what the ruling asked for, and it has the same consequence: anything after the
# pattern is part of the pattern. Measured before the change - of the 16 form-field
# lines carrying a pattern: rule in the shipped tree and the live sites repo, ZERO
# had another rule after it - but the behaviour is asserted here so that nobody
# "fixes" it by accident, and so the docs and the code agree about where to put it.
subtest 'an unquoted pattern takes the rest of the line, so it goes last' => sub {
    my $html = main::_render_form(
        "ref | Reference | pattern:[A-Z]{3} required\n", { form => 't' } );
    my ($pat) = $html =~ /name="ref"[^>]*\spattern="([^"]*)"/;
    is( $pat, '[A-Z]{3} required',
        'the trailing rule became part of the pattern - put pattern: last, or '
            . 'quote it' );
    # `\srequired>` and not `\srequired`: the word is INSIDE the pattern value, so
    # the looser regex matched the attribute it was meant to rule out.
    unlike( $html, qr/\srequired>/,
        'so it is NOT also applied as a rule, which is the thing to know' );
};

subtest 'a field with no tel and no pattern gets no pattern' => sub {
    my $html = main::_render_form( "name | Your name | required\n", { form => 't' } );
    unlike( $html, qr/name="name"[^>]*\spattern=/,
        'the default belongs to tel alone' );
};

done_testing();
