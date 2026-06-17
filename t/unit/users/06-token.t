#!/usr/bin/perl
# SM070: credential generation (token command) in lazysite-users.pl.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json decode_json);
use Digest::SHA qw(sha256_hex);
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
    my ( $wtr, $rdr );
    my $err = gensym;
    my $pid = open3( $wtr, $rdr, $err, $^X, $script, '--docroot', $docroot, @args );
    close $wtr;
    my $out = do { local $/; <$rdr> };
    my $eout = do { local $/; <$err> };
    waitpid $pid, 0;
    return { out => $out // '', err => $eout // '', code => $? >> 8 };
}

sub api {
    my ( $docroot, $payload ) = @_;
    my ( $cout, $cin );
    my $pid = open2( $cout, $cin, $^X, $script, '--api', '--docroot', $docroot );
    print $cin encode_json($payload);
    close $cin;
    my $out = do { local $/; <$cout> };
    close $cout;
    waitpid $pid, 0;
    return eval { decode_json($out) } // { _raw => $out };
}

sub stored_hash {
    my ( $docroot, $user ) = @_;
    open my $fh, '<', "$docroot/lazysite/auth/users" or return;
    while (<$fh>) {
        chomp;
        my ( $u, $h ) = split /:/, $_, 2;
        return $h if $u eq $user;
    }
    return;
}

# --- API token shape ---------------------------------------------------
{
    my $d = fresh_docroot();
    cli( $d, 'add', 'deploy', 'pw' );

    my $r = api( $d, { action => 'token', username => 'deploy' } );
    is( $r->{ok}, 1, 'token action ok' );
    like( $r->{token}, qr/^lzs_[0-9a-f]{64}$/, 'token is lzs_ + 64 hex chars' );
}

# --- stored as single-iteration sha256iter, and it verifies -----------
{
    my $d = fresh_docroot();
    cli( $d, 'add', 'deploy', 'pw' );
    my $r = api( $d, { action => 'token', username => 'deploy' } );
    my $token = $r->{token};

    my $h = stored_hash( $d, 'deploy' );
    like( $h, qr/^sha256iter:[0-9a-f]{32}:1:[0-9a-f]{64}$/,
        'stored hash uses iterations=1' );

    my ( $salt, $iters, $expect ) = $h =~ /^sha256iter:([0-9a-f]+):(\d+):([0-9a-f]+)$/;
    is( $iters, 1, 'iteration count is exactly 1' );
    is( sha256_hex( $salt . $token ), $expect,
        'single-round hash of the token reproduces the stored digest' );
}

# --- regenerating yields a different credential -----------------------
{
    my $d = fresh_docroot();
    cli( $d, 'add', 'deploy', 'pw' );
    my $t1 = api( $d, { action => 'token', username => 'deploy' } )->{token};
    my $h1 = stored_hash( $d, 'deploy' );
    my $t2 = api( $d, { action => 'token', username => 'deploy' } )->{token};
    my $h2 = stored_hash( $d, 'deploy' );

    isnt( $t1, $t2, 'two generations produce different tokens' );
    isnt( $h1, $h2, 'and different stored hashes (old credential invalidated)' );
}

# --- plaintext never lands on disk ------------------------------------
{
    my $d = fresh_docroot();
    cli( $d, 'add', 'deploy', 'pw' );
    my $token = api( $d, { action => 'token', username => 'deploy' } )->{token};

    my $hit = 0;
    for my $f ( "$d/lazysite/auth/users",
                "$d/lazysite/auth/user-settings.json" ) {
        next unless -f $f;
        open my $fh, '<', $f or next;
        my $body = do { local $/; <$fh> };
        close $fh;
        $hit++ if index( $body, $token ) >= 0;
    }
    is( $hit, 0, 'plaintext token absent from on-disk auth files' );
}

# --- token for a missing user fails -----------------------------------
{
    my $d = fresh_docroot();
    my $r = api( $d, { action => 'token', username => 'ghost' } );
    is( $r->{ok}, 0, 'token for unknown user rejected' );
}

done_testing();
