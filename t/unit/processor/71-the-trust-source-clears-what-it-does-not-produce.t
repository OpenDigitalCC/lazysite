#!/usr/bin/perl
# The wild-facing request-path review, 0.13.8. Three findings, three fixes,
# each of them putting a value back inside a rule the code already keeps
# somewhere else.
#
# SM794 - THE ONE THAT MATTERED. lazysite-auth.pl sets LAZYSITE_AUTH_TRUSTED=1
# and the C-1 gate then returns EARLY, so every trusted header survives - but
# the success block only ever wrote two of the six. The other four arrived from
# the client and were passed on as ours, and one of them is the payment proof.
# A logged-in visitor adding `X-Payment-Verified: 1` was served payment-gated
# content. The boundary is now produce-or-clear.
#
# SM795 - the engine tree is blocked by a test on the REQUEST STRING, while the
# canonical serve confined only to the docroot. _resolve_include, in the same
# file, tests the RESOLVED path and says why. Same rule, now in both.
#
# SM796 - request_uri entered the render stash raw between two escaped
# neighbours.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
sub src {
    my ($f) = @_;
    open my $fh, '<', "$root/$f" or die "$f: $!";
    local $/;
    return <$fh>;
}
my $auth = src('lazysite-auth.pl');
my $proc = src('lazysite-processor.pl');

subtest 'the trust source clears every trusted field it does not produce' => sub {
    # The six the gate covers. Two are produced from the verified cookie; the
    # other four must be cleared, or the early return hands the client's own
    # values on as trusted.
    # WITH THE PARENTHESES. Twice today a match without a capture group
    # returned 1 and every assertion below ran against the string "1".
    my ($gate) = $proc =~ /(sub apply_trust_gate.*?\n\})/s;
    ok( $gate, 'the gate was found' ) or return;
    my @covered = $gate =~ /(HTTP_X_(?:REMOTE|PAYMENT)_[A-Z]+)/g;
    my %covered = map { $_ => 1 } @covered;
    is( scalar keys %covered, 6, 'the gate covers six headers' )
        or diag( join ', ', sort keys %covered );

    my ($block) = $auth =~ /(if \(\$ident\).{0,4000})/s;
    ok( $block, 'the success block was found' ) or return;
    for my $h ( sort keys %covered ) {
        my $produced = $block =~ /\$ENV\{\Q$h\E\}\s*=/;
        my $cleared  = $block =~ /delete \@ENV\{[^}]*\Q$h\E/s;
        ok( $produced || $cleared,
            "$h is produced or cleared by the trust source" )
            or diag( "The gate returns early on the sentinel, so a header this "
                . 'block neither sets nor deletes is the CLIENT\'S, passed on as ours.' );
    }
    # Named, because it is the one with a price attached.
    ok( $block =~ /delete \@ENV\{[^}]*HTTP_X_PAYMENT_VERIFIED/s,
        'the payment proof specifically is cleared - it was a 402 turned into a 200' );
};

subtest 'the canonical serve excludes the engine tree, as the include path does' => sub {
    my ($serve) = $proc =~ /(sub _serve_content_static.{0,3000})/s;
    ok( $serve, 'the static serve was found' ) or return;
    like( $serve, qr/_path_under\(\s*\$real,\s*\$LAZYSITE_DIR\s*\)/,
        'it tests the RESOLVED path against the engine tree' )
        or diag( 'The engine-tree block earlier is a test on the REQUEST '
            . 'STRING. A symlink resolves past it.' );

    # The include path is the reference, and the point is that they now agree.
    my ($inc) = $proc =~ /(sub _resolve_include.{0,4000})/s;
    like( $inc, qr/_path_under\(\s*\$real,\s*"?\$LAZYSITE_DIR"?\s*\)/,
        'the include path makes the same test - one rule, two sinks' );
};

subtest 'every client-influenced value enters the stash escaped' => sub {
    like( $proc, qr/request_uri\s*=>\s*_esc_html\(/,
        'request_uri is escaped where the stash is built' )
        or diag( 'It sat raw between two _esc_html neighbours, and the shipped '
            . '402/403 pages interpolate it into an href.' );
};

# The check whose absence let SM794 stand for a release.
subtest 'the lint asks the question that would have caught it' => sub {
    my $lint = src('t/lint/38-trust-headers-gated-in-app.t');
    like( $lint, qr/PAYMENT/,
        'the trust-header lint knows the payment headers exist' )
        or diag( 'Its trigger was HTTP_X_REMOTE_(USER|GROUPS|NAME|EMAIL), so '
            . 'the payment headers were outside its alphabet entirely.' );
};

done_testing;
