#!/usr/bin/perl
# SM074: per-file ACLs in the manager API, central store + actions. An
# author claims a file with acl-set (becoming its owner); thereafter a
# non-operator, non-owner is denied write, the owner is allowed, and an
# operator (manager group) bypasses. The acl-set action itself is gated
# the same way.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use IPC::Open3;
use Symbol qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root   = repo_root();
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'sekret' x 6;

sub mapi {
    my ( $d, %o ) = @_;
    my $body = delete $o{body};
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}  = $d;
    $ENV{REQUEST_METHOD} = $o{REQUEST_METHOD} || 'GET';
    $ENV{CONTENT_LENGTH} = defined $body ? length($body) : 0;
    delete $ENV{HTTP_X_REMOTE_USER};
    delete $ENV{HTTP_X_REMOTE_GROUPS};
    $ENV{$_} = $o{$_} for grep { defined $o{$_} } keys %o;
    my ( $w, $r ); my $e = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    print $w ( defined $body ? $body : '' ); close $w;
    my $out = do { local $/; <$r> }; close $r;
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}
sub csrf { hmac_sha256_hex( "csrf:$_[0]:" . int( time() / 3600 ), $secret ) }

sub post {
    my ( $d, $user, $groups, $qs, $body ) = @_;
    return mapi( $d,
        REQUEST_METHOD       => 'POST',
        HTTP_X_REMOTE_USER   => $user,
        HTTP_X_REMOTE_GROUPS => $groups,
        HTTP_X_CSRF_TOKEN    => csrf($user),
        QUERY_STRING         => $qs,
        body                 => encode_json($body),
    );
}
sub save_as { post( $_[0], $_[1], $_[2], "action=save&path=$_[3]", { content => $_[4], mtime => undef } ) }
sub aclset  { post( $_[0], $_[1], $_[2], "action=acl-set&path=$_[3]", $_[4] ) }

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
make_path("$d/content");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "manager_groups: managers\n";
close $cf;
open my $sf, '>', "$d/lazysite/auth/.secret" or die $!; print $sf $secret; close $sf;
open my $xf, '>', "$d/content/x.md" or die $!; print $xf "orig\n"; close $xf;

# --- alice (not an operator) claims content/x.md, write-restricted -------
my $claim = aclset( $d, 'alice', 'authors', '/content/x.md', { write => ['alice'] } );
ok( $claim->{ok}, 'alice claims the file via acl-set' );
is( $claim->{acl}{owner}, 'alice', 'owner recorded as the claiming user' );

# --- enforcement on save -------------------------------------------------
ok( !save_as( $d, 'bob',   'authors',  '/content/x.md', 'bob' )->{ok},
    'non-operator non-owner write denied' );
ok(  save_as( $d, 'alice', 'authors',  '/content/x.md', 'alice-edit' )->{ok},
    'owner may write her own file' );
ok(  save_as( $d, 'admin', 'managers', '/content/x.md', 'op-edit' )->{ok},
    'operator (manager group) bypasses the ACL' );

# --- only the owner / an operator may change the ACL ---------------------
ok( !aclset( $d, 'bob',   'authors',  '/content/x.md', { write => ['bob'] } )->{ok},
    'non-owner cannot change the ACL' );
ok(  aclset( $d, 'admin', 'managers', '/content/x.md', { write => ['alice','bob'] } )->{ok},
    'operator may change the ACL' );

# after the operator added bob to the write list, bob may now save
ok( save_as( $d, 'bob', 'authors', '/content/x.md', 'bob-now' )->{ok},
    'a newly listed user may write' );

# --- SM077: @group ACL entry - a group member may write ------------------
ok( aclset( $d, 'admin', 'managers', '/content/x.md', { write => ['@editors'] } )->{ok},
    'operator sets a @group write entry' );
ok( save_as( $d, 'carol', 'editors', '/content/x.md', 'carol-grp' )->{ok},
    '@group: a member of @editors may write (X-Remote-Groups)' );
ok( !save_as( $d, 'dave', 'authors', '/content/x.md', 'dave-no' )->{ok},
    '@group: a non-member is denied' );

# --- SM077: move re-keys the ACL, and the listing surfaces it ------------
my $mv = post( $d, 'admin', 'managers',
    'action=move&path=/content/x.md&to=/content/moved.md', {} );
ok( $mv->{ok}, 'operator moves the file' );
ok( -f "$d/content/moved.md" && !-e "$d/content/x.md", 'file moved on disk' );

my $list = mapi( $d,
    REQUEST_METHOD       => 'GET',
    HTTP_X_REMOTE_USER   => 'admin',
    HTTP_X_REMOTE_GROUPS => 'managers',
    QUERY_STRING         => 'action=list&path=/content',
);
my ($entry) = grep { $_->{name} eq 'moved.md' } @{ $list->{entries} || [] };
ok( $entry, 'moved.md is listed at the new path' );
is( $entry->{owner}, 'alice', 'ACL re-keyed: owner preserved + surfaced in the listing' );
is_deeply( $entry->{write}, ['@editors'], 'listing surfaces the @group write list' );

done_testing();
