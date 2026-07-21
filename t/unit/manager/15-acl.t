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
    # The auth wrapper sets X-Remote-* AND LAZYSITE_AUTH_TRUSTED together; a test that
    # simulates the authenticated path must do the same, or the manager-API trust
    # gate (correctly) strips the header as forged.
    $ENV{LAZYSITE_AUTH_TRUSTED} = 1 if length( $ENV{HTTP_X_REMOTE_USER} // '' );
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
sub get_as {
    mapi( $_[0], REQUEST_METHOD => 'GET', HTTP_X_REMOTE_USER => $_[1],
        HTTP_X_REMOTE_GROUPS => $_[2], QUERY_STRING => $_[3] );
}

# Raw GET (download surfaces stream file bytes, not JSON) - return the whole
# response so a test can assert the protected content is or is not present.
sub get_raw {
    my ( $d, $user, $groups, $qs ) = @_;
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}         = $d;
    $ENV{REQUEST_METHOD}        = 'GET';
    $ENV{CONTENT_LENGTH}        = 0;
    $ENV{HTTP_X_REMOTE_USER}    = $user;
    $ENV{HTTP_X_REMOTE_GROUPS}  = $groups;
    $ENV{LAZYSITE_AUTH_TRUSTED} = 1;
    $ENV{QUERY_STRING}          = $qs;
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    close $w;
    my $out = do { local $/; <$r> };
    close $r;
    waitpid $pid, 0;
    return $out // '';
}

# Parse a zip-download response body and return its member names (a zip is
# compressed, so a plaintext regex on the bytes cannot tell if a file is inside).
sub zip_members {
    my ($raw) = @_;
    my ($body) = $raw =~ /\r?\n\r?\n(.*)/s;
    return () unless defined $body && length $body;
    require Archive::Zip;
    require File::Temp;
    my ( $fh, $tmp ) = File::Temp::tempfile( UNLINK => 1 );
    binmode $fh;
    print $fh $body;
    close $fh;
    my $zip = Archive::Zip->new();
    return ( $zip->read($tmp) == 0 ) ? $zip->memberNames() : ();
}

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
make_path("$d/content");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "site_name: T\n";
close $cf;
# SM138: a group granting manager access secures the site (replaces the
# retired conf manager_groups key); 'managers' members are operators.
open my $gsf, '>', "$d/lazysite/auth/groups-settings.json" or die $!;
print $gsf '{"managers":{"label":"Managers","ui":1,"manage_users":1}}';
close $gsf;
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

# --- F2 (2026-07 audit): READ ACL also enforced on download / zip-download -----
# The download surfaces skipped the read ACL that `read` enforces, so a
# non-operator could grab a file restricted away from them. A read-restricted
# file is now unreachable by all three surfaces for a denied user.
open my $secf, '>', "$d/content/secret.md" or die $!;
print $secf "TOP-SECRET-CONTENT\n";
close $secf;
ok( aclset( $d, 'admin', 'managers', '/content/secret.md',
        { read => ['alice'], write => ['alice'], owner => 'alice' } )->{ok},
    'operator restricts READ of secret.md to alice' );

ok( !get_as( $d, 'bob', 'authors', 'action=read&path=/content/secret.md' )->{ok},
    'bob is denied by read (baseline)' );
unlike( get_raw( $d, 'bob', 'authors', 'action=file-download&path=/content/secret.md' ),
    qr/TOP-SECRET-CONTENT/, 'bob cannot file-download a read-restricted file (F2)' );
my @bob_zip = zip_members( get_raw( $d, 'bob', 'authors',
    'action=file-zip-download&paths=/content/secret.md' ) );
ok( !( grep {m{secret\.md}} @bob_zip ),
    'bob\'s zip excludes the read-restricted file (F2)' ) or diag "members: @bob_zip";
my @alice_zip = zip_members( get_raw( $d, 'alice', 'authors',
    'action=file-zip-download&paths=/content/secret.md' ) );
ok( ( grep {m{secret\.md}} @alice_zip ),
    'alice\'s zip includes it (she may read it)' );

like( get_raw( $d, 'alice', 'authors', 'action=file-download&path=/content/secret.md' ),
    qr/TOP-SECRET-CONTENT/, 'alice (read-allowed) can still download it' );
like( get_raw( $d, 'admin', 'managers', 'action=file-download&path=/content/secret.md' ),
    qr/TOP-SECRET-CONTENT/, 'operator can still download it' );

done_testing();
