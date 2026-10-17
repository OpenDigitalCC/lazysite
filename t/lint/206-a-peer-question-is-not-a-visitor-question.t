#!/usr/bin/perl
# SM929: FIVE PLACES STILL READ REMOTE_ADDR, AND EACH ONE IS A DECISION.
#
# Forty-four reads asked "who is this request from" and answered with the front
# proxy. They now go through one definition of the request address. But a handful
# of reads were never asking that question at all - they ask whether the PEER is
# this machine, which is a fact about the connection and must never come from a
# header a proxy carries or a visitor writes:
#
#   - the no-password account gate (auth): docs/architecture/security.md says in
#     those words that only the immediate remote address matters here, and a
#     forwarded address that could unlock a passwordless login would be the worst
#     possible place to start trusting one;
#   - the plaintext-transport gates (auth claim/exchange/rotate, dav): "HTTPS, or
#     loopback for dev" - a loopback VISITOR behind a proxy is not a loopback
#     CONNECTION, and treating it as one would accept credentials in clear;
#   - the trust check inside the one definition itself, which is what makes the
#     whole thing unforgeable.
#
# THIS LEDGER EXISTS SO THE EXCEPTIONS CANNOT BE MISTAKEN FOR OVERSIGHTS, in either
# direction: a new bare REMOTE_ADDR read fails here until someone writes down which
# question it asks, and deleting one of these (say, "unifying" the transport gate)
# fails too. An unexplained read is the state this filing was raised about.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

# file => [ [ line pattern, why this one asks about the PEER ], ... ]
my %LEDGER = (
    'lazysite-auth.pl' => [
        [ qr/my \$addr = \$ENV\{REMOTE_ADDR\}/,
            'the no-password account gate - only the immediate peer may unlock it'
        ],
        [ qr/my \$peer = \$ENV\{REMOTE_ADDR\}/,
            'handle_claim: plaintext is allowed only from a loopback CONNECTION'
        ],
        [ qr/my \$peer = \$ENV\{REMOTE_ADDR\}/,
            'handle_exchange: the same transport gate'
        ],
        [ qr/my \$peer = \$ENV\{REMOTE_ADDR\}/,
            'handle_rotate: the same transport gate'
        ],
    ],
    'lazysite-dav.pl' => [
        [ qr/my \$peer = \$ENV\{REMOTE_ADDR\}/,
            'the DAV transport gate - never accept Basic credentials over plaintext'
        ],
    ],
    # SM944: the processor is the script and its parts; code_lines reads them all.
    'the processor' => [
        [ qr/my \$peer\s+= \$ENV\{REMOTE_ADDR\}/,
            'the trust check inside the one definition - the peer is the trust basis'
        ],
        [ qr/peer => \( \$ENV\{REMOTE_ADDR\}/,
            'SM1129 _proxy_identity: whether the immediate peer may send identity headers - never a forwarded address'
        ],
    ],
);

# And these files must now hold NONE: every read in them was a record of who the
# visitor was, which is the question the one definition answers.
my @NO_BARE_READS = (
    'lazysite-mcp.pl',
    'lazysite-oauth.pl',
    'the manager API',
    'plugins/form-handler.pl',
    'plugins/form-smtp.pl',
    'plugins/payment-demo.pl',
);

my @PROCESSOR = ( 'lazysite-processor.pl',
    map { s{\A\Q$root/\E}{}r } sort glob("$root/lazysite-processor/*.pm") );

# SM944 S31: the manager API's request address, _request_ip, lives in
# Lazysite::Manager::Common (ruled 2026-10-10), which the script imports it from;
# the script and that module are read as one.
my @MANAGER_API = ( 'lazysite-manager-api.pl', 'lib/Lazysite/Manager/Common.pm' );
my %SET         = ( 'the processor' => \@PROCESSOR, 'the manager API' => \@MANAGER_API );

sub code_lines {
    my ($file) = @_;
    my @out;
    for my $f ( $SET{$file} ? @{ $SET{$file} } : ($file) ) {
        open my $fh, '<', "$root/$f" or die "$f: $!";
        while ( my $l = <$fh> ) {
            next if $l =~ /^\s*#/;    # a comment may name the variable freely
            push @out, $l;
        }
        close $fh;
    }
    return @out;
}

for my $file ( sort keys %LEDGER ) {
    my @reads = grep { /\$ENV\{REMOTE_ADDR\}/ } code_lines($file);
    my $want  = scalar @{ $LEDGER{$file} };
    is( scalar @reads, $want, "$file: exactly $want peer read(s), all accounted for" )
        or diag( "  found:\n" . join( '', map { "    $_" } @reads )
            . "  Every REMOTE_ADDR read must say which question it asks. If this is\n"
            . "  the VISITOR, use the one definition (_request_ip / _request_address).\n"
            . "  If it is the PEER, add it to this ledger with the reason.\n" );

    my $i = 0;
    for my $entry ( @{ $LEDGER{$file} } ) {
        my ( $pattern, $why ) = @{$entry};
        my $line = $reads[ $i++ ] // '';
        like( $line, $pattern, "$file: $why" );
    }
}

for my $file (@NO_BARE_READS) {
    my @reads = grep { /\$ENV\{REMOTE_ADDR\}/ } code_lines($file);
    is( scalar @reads, 0, "$file: reads the request address, never the bare peer" )
        or diag( "  found:\n" . join( '', map { "    $_" } @reads ) );
}

# --- AND THE PEER VALUE IS WHAT THE PEER QUESTION IS ASKED OF ----------------
# Counting the reads is not enough, and a sabotage proved it: switching the DAV
# transport gate from $peer to the visitor address left the `my $peer = ...` line
# in place, so the count above still matched while the gate had changed meaning.
# Two assertions covering one claim. These assert the USE.
{
    my $dav = join '', code_lines('lazysite-dav.pl');
    like( $dav, qr/\$loopback\s*=\s*\(\s*\$peer eq '127\.0\.0\.1'\s*\|\|\s*\$peer eq '::1'\s*\)/,
        'lazysite-dav.pl: the loopback test is made of the PEER, not the visitor' );

    my $auth  = join '', code_lines('lazysite-auth.pl');
    my $gates = () = $auth =~ /_secure_transport\(\$peer\)/g;
    is( $gates, 3,
        'lazysite-auth.pl: all three transport gates are asked of the PEER' );
    unless ( $gates == 3 ) {
        diag( "  _secure_transport decides whether credentials may cross in clear.\n"
                . "  A visitor on 127.0.0.1 behind a proxy is not a loopback CONNECTION,\n"
                . "  and reading the request address here would accept plaintext for\n"
                . "  anyone whose forwarded address happened to say localhost.\n" );
    }
    unlike( $auth, qr/_secure_transport\(\s*_request_ip/,
        'and never of the request address' );
    like( $auth, qr/my \$addr = \$ENV\{REMOTE_ADDR\}[^;]*;\s*\n\s*unless \(\s*\$addr eq '127\.0\.0\.1'/,
        'the no-password gate tests the value it read from the connection' );
}

# The other half of the claim: those files DO read the address, through the one
# helper. A file that read neither would have quietly stopped recording anything.
for my $file (@NO_BARE_READS) {
    my $src = '';
    for my $f ( $SET{$file} ? @{ $SET{$file} } : ($file) ) {
        open my $fh, '<', "$root/$f" or die "$f: $!";
        $src .= do { local $/; <$fh> };
        close $fh;
    }
    like( $src, qr/_request_ip\(\)/, "$file: and it does read the request address" );
    like( $src, qr/Lazysite::Util::request_address/,
        "$file: through the one definition, not a local copy of the walk" );
}

done_testing();
