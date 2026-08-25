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
use JSON::PP   qw(encode_json);
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
    is( $r->{ok},     0,     'manager cannot acquire over a DAV lock' );
    is( $r->{locked}, 1,     'reported as locked' );
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
    is( $info->{origin},    'dav',    'lock info carries dav origin' );
    is( $info->{active},    1,        'lock reported active' );
    is( $info->{locked_by}, 'deploy', 'lock owner reported' );
}

# --- legacy single-line manager lock still works ----------------------
{
    write_lock_file( 'content/legacy.md', 'alice ' . time() );
    my $info = main::_get_lock_info('content/legacy.md');
    is( $info->{origin},    'manager', 'legacy line read as manager origin' );
    is( $info->{locked_by}, 'alice',   'legacy owner parsed' );

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
    like( $raw, qr/^\{/,                'manager now writes JSON lock records' );
    like( $raw, qr/"origin":"manager"/, 'with origin=manager' );

    my $r2 = main::acquire_lock( 'content/mine.md', 'carol' );
    is( $r2->{ok}, 1, 'owner can refresh their own manager lock' );
}

# --- a DAV lock blocks a manager SAVE, not just acquire ---------------
# Regression: action_save used to parse the lock as the legacy "user
# epoch" line, so a (spaceless) JSON / DAV lock record slipped through
# and a save could clobber a WebDAV-locked file.
{
    my $r = main::action_save( 'content/p.md', 'editor', "new body\n", undef );
    is( $r->{ok},     0, 'manager save refused while a DAV lock is held' );
    is( $r->{locked}, 1, 'save reports the lock' );
    like( $r->{error}, qr/WebDAV/, 'error names the WebDAV lock' );
}

# --- a manager lock blocks a different user, allows the owner ---------
{
    # carol holds content/mine.md from the refresh block above.
    my $blocked = main::action_save( 'content/mine.md', 'dave', "x\n", undef );
    is( $blocked->{ok}, 0, "another user cannot save over carol's lock" );

    my $owner = main::action_save( 'content/mine.md', 'carol', "ok\n", undef );
    is( $owner->{ok}, 1, 'the lock owner can save their own locked file' );
}

# --- SM527: the lock is keyed by the canonical path, not the spelling ---
# A lock taken as content/q.md was invisible to a save spelled /content/q.md,
# ./content/q.md or content//q.md: each spelling minted its own key, so MCP
# (/slug.md) and the API (the path as typed) never saw each other's locks,
# and the listing's glyph never showed a lock taken as content/q.md.
{
    my $r = main::acquire_lock( 'content/q.md', 'erin' );
    is( $r->{ok}, 1, 'erin locks content/q.md' );
    for my $spelling ( '/content/q.md', './content/q.md', 'content//q.md' ) {
        my $s = main::action_save( $spelling, 'frank', "x\n", undef );
        is( $s->{ok}, 0,
            "a lock taken as content/q.md refuses a save spelled $spelling" );
        is( $s->{locked}, 1, "and $spelling reports the lock" );
    }
    my $info = main::_get_lock_info('/content/q.md');
    is( $info->{locked_by}, 'erin',
        'lock info asked as /content/q.md finds the same lock' );

    my $first = main::action_save( 'content/q.md', 'erin', "first\n", undef );
    is( $first->{ok}, 1, 'the owner writes the page, which releases the lock' );
    is( main::acquire_lock( 'content/q.md', 'erin' )->{ok}, 1,
        'and locks it again, now that the file exists to be listed' );
    my $list = main::action_list('/content');
    my ($e) = grep { $_->{name} eq 'q.md' } @{ $list->{entries} || [] };
    is( ( $e && $e->{lock} ? $e->{lock}{locked_by} : undef ),
        'erin', 'the listing shows the lock taken as content/q.md' );

    my $own = main::action_save( '/content/q.md', 'erin', "mine\n", undef );
    is( $own->{ok}, 1, 'the owner saves under another spelling' );
    ok( !lock_exists('content/q.md'), 'and the save released the one lock' );
}

done_testing();
