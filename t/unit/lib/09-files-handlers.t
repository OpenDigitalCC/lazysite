#!/usr/bin/perl
# SM079a coverage: in-process tests for Manager::Files action handlers that the
# subprocess tests did not measure (delete, mkdir, acl-set/remove, renew_lock).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Manager::Files
    qw(action_mkdir action_delete action_acl_set action_acl_remove
       acquire_lock renew_lock release_lock);
use Lazysite::Manager::Common ();
use Lazysite::Auth::Acl ();

my $d = tempdir( CLEANUP => 1 );
make_path( "$d/content", "$d/lazysite/auth", "$d/lazysite/manager/locks" );
$Lazysite::Manager::Files::DOCROOT   = $d;
$Lazysite::Manager::Files::LOCK_DIR  = "$d/lazysite/manager/locks";
$Lazysite::Manager::Files::auth_user = 'alice';
$Lazysite::Manager::Files::action    = 'test';
$Lazysite::Manager::Common::DOCROOT  = $d;
$Lazysite::Auth::Acl::DOCROOT             = $d;
$Lazysite::Auth::Acl::auth_user           = 'alice';
$Lazysite::Auth::Acl::token_auth          = 0;
$Lazysite::Auth::Acl::manager_groups_conf = '';    # unsecured => operator

# --- action_mkdir ---
ok( action_mkdir('content/sub')->{ok}, 'mkdir creates a directory' );
ok( -d "$d/content/sub", 'directory exists on disk' );
ok( !action_mkdir('../escape')->{ok}, 'traversal mkdir rejected' );

# --- action_delete ---
open my $f, '>', "$d/content/x.md" or die $!;
print {$f} 'hi';
close $f;
ok( action_delete( 'content/x.md', 'alice' )->{ok}, 'delete a file' );
ok( !-f "$d/content/x.md", 'file removed' );
ok( !action_delete( 'lazysite/auth/users', 'alice' )->{ok},
    'delete of a blocked path refused' );

# --- ACL set then remove ---
my $set = action_acl_set( 'content/y.md', 'alice', undef, ['bob'], 'alice' );
ok( $set->{ok}, 'acl-set as operator' );
my $rem = action_acl_remove( 'content/y.md', 'alice' );
ok( $rem->{ok}, 'acl-remove' );
my $rem2 = action_acl_remove( 'content/none.md', 'alice' );
ok( $rem2->{ok} && !$rem2->{removed}, 'acl-remove of an unset path is a no-op' );

# --- locks: acquire then renew then release ---
my $lk = acquire_lock( 'content/z.md', 'alice' );
ok( $lk->{ok}, 'lock acquired' );
ok( renew_lock( 'content/z.md', 'alice' )->{ok}, 'lock renewed by owner' );
ok( release_lock( 'content/z.md', 'alice' )->{ok}, 'lock released' );

done_testing();
