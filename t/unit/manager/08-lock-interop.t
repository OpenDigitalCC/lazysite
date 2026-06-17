#!/usr/bin/perl
# SM070: the manager API and lazysite-dav.pl share one lock store. The
# manager must read the JSON lock record and honour WebDAV-origin locks
# (refuse to acquire over them, refuse to release them), while still
# accepting legacy single-line manager locks.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(encode_json);
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/manager/locks");

BEGIN { $ENV{LAZYSITE_API_LOAD_ONLY} = 1 }
$ENV{DOCUMENT_ROOT} = $docroot;

my $root = repo_root();
{ package main; do "$root/lazysite-manager-api.pl" or die "load failed: $@" }

my $LOCKS = "$docroot/lazysite/manager/locks";
sub write_lock_file {
    my ( $rel, $content ) = @_;
    ( my $key = $rel ) =~ s{/}{:}g;
    open my $fh, '>', "$LOCKS/$key.lock" or die;
    print $fh $content;
    close $fh;
}
sub lock_exists {
    my ($rel) = @_;
    ( my $key = $rel ) =~ s{/}{:}g;
    return -f "$LOCKS/$key.lock";
}

# --- manager refuses to acquire over a fresh DAV lock -----------------
{
    write_lock_file( 'content/p.md', encode_json(
        { user => 'deploy', at => time(), origin => 'dav',
          token => 'opaquelocktoken:abc', timeout => 3600, owner => '' } ) );

    my $r = main::acquire_lock( 'content/p.md', 'editor' );
    is( $r->{ok}, 0, 'manager cannot acquire over a DAV lock' );
    is( $r->{locked}, 1, 'reported as locked' );
    is( $r->{origin}, 'dav', 'origin surfaced as dav' );
}

# --- manager refuses to release a DAV lock ----------------------------
{
    my $r = main::release_lock( 'content/p.md', 'editor' );
    is( $r->{ok}, 0, 'manager will not release a live DAV lock' );
    ok( lock_exists('content/p.md'), 'DAV lock left intact' );
}

# --- _get_lock_info reports origin and active -------------------------
{
    my $info = main::_get_lock_info('content/p.md');
    is( $info->{origin}, 'dav', 'lock info carries dav origin' );
    is( $info->{active}, 1, 'lock reported active' );
    is( $info->{locked_by}, 'deploy', 'lock owner reported' );
}

# --- legacy single-line manager lock still works ----------------------
{
    write_lock_file( 'content/legacy.md', 'alice ' . time() );
    my $info = main::_get_lock_info('content/legacy.md');
    is( $info->{origin}, 'manager', 'legacy line read as manager origin' );
    is( $info->{locked_by}, 'alice', 'legacy owner parsed' );

    # Another manager user is still blocked by a legacy lock.
    my $r = main::acquire_lock( 'content/legacy.md', 'bob' );
    is( $r->{ok}, 0, 'legacy manager lock blocks a different user' );
}

# --- a manager user can refresh their own lock; writes JSON now -------
{
    my $r1 = main::acquire_lock( 'content/mine.md', 'carol' );
    is( $r1->{ok}, 1, 'carol acquires a fresh path' );
    ( my $key = 'content/mine.md' ) =~ s{/}{:}g;
    open my $fh, '<', "$LOCKS/$key.lock" or die;
    my $raw = do { local $/; <$fh> };
    close $fh;
    like( $raw, qr/^\{/, 'manager now writes JSON lock records' );
    like( $raw, qr/"origin":"manager"/, 'with origin=manager' );

    my $r2 = main::acquire_lock( 'content/mine.md', 'carol' );
    is( $r2->{ok}, 1, 'owner can refresh their own manager lock' );
}

done_testing();
