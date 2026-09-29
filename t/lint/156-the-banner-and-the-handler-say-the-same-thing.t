#!/usr/bin/perl
# SM579: THE TWO COPIES OF WHAT A VISITOR IS TOLD AGREE.
#
# A successful submission is answered twice, on two paths that cannot share code:
#
#   the JS path   - plugins/form-handler.pl returns { ok: 1, message: "..." }
#   the no-JS path - it redirects with `?form=X&outcome=<token>`, and
#                    lazysite-processor.pl renders the sentence for that token
#
# The processor cannot read the handler: ADR 0001 keeps the render path
# module-free, which is why _acl_allows_read is a second copy of the ACL decision
# with t/lint/36 holding the two together. This is the same shape, so it gets the
# same treatment - and the reason a lint rather than a note is that the two
# sentences are PROSE. Nothing fails when they drift; a visitor simply gets one
# wording with JavaScript and a different one without, and nobody is looking at
# both at once.
#
# WHY THE WORDING IS KEYED RATHER THAN CARRIED, which this also pins: the query
# string is attacker-writable by construction, so a sentence travelling in the URL
# would let a crafted link put any text on the page in the SUCCESS style. The token
# selects from a closed map on each side; an attacker choosing between two engine
# sentences gains nothing. That is why the map exists at all, and why an
# open-ended `ok:<text>` outcome would be the wrong shape.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp {
    open my $fh, '<:utf8', $_[0] or die "$_[0]: $!";
    local $/;
    return <$fh>;
}

# Both sides declare the same shape - a token => sentence map - so both are read
# the same way rather than with two bespoke patterns.
#
# THE KEY IS READ LOOSELY ON PURPOSE. An earlier version of this matched keys as
# [a-z][a-z0-9-]* - the shape a token is SUPPOSED to have - and sabotage showed
# what that costs: a token with a space did not fail the "survives the redirect"
# assertion below, it fell out of BOTH maps, so is_deeply then compared two
# equally-incomplete maps and would have agreed. A parser that discards what it
# cannot understand turns a drifted map into a passing test. So: take any quoted
# key, and judge its shape in an assertion where a failure is visible.
sub said_in {
    my ( $src, $what ) = @_;
    my ($block) = $src =~ /\Q$what\E\s*=\s*\(\s*(.*?)\n\s*\);/s;
    return ( {}, 0 ) unless defined $block;
    my %said;
    # A key may be bare (`ok =>`) or quoted (`'ok-processing' =>`); perltidy leaves
    # whichever the author wrote, so both are read and the quotes stripped after.
    while ( $block =~ /^\s*(.+?)\s*=>\s*\n?\s*'((?:[^'\\]|\\.)*)'/mg ) {
        my ( $key, $sentence ) = ( $1, $2 );
        $key =~ s/\A'(.*)'\z/$1/s;
        $said{$key} = $sentence;
    }
    # What the block DECLARES, counted independently of what parsed. A pair the
    # loop could not read is a hole in the measurement, not an absent entry.
    my $pairs = () = $block =~ /=>/g;
    return ( \%said, $pairs );
}

my ( $handler,   $h_pairs ) = said_in( slurp("$root/plugins/form-handler.pl"), 'our %OUTCOME_SAID' );
my ( $processor, $p_pairs ) = said_in( slurp("$root/lazysite-processor.pl"),   'my %SAID' );

cmp_ok( scalar keys %{$handler}, '>=', 2, 'the handler declares its sentences' )
    or diag( 'Looked for `our %OUTCOME_SAID = (...)` in plugins/form-handler.pl.' );
cmp_ok( scalar keys %{$processor}, '>=', 2, 'and the processor declares the banner\'s' )
    or diag( 'Looked for `my %SAID = (...)` beside the banner in lazysite-processor.pl.' );

# THE MEASUREMENT IS WHOLE, asserted before anything is concluded from it. Without
# this, an entry this file cannot parse reads as an entry that is not there.
is( scalar keys %{$handler}, $h_pairs,
    'every sentence the handler declares was read' )
    or diag( "The handler's map has $h_pairs pairs but "
        . scalar( keys %{$handler} )
        . ' parsed, so this test is comparing less than the file says.' );
is( scalar keys %{$processor}, $p_pairs,
    'and every sentence the processor declares' )
    or diag( "The banner's map has $p_pairs pairs but "
        . scalar( keys %{$processor} )
        . ' parsed, so this test is comparing less than the file says.' );

is_deeply( $processor, $handler,
    'the banner and the handler say the same thing, token for token' )
    or diag( "A visitor would be told one thing with JavaScript and another "
        . "without, and nothing else would fail.\n"
        . "  handler:   " . join( ' | ', map { "$_=$handler->{$_}" } sort keys %{$handler} ) . "\n"
        . "  processor: " . join( ' | ', map { "$_=$processor->{$_}" } sort keys %{$processor} ) );

# THE TOKENS MUST SURVIVE THE REDIRECT, which URL-encodes anything outside
# [A-Za-z0-9-. _] and turns a space into `+`. A token that came back altered would
# miss the map and render as an ERROR - the success shown as a failure.
for my $tok ( sort keys %{$handler} ) {
    like( $tok, qr/\A[A-Za-z0-9._-]+\z/,
        "the '$tok' token passes through _redirect_back unaltered" );
}

# AND THE SENTENCE IS NEVER THE OUTCOME ITSELF. `$o` is attacker-writable; it may
# only ever be a KEY.
{
    my $src = slurp("$root/lazysite-processor.pl");
    like( $src, qr/\$SAID\{\$o\}/,
        'the banner looks the sentence up by token' );
    unlike( $src, qr/form-status-ok[^\n]*role="status">\$o</,
        'and never prints the outcome itself in the success style' )
        or diag( 'That is the phishing shape the closed map exists to prevent: a '
            . 'crafted link putting arbitrary text on the page in green.' );
}

done_testing();
