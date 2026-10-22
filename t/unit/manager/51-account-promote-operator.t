#!/usr/bin/perl
# SM194 (manager-api layer): promotion to top level and scope emancipation are
# OPERATOR-ONLY. They are omitted from %DELEGABLE, so a delegated sub-manager
# (create_sub_users, not full manage_users) is refused as `forbidden`; a real
# manage_users operator succeeds. Mirrors 40-subuser-escalation's harness.
use strict;
use warnings;
use Test::More;
use JSON::PP    qw(encode_json decode_json);
use Digest::SHA qw(hmac_sha256_hex);
use File::Path  qw(make_path);
use File::Temp  qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root grant_caps run_child);

my $root   = repo_root();
my $utool  = "$root/tools/lazysite-users.pl";
my $mapi   = "$root/lazysite-manager-api.pl";
my $secret = 'sekret' x 6;

sub uapi {
    my ( $d, $p ) = @_;
    my $out = run_child( [ $^X, $utool, '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // {};
}

sub post {
    my ( $d, $user, $groups, $sub ) = @_;
    my $body = encode_json($sub);
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}        = $d;
    $ENV{REQUEST_METHOD}       = 'POST';
    $ENV{QUERY_STRING}         = 'action=users';
    $ENV{CONTENT_LENGTH}       = length $body;
    $ENV{HTTP_X_REMOTE_USER}   = $user;
    $ENV{HTTP_X_REMOTE_GROUPS} = $groups;
    $ENV{HTTP_X_CSRF_TOKEN} = hmac_sha256_hex( "csrf:$user:" . int( time() / 3600 ), $secret );
    $ENV{LAZYSITE_AUTH_TRUSTED} = 1;
    my $out = run_child( [ $^X, $mapi ], stdin => $body )->{out};
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

sub settings { return uapi( $_[0], { action => 'settings-get', username => $_[1] } )->{settings} || {} }

# op = full manage_users; boss = create_sub_users only; sub1 is boss's child.
my $d = tempdir( CLEANUP => 1 );
make_path( "$d/lazysite/auth", "$d/lazysite/logs" );
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print $cf "site_name: T\n";
close $cf;
open my $sf, '>', "$d/lazysite/auth/.secret" or die $!;
print $sf $secret;
close $sf;

uapi( $d, { action => 'add', username => 'op',   password => 'x-long-enough' } );
uapi( $d, { action => 'add', username => 'boss', password => 'x-long-enough' } );
grant_caps( $d, 'op', 'manage_users', 'ui' );    # SM1057: uses the manager
grant_caps( $d, 'boss', 'create_sub_users' );
my $BG = 'role-boss';
my $OG = 'role-op';

# boss creates a child it legitimately manages.
uapi( $d, { action => 'account-create', username => 'sub1', password => 'x-long-enough',
        created_by => 'boss' } );

# --- delegate is REFUSED promotion + emancipation, even of its own child ------
{
    my $r = post( $d, 'boss', $BG, { action => 'account-promote', username => 'sub1' } );
    ok( !$r->{ok}, 'delegate CANNOT promote its own child to top level' )
        or diag encode_json($r);
    is( $r->{kind} // '', 'forbidden', '  ... refused as forbidden' );
    is( settings( $d, 'sub1' )->{managed_by}, 'boss',
        'refused promotion left managed_by = boss' );

    my $r2 = post( $d, 'boss', $BG,
        { action => 'account-scope-independent', username => 'sub1', value => 1 } );
    ok( !$r2->{ok}, 'delegate CANNOT emancipate a scope ceiling' )
        or diag encode_json($r2);
    is( $r2->{kind} // '', 'forbidden', '  ... refused as forbidden' );
    ok( !settings( $d, 'sub1' )->{scope_independent},
        'refused emancipation left scope_independent unset' );
}

# --- a real operator CAN promote + emancipate --------------------------------
{
    my $r = post( $d, 'op', $OG, { action => 'account-promote', username => 'sub1' } );
    ok( $r->{ok}, 'operator CAN promote sub1 to top level' ) or diag encode_json($r);
    ok( settings( $d, 'sub1' )->{top_level}, '  ... sub1 is now top-level' );
    is( settings( $d, 'sub1' )->{created_by}, 'boss',
        '  ... created_by (provenance) preserved through promotion' );

    my $r2 = post( $d, 'op', $OG,
        { action => 'account-scope-independent', username => 'sub1', value => 1 } );
    ok( $r2->{ok}, 'operator CAN set scope_independent' ) or diag encode_json($r2);
    ok( settings( $d, 'sub1' )->{scope_independent},
        '  ... scope_independent flag set by the operator' );
}

done_testing();
