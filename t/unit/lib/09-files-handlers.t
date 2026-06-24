#!/usr/bin/perl
# SM079a coverage: in-process tests for Manager::Files action handlers. Covers
# both the operator happy paths AND the non-operator deny paths + lock
# contention (which the operator-only context would otherwise mask).
use strict;
use warnings;
use Test::More;
use JSON::PP qw(encode_json);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Files
    qw(action_list action_mkdir action_delete action_move action_acl_set action_acl_remove
       acquire_lock renew_lock release_lock);
use Lazysite::Manager::Common ();
use Lazysite::Auth::Acl qw(load_acls);

my $d = tempdir( CLEANUP => 1 );
my $LOCKS = "$d/lazysite/manager/locks";
make_path( "$d/content", "$d/lazysite/auth", $LOCKS );
$Lazysite::Manager::Files::DOCROOT   = $d;
$Lazysite::Manager::Files::LOCK_DIR  = $LOCKS;
$Lazysite::Manager::Files::auth_user = 'alice';
$Lazysite::Manager::Files::action    = 'test';
$Lazysite::Manager::Common::DOCROOT  = $d;
$Lazysite::Auth::Acl::DOCROOT             = $d;
$Lazysite::Auth::Acl::auth_user           = 'alice';
$Lazysite::Auth::Acl::token_auth          = 0;
$Lazysite::Auth::Acl::manager_groups_conf = '';    # operator for the happy paths

# --- mkdir (assert the rejection reason, not just falsiness) ---
ok( action_mkdir('content/sub')->{ok}, 'mkdir creates a directory' );
ok( -d "$d/content/sub", 'directory exists on disk' );
my $mk = action_mkdir('../escape');
ok( !$mk->{ok}, 'traversal mkdir rejected' );
like( $mk->{error}, qr/Invalid path/, 'rejected specifically as an invalid path' );

# --- delete + blocked reason ---
open my $f, '>', "$d/content/x.md" or die $!;
print {$f} 'hi'; close $f;
ok( action_delete( 'content/x.md', 'alice' )->{ok}, 'delete a file' );
ok( !-f "$d/content/x.md", 'file removed' );
my $bd = action_delete( 'lazysite/auth/users', 'alice' );
ok( !$bd->{ok}, 'delete of a blocked path refused' );
like( $bd->{error}, qr/block/i, 'refused with a "blocked" reason' );

# --- acl-set ACTUALLY stores the record (operator) ---
my $set = action_acl_set( 'content/secret.md', 'alice', undef, ['alice'], 'alice' );
ok( $set->{ok}, 'acl-set succeeds' );
is( $set->{acl}{owner}, 'alice', 'returned owner is correct' );
is_deeply( $set->{acl}{write}, ['alice'], 'returned write-list is correct' );
ok( !exists $set->{acl}{read}, 'undef read is omitted (not stored empty)' );
is_deeply( load_acls()->{'content/secret.md'}, { owner => 'alice', write => ['alice'] },
    'ACL is persisted to acls.json byte-for-byte' );

# --- NON-OPERATOR deny paths (H1: the security-relevant logic) ---
{
    local $Lazysite::Auth::Acl::manager_groups_conf = 'managers';
    local $Lazysite::Auth::Acl::auth_user           = 'eve';   # not operator, not owner
    local $Lazysite::Manager::Files::auth_user      = 'eve';
    open my $sf, '>', "$d/content/secret.md" or die $!;
    print {$sf} 'secret'; close $sf;

    my $r = action_acl_set( 'content/secret.md', 'eve', undef, ['eve'], 'eve' );
    ok( !$r->{ok}, 'non-owner cannot rewrite an existing ACL' );
    like( $r->{error}, qr/owner/i, 'refused: only the owner may change permissions' );

    my $del = action_delete( 'content/secret.md', 'eve' );
    ok( !$del->{ok}, 'non-owner cannot delete an ACL-protected file' );
    like( $del->{error}, qr/access/i, 'refused via the per-file ACL write gate' );
    ok( -f "$d/content/secret.md", 'the protected file is untouched' );

    my $rm = action_acl_remove( 'content/secret.md', 'eve' );
    ok( !$rm->{ok}, 'non-owner cannot remove the ACL' );
}

# back to operator: acl-remove works + clears the store
ok( action_acl_remove( 'content/secret.md', 'alice' )->{ok}, 'owner removes the ACL' );
ok( !exists load_acls()->{'content/secret.md'}, 'ACL gone from the store' );
my $rem2 = action_acl_remove( 'content/none.md', 'alice' );
ok( $rem2->{ok} && !$rem2->{removed}, 'remove of an unset path is a no-op' );

# --- lock contention (H3) ---
ok( acquire_lock( 'content/z.md', 'alice' )->{ok}, 'alice acquires a lock' );
my $contend = acquire_lock( 'content/z.md', 'bob' );
ok( !$contend->{ok} && $contend->{locked}, "bob is blocked by alice's lock" );
is( $contend->{locked_by}, 'alice', 'contention reports the holder' );
ok( renew_lock( 'content/z.md', 'alice' )->{ok}, 'owner may renew their own lock' );

# a live WebDAV lock must never be released by the manager
_write_dav_lock( 'content:dav.md.lock', 'davclient' );
my $rel = release_lock( 'content/dav.md', 'alice' );
ok( !$rel->{ok}, 'manager refuses to release a live WebDAV lock' );
like( $rel->{error}, qr/WebDAV/i, 'refused: locked via WebDAV' );

sub _write_dav_lock {
    my ( $name, $user ) = @_;
    open my $lf, '>', "$LOCKS/$name" or die $!;
    print {$lf} encode_json( { user => $user, at => time(), origin => 'dav', timeout => 300 } );
    close $lf;
}

# --- action_move (rename/move + .brief + ACL re-key) ---
open my $of, '>', "$d/content/orig.md" or die $!;       print {$of} 'body'; close $of;
open my $ob, '>', "$d/content/orig.md.brief" or die $!; print {$ob} 'why';  close $ob;
action_acl_set( 'content/orig.md', 'alice', undef, ['alice'], 'alice' );
my $mv = action_move( 'content/orig.md', 'content/renamed.md', 'alice' );
ok( $mv->{ok}, 'move succeeds' );
ok( -f "$d/content/renamed.md" && !-e "$d/content/orig.md", 'file moved' );
ok( -f "$d/content/renamed.md.brief" && !-e "$d/content/orig.md.brief", '.brief sidecar moved' );
my $acls = load_acls();
ok( exists $acls->{'content/renamed.md'} && !exists $acls->{'content/orig.md'},
    'ACL entry re-keyed to the new path' );

open my $tk, '>', "$d/content/taken.md" or die $!; print {$tk} 'x'; close $tk;
ok( !action_move( 'content/renamed.md', 'content/taken.md', 'alice' )->{ok},
    'move onto an existing target is refused' );
ok( !action_move( 'content/renamed.md', 'lazysite/auth/users', 'alice' )->{ok},
    'move to a blocked path is refused' );
ok( !action_move( 'content/missing.md', 'content/x.md', 'alice' )->{ok},
    'move of a missing source is refused' );

# --- action_list surfaces ACL read/write + lock state (SM077) ---
open my $sh, '>', "$d/content/shared.md" or die $!; print {$sh} 'x'; close $sh;
action_acl_set( 'content/shared.md', 'alice', ['bob'], ['alice'], 'alice' );
acquire_lock( '/content/shared.md', 'alice' );   # leading slash, as the dispatch passes it
my ($e) = grep { $_->{name} eq 'shared.md' }
    @{ action_list('/content')->{entries} };
ok( $e, 'shared.md is listed' );
is( $e->{owner}, 'alice',           'list surfaces owner' );
is_deeply( $e->{read},  ['bob'],    'list surfaces the read list' );
is_deeply( $e->{write}, ['alice'],  'list surfaces the write list' );
ok( $e->{lock} && $e->{lock}{locked_by} eq 'alice', 'list surfaces the lock holder' );

done_testing();
