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
    qw(action_list action_save action_mkdir action_delete action_move action_copy action_migrate_to_local
       action_aliases_list action_acl_set action_acl_remove acquire_lock renew_lock release_lock);
use Lazysite::Aliases qw(lookup);
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
    # SM138: secure the site (a group grants manager access), so eve - in no
    # group - is not an operator. Replaces the retired manager_groups_conf var.
    open my $gsf, '>', "$d/lazysite/auth/groups-settings.json" or die $!;
    print {$gsf} '{"managers":{"label":"Managers","ui":1,"manage_users":1}}';
    close $gsf;
    local $Lazysite::Auth::Acl::auth_user      = 'eve';   # not operator, not owner
    local $Lazysite::Manager::Files::auth_user = 'eve';
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
    unlink "$d/lazysite/auth/groups-settings.json";    # back to unsecured/operator
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

# --- action_copy (duplicate: source kept, fresh owner, no cache copy) ---
open my $cf, '>', "$d/content/src.md" or die $!;       print {$cf} 'dup me'; close $cf;
open my $cb, '>', "$d/content/src.md.brief" or die $!; print {$cb} 'why';   close $cb;
open my $ch, '>', "$d/content/src.html" or die $!;     print {$ch} '<cache>'; close $ch;
action_acl_set( 'content/src.md', 'alice', ['bob'], ['alice'], 'alice' );
my $cp = action_copy( 'content/src.md', 'content/dup.md', 'carol' );
ok( $cp->{ok}, 'copy succeeds' );
ok( -f "$d/content/src.md" && -f "$d/content/dup.md", 'source kept, duplicate created' );
is( do { open my $f, '<', "$d/content/dup.md"; local $/; <$f> }, 'dup me',
    'duplicate has the source content' );
ok( -f "$d/content/dup.md.brief", '.brief sidecar copied' );
ok( !-e "$d/content/dup.html", 'generated .html cache is NOT copied (re-renders)' );
my $ca = load_acls();
is( $ca->{'content/dup.md'}{owner}, 'carol', 'duplicate is owned by its creator, not the source owner' );
ok( !$ca->{'content/dup.md'}{read}, 'duplicate does not inherit the source read list' );

ok( !action_copy( 'content/src.md', 'content/dup.md', 'carol' )->{ok},
    'copy onto an existing target is refused' );
ok( !action_copy( 'content/src.md', 'lazysite/auth/users', 'carol' )->{ok},
    'copy to a blocked path is refused' );
ok( !action_copy( 'content/missing.md', 'content/y.md', 'carol' )->{ok},
    'copy of a missing source is refused' );

# --- action_migrate_to_local (.url -> local .md via the guarded fetch) -------
# Mock the shared fetch so there is no live-network dependency.
require Lazysite::Fetch;
{ no warnings qw(redefine once);
  *Lazysite::Fetch::fetch_url = sub { "# Migrated\n\nremote body from $_[0]\n" }; }

open my $uf, '>', "$d/content/remote.url"        or die $!; print {$uf} 'https://example.com/page'; close $uf;
open my $ub, '>', "$d/content/remote.url.brief"  or die $!; print {$ub} 'why';                     close $ub;
action_acl_set( 'content/remote.url', 'alice', ['bob'], ['alice'], 'alice' );

my $mig = action_migrate_to_local( 'content/remote.url', 'alice' );
ok( $mig->{ok}, 'migrate succeeds' );
ok( -f "$d/content/remote.md" && !-e "$d/content/remote.url", '.md created, .url removed' );
like( do { open my $f, '<', "$d/content/remote.md"; local $/; <$f> }, qr/remote body from/,
    '.md holds the fetched content' );
ok( -f "$d/content/remote.md.brief", '.brief sidecar carried over' );
my $ma = load_acls();
ok( exists $ma->{'content/remote.md'} && !exists $ma->{'content/remote.url'},
    'ACL entry re-keyed from .url to .md (ownership carried)' );

ok( !action_migrate_to_local( 'content/src.md', 'alice' )->{ok},
    'migrate of a non-.url file is refused' );

# A fetch failure must leave the .url intact and write no .md.
{ no warnings qw(redefine once); *Lazysite::Fetch::fetch_url = sub { undef }; }
open my $u2, '>', "$d/content/dead.url" or die $!; print {$u2} 'https://example.com/gone'; close $u2;
my $fail = action_migrate_to_local( 'content/dead.url', 'alice' );
ok( !$fail->{ok} && -f "$d/content/dead.url" && !-e "$d/content/dead.md",
    'fetch failure leaves the .url intact and writes no .md' );

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

# --- SM134: saving/deleting a page maintains the alias-redirect map ---
{
    my $md = "---\ntitle: Pricing\naliases:\n  - /old-pricing\n---\n\nPrices.\n";
    ok( action_save( 'content/pricing.md', 'alice', $md )->{ok}, 'page with aliases saved' );
    is( lookup( $d, '/old-pricing' ), '/content/pricing',
        'action_save indexed the alias (SM134 hook)' );

    ok( action_delete('content/pricing.md')->{ok}, 'aliased page deleted' );
    is( lookup( $d, '/old-pricing' ), undef,
        'action_delete cleared the alias (SM134 hook)' );
}

# --- SM134 follow-ups: move/copy re-key the alias map without a save ---------
{
    my $md = "---\ntitle: Guide\naliases:\n  - /old-guide\naliases_temp:\n  - /guide-preview\n---\n\nG.\n";
    ok( action_save( 'content/guide.md', 'alice', $md )->{ok}, 'aliased page saved' );
    is( lookup( $d, '/old-guide' ), '/content/guide', 'alias targets the original path' );

    # rename via the manager action: the alias follows, no save needed
    ok( action_move( 'content/guide.md', 'content/handbook.md', 'alice' )->{ok},
        'aliased page moved' );
    is( lookup( $d, '/old-guide' ), '/content/handbook',
        'action_move re-keyed the 301 alias to the new target' );
    is( lookup( $d, '/guide-preview' ), '/content/handbook',
        'action_move re-keyed the 302 alias too' );

    # duplicate: the copy carries the alias list, so it takes the aliases
    # (last-writer-wins, same as a save)
    ok( action_copy( 'content/handbook.md', 'content/handbook-v2.md', 'alice' )->{ok},
        'aliased page copied' );
    is( lookup( $d, '/old-guide' ), '/content/handbook-v2',
        'action_copy indexed the duplicate (last writer wins)' );
}

# --- SM134 follow-ups: migrate-to-local indexes the fetched page's aliases ---
{
    no warnings qw(redefine once);
    local *Lazysite::Fetch::fetch_url =
        sub { "---\ntitle: R\naliases:\n  - /moved-in\n---\n\nbody\n" };
    open my $u3, '>', "$d/content/incoming.url" or die $!;
    print {$u3} 'https://example.com/incoming';
    close $u3;
    ok( action_migrate_to_local( 'content/incoming.url', 'alice' )->{ok},
        'aliased .url migrated' );
    is( lookup( $d, '/moved-in' ), '/content/incoming',
        'migrate-to-local indexed the fetched aliases' );
}

# --- SM134 follow-ups: action_aliases_list returns the map rows --------------
{
    my $r = action_aliases_list();
    ok( $r->{ok}, 'aliases-list ok' );
    my %by_alias = map { $_->{alias} => $_ } @{ $r->{aliases} };
    is( $by_alias{'/old-guide'}{target}, '/content/handbook-v2',
        'aliases-list row carries the target' );
    is( $by_alias{'/old-guide'}{code}, 301, 'permanent row reports 301' );
    is( $by_alias{'/guide-preview'}{code}, 302, 'temporary row reports 302' );
}

done_testing();
