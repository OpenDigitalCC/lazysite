#!/usr/bin/perl
# SM072 batch 4: TOTP (RFC 6238) - the primitive against the published test
# vectors, plus enrol / verify / recovery-code / disable round-trips.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json decode_json);
use IPC::Open2;
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root   = repo_root();
my $script = "$root/tools/lazysite-users.pl";

sub fresh_docroot {
    my $d = tempdir( CLEANUP => 1 );
    mkdir "$d/lazysite";
    mkdir "$d/lazysite/auth";
    return $d;
}
sub cli {
    my ( $docroot, @args ) = @_;
    my ( $wtr, $rdr ); my $err = gensym;
    my $pid = open3( $wtr, $rdr, $err, $^X, $script, '--docroot', $docroot, @args );
    close $wtr;
    my $out = do { local $/; <$rdr> }; do { local $/; <$err> };
    waitpid $pid, 0;
    return { out => $out // '', code => $? >> 8 };
}
sub api {
    my ( $docroot, $payload ) = @_;
    my ( $cout, $cin );
    my $pid = open2( $cout, $cin, $^X, $script, '--api', '--docroot', $docroot );
    print $cin encode_json($payload); close $cin;
    my $out = do { local $/; <$cout> }; close $cout;
    waitpid $pid, 0;
    return eval { decode_json($out) } // { _raw => $out };
}
sub settings { api( $_[0], { action => 'settings-get', username => $_[1] } )->{settings} }

# --- RFC 6238 SHA1 test vectors (8-digit) -----------------------------
{
    my $d = fresh_docroot();
    my $SECRET = 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ';   # ASCII "12345678901234567890"
    my %vec = (
        59         => '94287082',
        1111111109 => '07081804',
        1111111111 => '14050471',
        1234567890 => '89005924',
        2000000000 => '69279037',
    );
    for my $t ( sort { $a <=> $b } keys %vec ) {
        my $r = api( $d, { action => 'totp-code', secret => $SECRET, time => $t, step => 30, digits => 8 } );
        is( $r->{code}, $vec{$t}, "RFC 6238 vector at t=$t" );
    }
}

# --- enrol, verify, recovery codes, disable ---------------------------
{
    my $d = fresh_docroot();
    cli( $d, 'add', 'alice', 'pw' );

    my $e = api( $d, { action => 'mfa-enroll', username => 'alice' } );
    ok( $e->{ok} && $e->{secret}, 'enrol returns a secret' );
    like( $e->{otpauth_uri}, qr{^otpauth://totp/}, 'otpauth URI present' );
    is( scalar @{ $e->{recovery_codes} }, 8, 'eight recovery codes' );
    ok( settings( $d, 'alice' )->{mfa_enrolled}, 'mfa_enrolled is true' );

    my $code = api( $d, { action => 'totp-code', secret => $e->{secret},
                          time => time(), step => 30, digits => 6 } )->{code};
    ok(  api( $d, { action => 'mfa-verify', username => 'alice', code => $code } )->{ok},
        'the current TOTP verifies' );
    ok( !api( $d, { action => 'mfa-verify', username => 'alice', code => $code } )->{ok},
        'the same TOTP code cannot be replayed (review item 5)' );
    ok( !api( $d, { action => 'mfa-verify', username => 'alice', code => 'nope' } )->{ok},
        'an invalid code fails' );

    my $rc = $e->{recovery_codes}[0];
    ok(  api( $d, { action => 'mfa-verify', username => 'alice', code => $rc } )->{ok},
        'a recovery code works' );
    ok( !api( $d, { action => 'mfa-verify', username => 'alice', code => $rc } )->{ok},
        'a recovery code is single-use' );

    api( $d, { action => 'mfa-disable', username => 'alice' } );
    ok( !settings( $d, 'alice' )->{mfa_enrolled}, 'mfa_enrolled false after disable' );
    ok( !api( $d, { action => 'mfa-verify', username => 'alice', code => $code } )->{ok},
        'verify fails once MFA is disabled' );
}

done_testing();
