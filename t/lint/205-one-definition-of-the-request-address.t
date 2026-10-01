#!/usr/bin/perl
# SM929, RULED 2026-10-01: ONE DEFINITION OF THE REQUEST ADDRESS, and there is one.
#
# Forty-four reads across nine files asked "who is this request from" and behind a
# front proxy every one of them answered with the PROXY - the same address for every
# visitor a site will ever have. The one reader that did consult X-Forwarded-For
# believed its first hop without any trust check, which was measured forgeable on a
# live site 2026-10-01.
#
# ADR 0001 keeps the render path module-free, so lazysite-processor.pl cannot call
# Lazysite::Util's definition and carries its own copy. That is the established
# trade (t/lint/198 for `_cannot_read`, 202 for the env allowlist, 203 for the
# request host) and the cost is drift. This gate is the brake.
#
# WHAT MUST STAY TRUE OF BOTH, each clause being a decision someone could undo:
#   1. the TRUST decision keys on REMOTE_ADDR - the peer, which the server sets and
#      no client can forge. That is what makes this different in kind from the
#      SM794 header-trust shape: there is no sentinel to clear.
#   2. the chain is walked FROM THE RIGHT. The filing asked for the first address,
#      which is correct only for a proxy that REPLACES the header; ours appends, so
#      a caller-supplied value arrives ahead of the true one.
#   3. a hop that will not parse ENDS the walk at the peer. Skipping it would step
#      further left, into the part of the chain the caller controls.
#   4. a zero-length prefix (/0) is REFUSED, because a trust set that matches every
#      peer is the fault this change exists to remove.
#   5. an absent OR empty setting means the private-range default, and `none` is
#      the one way to turn the trust off. Empty is NOT "off": the Config page ships
#      the field empty and pressing Save writes an empty value, so reading it as
#      off would disable the feature for anyone who merely saved the page.
#   6. a range only ever matches its own address family.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

# Lift a named sub's body out of a file by brace depth - the shape t/lint/198 and
# 203 use.
sub body_of {
    my ( $file, $name ) = @_;
    open my $fh, '<', "$root/$file" or die "$file: $!";
    my @lines = <$fh>;
    close $fh;
    my ( $in, $depth, @body ) = ( 0, 0 );
    for my $l (@lines) {
        if ( !$in && $l =~ /^\s*sub \Q$name\E\b/ ) { $in = 1 }
        next unless $in;
        push @body, $l;
        $depth++ while $l =~ /\{/g;
        $depth-- while $l =~ /\}/g;
        last if $depth <= 0 && @body > 1;
    }
    return join '', @body;
}

# The processor's copies carry a leading underscore where the module exports a
# name; everything else is spelt identically on purpose.
my @PAIRS = (
    [ 'the request address',   '_request_address',       'request_address' ],
    [ 'the trust-set parser',  '_parse_trusted_proxies', 'parse_trusted_proxies' ],
    [ 'the private default',   '_trusted_proxy_default', '_trusted_proxy_default' ],
    [ 'address to bytes',      '_packed_address',        '_packed_address' ],
    [ 'bytes to one spelling', '_text_address',          '_text_address' ],
    [ 'the range match',       '_address_in_set',        '_address_in_set' ],
);

my %PROC = map { $_->[1] => body_of( 'lazysite-processor.pl', $_->[1] ) } @PAIRS;
my %UTIL = map { $_->[2] => body_of( 'lib/Lazysite/Util.pm',  $_->[2] ) } @PAIRS;

for my $p (@PAIRS) {
    my ( $what, $pname, $uname ) = @{$p};
    ok( length $PROC{$pname}, "processor: $what ($pname) was found" );
    ok( length $UTIL{$uname}, "Util: $what ($uname) was found" );
}

# --- the clauses, asserted against BOTH copies ------------------------------
for my $pair (
    [ 'lazysite-processor.pl', $PROC{_request_address} ],
    [ 'lib/Lazysite/Util.pm',  $UTIL{request_address} ],
    )
{
    my ( $file, $b ) = @{$pair};
    next unless length $b;

    like( $b, qr/\$ENV\{REMOTE_ADDR\}/,
        "$file: clause 1 - the peer comes from REMOTE_ADDR, which no client sets" );
    like( $b, qr/reverse \@chain/,
        "$file: clause 2 - the chain is walked from the RIGHT" );
    # Whitespace-tolerant: perltidy aligns these two returns into a column, so a
    # single-space pattern would fail for a reason the tidier owns.
    like( $b, qr/return \$peer\s+unless length \$packed/,
        "$file: clause 3 - a hop that will not parse ends the walk at the peer" );
    like( $b, qr/\$ENV\{HTTP_X_FORWARDED_FOR\}/,
        "$file: and the chain is the forwarded header" );
    # The header is read only AFTER the peer has been found trustworthy: the trust
    # check must come first in the body, or the walk could run for any caller.
    my $trust_at = index $b, '_address_in_set';
    my $chain_at = index $b, 'HTTP_X_FORWARDED_FOR';
    ok( $trust_at >= 0 && $chain_at > $trust_at,
        "$file: the trust check happens BEFORE the header is read" );
}

for my $pair (
    [ 'lazysite-processor.pl', $PROC{_parse_trusted_proxies} ],
    [ 'lib/Lazysite/Util.pm',  $UTIL{parse_trusted_proxies} ],
    )
{
    my ( $file, $b ) = @{$pair};
    next unless length $b;

    like( $b, qr/\$bits \+ 0 == 0/,
        "$file: clause 4 - a zero-length prefix is refused, not honoured" );
    like( $b, qr/!length \$spec \)\s*\{\s*\@words = _trusted_proxy_default/,
        "$file: clause 5 - an absent OR empty setting means the private-range default" );
    like( $b, qr/lc\(\$spec\) eq 'none'/,
        "$file: clause 5 - and `none` is the one way to say trust nothing" );
    like( $b, qr/push \@rejected/,
        "$file: a word that is not a range is REPORTED, not silently dropped" );
}

for my $pair (
    [ 'lazysite-processor.pl', $PROC{_address_in_set} ],
    [ 'lib/Lazysite/Util.pm',  $UTIL{_address_in_set} ],
    )
{
    my ( $file, $b ) = @{$pair};
    next unless length $b;
    like( $b, qr/length\(\$net\) == length\(\$packed\)/,
        "$file: clause 6 - a range only matches its own address family" );
}

# --- and the bodies must say the SAME thing, line for line ------------------
sub norm {
    my ($b) = @_;
    $b =~ s/^\s*#.*$//mg;    # comments are allowed to differ
    $b =~ s/\bsub\s+_(request_address|parse_trusted_proxies)\b/sub $1/;
    $b =~ s/\b_(request_address|parse_trusted_proxies)\(/$1(/g;
    $b =~ s/\s+/ /g;
    $b =~ s/\A\s+|\s+\z//g;
    return $b;
}

for my $p (@PAIRS) {
    my ( $what, $pname, $uname ) = @{$p};
    next unless length $PROC{$pname} && length $UTIL{$uname};
    is( norm( $PROC{$pname} ), norm( $UTIL{$uname} ),
        "$what: the two copies are the SAME decision, line for line" )
        or diag( "  processor: " . norm( $PROC{$pname} ) . "\n"
            . "  util:      " . norm( $UTIL{$uname} ) . "\n"
            . "  Two copies of one judgement about who a request is from. The\n"
            . "  render path and everything else would disagree about the\n"
            . "  visitor, which is the whole of what SM929 ruled against.\n" );
}

# --- the default is a SUB in both, and that is not a style choice -----------
# A file-scoped `our @ARRAY` below the processor's main body is EMPTY when a
# request is served (t/lint/39 names exactly this). As a package array the default
# silently became "trust nothing" in the render path, which failed safe and failed
# to work - caught by t/unit/processor/27 before it ever ran anywhere.
for my $file ( 'lazysite-processor.pl', 'lib/Lazysite/Util.pm' ) {
    open my $fh, '<', "$root/$file" or die "$file: $!";
    my $src = do { local $/; <$fh> };
    close $fh;
    unlike( $src, qr/our \@TRUSTED_PROXY_DEFAULT/,
        "$file: the private-range default is a sub, not file-scoped state" );
    like( $src, qr/sub _trusted_proxy_default/,
        "$file: and it is spelt as one" );
}

done_testing();
