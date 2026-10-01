#!/usr/bin/perl
# SM921: an owner typed the single letter S into their phone field and was allowed.
#
# The engine's shipped `tel` default was `[\d\s()+.-]{6,20}` - a valid Perl regex
# and an INVALID HTML pattern. A browser compiles the attribute as
# `new RegExp("^(?:"+pattern+")$","v")`, and under the `v` (unicodeSets) flag a bare
# `(`, `)` or a hyphen at the end of a character class is a syntax error. The
# specification's answer to a pattern that will not compile is to IGNORE THE
# ATTRIBUTE IN FULL - so the field was not loosely validated, it was unvalidated,
# and no console message said so.
#
# TWO LEVELS OF ASSERTION HERE, deliberately:
#
#   1. the helper's own verdicts, which run everywhere;
#   2. a cross-check against NODE's `v` flag - the same compiler a browser uses -
#      which runs where node exists and says why when it does not.
#
# The second is what makes the first trustworthy. The list of reserved characters
# cannot be derived by reading the specification carefully enough; it was MEASURED,
# and the filing's own list (which this build started from) missed `/` and `|`,
# while `~ ! # &` look equally suspicious and compile fine. A helper that drives a
# REFUSAL must not flag a pattern that works.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json decode_json);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Validate qw(html_pattern_problem);

# --- what must be refused ----------------------------------------------------

my @REFUSED = (
    [ '[\d\s()+.-]{6,20}' => 'the shipped default before this build' ],
    [ '[0-9\s+.-]{6,30}'  => 'the parens removed but the hyphen left bare' ],
    [ '[(]'               => 'a bare open paren' ],
    [ '[)]'               => 'a bare close paren' ],
    [ '[{]'               => 'a bare open brace' ],
    [ '[}]'               => 'a bare close brace' ],
    [ '[/]'               => 'a bare slash - NOT in the filing\'s list, and it fails' ],
    [ '[|]'               => 'a bare pipe - nor was this' ],
    [ '[[]'               => 'a bare open bracket' ],
    [ '[-a]'              => 'a hyphen at the start of a class' ],
    [ '[a-]'              => 'a hyphen at the end of a class' ],
    [ '[0-9-]'            => 'a hyphen after a range' ],
    [ '[\w.-]'            => 'the shape half the internet writes' ],
    [ '[a-zA-Z0-9._%+-]+' => 'the classic email class' ],
    [ '[a!!b]'            => 'a double punctuator the v flag reads as a set operation' ],
    [ '[a##b]'            => 'the other one' ],
);

for my $c (@REFUSED) {
    my ( $pat, $why ) = @$c;
    ok( html_pattern_problem($pat) ne '', "refused: $pat - $why" );
}

# --- what must NOT be refused, which is the half that matters more -----------
#
# This drives a refusal at validate time. Flagging a pattern that works would
# reject a page that renders correctly today, and the author would have no way to
# tell they had been refused for nothing.

my @ACCEPTED = (
    [ '[0-9\s\(\)\+\.\-]{6,30}' => 'the new shipped default' ],
    [ '.{2,}'                   => 'what the live diagnostic form uses' ],
    [ '[0-9]{6}'                => 'a plain class' ],
    [ '[a-z]+'                  => 'a range' ],
    [ '[a-z\-]+'                => 'an escaped hyphen at the end' ],
    [ '[\[\]]'                  => 'escaped brackets' ],
    [ '[\^]'                    => 'an escaped caret' ],
    [ '[^0-9]+'                 => 'a NEGATED class - the ^ is not a member' ],
    [ '[~]'                     => 'a bare tilde, which compiles' ],
    [ '[!]'                     => 'a bare bang, which compiles' ],
    [ '[#]'                     => 'a bare hash, which compiles' ],
    [ '[&]'                     => 'a bare ampersand, which compiles' ],
    [ '[a&&b]'                   => 'a DOUBLE ampersand, which is legal intersection' ],
    [ '\d{3}-\d{4}'             => 'a hyphen OUTSIDE a class' ],
    [ '(a|b)'                   => 'parens and a pipe outside a class' ],
    [ 'https?://.+'             => 'slashes outside a class' ],
    [ '[A-Z]{2}[0-9]{4}'        => 'a reference code' ],
    [ '[A-Za-z0-9 ]+'           => 'a space inside a class' ],
    [ 'GB[0-9]{2}[A-Z]{4}[0-9]{14}' => 'an IBAN-shaped pattern' ],
    [ '[A-Z]{1,2}[0-9][A-Z0-9]? ?[0-9][A-Z]{2}' => 'a UK postcode' ],
);

for my $c (@ACCEPTED) {
    my ( $pat, $why ) = @$c;
    is( html_pattern_problem($pat), '', "accepted: $pat - $why" );
}

subtest 'the empty and the absent are not findings' => sub {
    is( html_pattern_problem(undef), '', 'undef is not a problem' );
    is( html_pattern_problem(''),    '', 'nor is an empty pattern' );
};

subtest 'the message names the character and what to write instead' => sub {
    my $why = html_pattern_problem('[\d\s()+.-]{6,20}');
    like( $why, qr/\(/,      'it names the character it found' );
    like( $why, qr/\\\(/,    'and the escaped form to write' );
    like( $why, qr/validates nothing/,
        'and the consequence - which is the part an author would not guess, '
            . 'because a broken pattern looks like a strict one' );
};

# --- the cross-check ---------------------------------------------------------
#
# Not a skip_all: the assertions above are the gate and they ran. This adds the
# measurement when the tool for it is present, and SAYS what it could not do when
# it is not - a check that goes quiet about its own absence is the shape
# t/lint/95's history is about.
subtest 'the helper agrees with a real v-flag compiler' => sub {
    chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
    plan skip_all => 'no node on this host: the verdicts above were NOT cross-checked '
        . 'against a real v-flag compiler (install nodejs to restore this)'
        unless length $node;

    my @all = map { $_->[0] } ( @REFUSED, @ACCEPTED );
    my $dir = tempdir( CLEANUP => 1 );
    open my $pf, '>', "$dir/patterns.json" or die $!;
    print {$pf} encode_json( \@all );
    close $pf;

    open my $jf, '>', "$dir/compile.js" or die $!;
    print {$jf} <<"JS";
const fs = require('fs');
const pats = JSON.parse(fs.readFileSync('$dir/patterns.json', 'utf8'));
const out = {};
for (const p of pats) {
  try { new RegExp('^(?:' + p + ')\$', 'v'); out[p] = true }
  catch (e) { out[p] = false }
}
process.stdout.write(JSON.stringify(out));
JS
    close $jf;

    my $json = `$node $dir/compile.js 2>/dev/null`;
    my $compiles = eval { decode_json($json) };
    plan skip_all => 'node did not answer with the compile results' unless ref $compiles;

    my ( $false_refusals, $missed ) = ( 0, 0 );
    for my $pat (@all) {
        my $ok      = $compiles->{$pat} ? 1 : 0;
        my $flagged = html_pattern_problem($pat) ne '' ? 1 : 0;
        $false_refusals++ if $ok     && $flagged;
        $missed++         if !$ok    && !$flagged;
        diag("FALSE REFUSAL: $pat compiles, the helper flags it") if $ok && $flagged;
        diag("missed: $pat is uncompilable, the helper is silent") if !$ok && !$flagged;
    }
    is( $false_refusals, 0,
        'the helper flags nothing that compiles - a false refusal rejects a working page' );
    is( $missed, 0,
        'and misses nothing in this set, though under-flagging is the safe direction '
            . 'and the helper admits to it for shapes outside it' );
};

done_testing();
