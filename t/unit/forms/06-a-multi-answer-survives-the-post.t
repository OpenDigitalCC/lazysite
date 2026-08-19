#!/usr/bin/perl
# SM401: the handler side of structured answers.
#
# TWO DEFECTS, BOTH SILENT. `$form{$k} = $v` overwrote, so a field submitted more
# than once - which is how HTML has always expressed a multi-select - kept only
# the last value. The submission still arrived and still looked well-formed, so
# nothing anywhere said that answers had been dropped.
#
# And checklist-qty asks something the flat name/value shape cannot carry: WHICH
# options, and HOW MANY of each. The alternative to encoding that in the NAME was
# to teach this handler the form's field types, which it does not have and should
# not - the page defines the form, the handler receives it. A rule keeps the
# handler generic where a schema would couple it.
#
# The parser is exercised through the real script rather than a copy of it: the
# subs are extracted and run, so a change to the handler that broke this could
# not pass by virtue of the test having its own implementation.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $handler = repo_root() . '/plugins/form-handler.pl';
plan skip_all => "no $handler" unless -f $handler;

my $src = do { open my $fh, '<', $handler or die $!; local $/; <$fh> };

my ($fold) = $src =~ /(sub _fold_quantities \{.*?\n\}\n)/s;
ok( $fold, 'the quantity fold can be isolated' ) or BAIL_OUT('cannot extract');

## no critic (BuiltinFunctions::ProhibitStringyEval)
eval "$fold 1" or BAIL_OUT("cannot load the fold: $@");
## use critic

# --- the fold ---------------------------------------------------------
{
    my %f = (
        batches         => 'A; C',
        'batches~qty~A' => '60',
        'batches~qty~C' => '40',
        name            => 'Dept',
    );
    _fold_quantities( \%f );
    is( $f{batches}, 'A=60; C=40', 'ticked options carry their quantities' );
    ok( !exists $f{'batches~qty~A'}, 'and the raw quantity keys are gone' );
    is( $f{name}, 'Dept', 'an ordinary field is untouched' );
}

{
    # A quantity left behind for an option that was then UNTICKED. This is what
    # a person does when they change their mind, and it must not submit a
    # quantity for something they deselected.
    my %f = ( b => 'A', 'b~qty~A' => '5', 'b~qty~B' => '99' );
    _fold_quantities( \%f );
    is( $f{b}, 'A=5', 'a quantity for an unticked option is dropped' );
}

{
    my %f = ( b => 'A; B', 'b~qty~A' => '7' );
    _fold_quantities( \%f );
    is( $f{b}, 'A=7; B', 'an option with no quantity keeps its bare label' );
}

for my $bad ( '', '0', 'abc', '-3', '3.5' ) {
    my %f = ( b => 'A', 'b~qty~A' => $bad );
    _fold_quantities( \%f );
    is( $f{b}, 'A', "a quantity of '$bad' is refused, leaving the bare tick" );
}

{
    my %f = ( plain => 'x' );
    _fold_quantities( \%f );
    is_deeply( \%f, { plain => 'x' }, 'a form with no quantities is unchanged' );
}

# --- the repeated key, in the parser itself ----------------------------
# Asserted against the source, because parse_post reads STDIN and the shape
# being pinned is the accumulate-rather-than-overwrite branch.
like( $src, qr/\$form\{\$k\} \.= "; \$v"/,
    'a repeated key accumulates rather than overwriting' );
unlike( $src, qr/\$form\{\$k\} = sanitise_header/,
    'the overwriting assignment is gone' );

# --- the rate limit ----------------------------------------------------
like( $src, qr/sub check_rate_limit \{\s*my \( \$ip, \$limit \) = \@_;/,
    'the rate limit takes a per-form ceiling' );
like( $src, qr/\$limit = defined \$limit \? \$limit : 5;/,
    'defaulting to the shipped 5 when the form does not set one' );
like( $src, qr/return if \$limit <= 0;/, 'and 0 / off removes it' );
like( $src, qr/\$count >= \$limit/,      'the comparison uses the configured value' );

# The header-based exemption that was ASKED for is deliberately absent: this
# handler is not behind the auth wrapper, so HTTP_X_REMOTE_USER arrives exactly
# as the client sent it and exempting on it would put the limit one header away
# from useless.
unlike( $src, qr/return\s+if\s+.*HTTP_X_REMOTE_USER/,
    'the rate limit is NOT exempted on an unverified request header' );

done_testing();
