#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use JSON::PP qw(encode_json decode_json);
use IPC::Open2;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root    = repo_root();
my $script  = "$root/tools/lazysite-users.pl";
my $docroot = tempdir( CLEANUP => 1 );

ok( -f $script, 'tools/lazysite-users.pl present' );

sub api {
    my ($payload) = @_;
    my $json = encode_json($payload);
    my ( $cout, $cin );
    my $pid = open2( $cout, $cin, $^X, $script, '--api', '--docroot', $docroot );
    print $cin $json;
    close $cin;
    my $out = do { local $/; <$cout> };
    close $cout;
    waitpid $pid, 0;
    return eval { decode_json($out) } // { _raw => $out };
}

# --- add via API ---
{
    my $r = api({ action => 'add', username => 'alice', password => 'pass123' });
    is( $r->{ok}, 1, 'API add ok' );
    like( $r->{message} // '', qr/added/i, 'message reflects add' );
}

# --- list via API ---
{
    my $r = api({ action => 'list' });
    is( $r->{ok}, 1, 'API list ok' );
    ok( ref $r->{users} eq 'ARRAY', 'users is array' );
    ok( ( grep { $_ eq 'alice' } @{ $r->{users} } ), 'alice in list' );
}

# --- passwd via API ---
{
    my $r = api({ action => 'passwd', username => 'alice', password => 'new' });
    is( $r->{ok}, 1, 'API passwd ok' );
}

# --- group-add via API ---
{
    my $r = api({ action => 'group-add', username => 'alice', group => 'admins' });
    is( $r->{ok}, 1, 'API group-add ok' );
}

# --- groups via API ---
{
    my $r = api({ action => 'groups' });
    is( $r->{ok}, 1, 'API groups ok' );
    ok( ref $r->{groups} eq 'HASH', 'groups is hash' );
    ok( exists $r->{groups}{admins}, 'admins group exists' );
    ok( ( grep { $_ eq 'alice' } @{ $r->{groups}{admins} || [] } ),
        'alice in admins' );
}

# --- unknown action ---
{
    my $r = api({ action => 'invalid' });
    is( $r->{ok}, 0, 'unknown action returns error' );
    like( $r->{error} // '', qr/Unknown action/, 'error message present' );
}

# --- invalid JSON input ---
{
    my ( $cout, $cin );
    my $pid = open2( $cout, $cin, $^X, $script, '--api', '--docroot', $docroot );
    print $cin "not json";
    close $cin;
    my $out = do { local $/; <$cout> };
    close $cout;
    waitpid $pid, 0;
    my $r = eval { decode_json($out) };
    ok( $r, 'response is parseable JSON even for bad input' );
    is( $r->{ok}, 0, 'bad input → ok=false' );
    like( $r->{error} // '', qr/Invalid JSON/i, 'error mentions invalid JSON' );
}

# --- remove via API ---
{
    my $r = api({ action => 'remove', username => 'alice' });
    is( $r->{ok}, 1, 'API remove ok' );
    my $r2 = api({ action => 'list' });
    ok( !( grep { $_ eq 'alice' } @{ $r2->{users} } ),
        'alice gone after remove' );
}

done_testing();
