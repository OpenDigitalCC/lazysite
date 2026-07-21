#!/usr/bin/perl
# F3 (2026-07 audit): the account/group roster (action=principals) leaked to any
# authenticated user - username enumeration aids credential attacks. It backs the
# ACL "grant to whom" picker (Files, manage_content) and the domain-groups picker
# (Domains, manage_domains), so it is now gated on manage_content OR
# manage_domains. A ui-only user is denied; a holder of either cap - and an
# operator - may read it.
use strict;
use warnings;
use Test::More;
use File::Temp   qw(tempdir);
use File::Path   qw(make_path);
use JSON::PP     qw(encode_json decode_json);
use IPC::Open2   qw(open2);
use IPC::Open3   qw(open3);
use Symbol       qw(gensym);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root  = repo_root();
my $utool = "$root/tools/lazysite-users.pl";
my $mapi  = "$root/lazysite-manager-api.pl";

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "site_name: T\n";
close $cf;
# 'managers' is the operator group (manage_users); seed it so _is_operator has a
# manager group to recognise.
open my $gs, '>', "$d/lazysite/auth/groups-settings.json" or die $!;
print $gs '{"managers":{"label":"M","ui":1,"manage_users":1}}';
close $gs;
open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
print $sf 'sekret' x 6;
close $sf;

# Set up REAL users + group membership + group caps via the tool (caps resolve
# from actual membership, not the request headers - SEC-2026-07 M5).
sub uapi {
    my ($p) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, $utool, '--api', '--docroot', $d );
    print $i encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    close $o;
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}
for my $spec (
    [ 'ed',   'editors',   'manage_content' ],
    [ 'dom',  'domainers', 'manage_domains' ],
    [ 'vic',  'viewers',   'ui' ],
    [ 'boss', 'managers',  undef ],
    )
{
    my ( $user, $group, $cap ) = @$spec;
    uapi( { action => 'add', username => $user, password => 'pw' } );
    uapi( { action => 'group-add', username => $user, group => $group } );
    uapi( { action => 'group-settings-set', group => $group, key => $cap, value => 'on' } )
        if $cap;
}

# Drive action=principals as a given cookie user.
sub principals {
    my ( $user, $groups ) = @_;
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}         = $d;
    $ENV{REQUEST_METHOD}        = 'GET';
    $ENV{CONTENT_LENGTH}        = 0;
    $ENV{HTTP_X_REMOTE_USER}    = $user;
    $ENV{HTTP_X_REMOTE_GROUPS}  = $groups // '';
    $ENV{LAZYSITE_AUTH_TRUSTED} = 1;
    $ENV{QUERY_STRING}          = 'action=principals';
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, $mapi );
    close $w;
    my $out = do { local $/; <$r> };
    close $r;
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // {};
}

my $vic = principals( 'vic', 'viewers' );
ok( !$vic->{ok}, 'a ui-only user is DENIED the account/group roster (F3)' );
like( $vic->{error} // '', qr/manage_content or manage_domains/,
    'the denial names the required capability' );

ok( principals( 'ed', 'editors' )->{ok},
    'a manage_content user may read the roster (ACL picker)' );
ok( principals( 'dom', 'domainers' )->{ok},
    'a manage_domains user may read the roster (domain-groups picker)' );

my $boss = principals( 'boss', 'managers' );
ok( $boss->{ok}, 'an operator may read the roster' );
ok( ref $boss->{users} eq 'ARRAY' && ref $boss->{groups} eq 'ARRAY',
    'the roster carries users + groups for an allowed caller' );

done_testing();
