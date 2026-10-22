#!/usr/bin/perl
# SM1053 (n571), the second of what the core left unbuilt: a staged import
# could only be removed by hand from lazysite/auth/import/. accounts-import-remove
# removes one: the account that staged it (either door, as staging is), or the
# operator (a cookie session). Nobody else - holding manage_users is not enough,
# and neither is having staged a different import. Audited, as every mutating
# action is, naming the import.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP       qw(encode_json decode_json);
use MIME::Base64   qw(encode_base64);
use TestHelper     qw(repo_root run_child);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";
local $ENV{LAZYSITE_PROCESSOR} = "$root/lazysite-processor.pl";

my @ALL  = qw(ui api manage_users manage_content);
my %CAPS = (
    op  => [qw(ui manage_users manage_content)],
    tks => [qw(api manage_users manage_content)],    # the partner, by token
    ckm => [qw(ui manage_users)],                    # manage_users, not the operator
    ckc => [qw(ui manage_content)],                  # no manage_users
);
my $s = new_site( root => $root, conf => "control_api_enabled: true\n" );
my $d = $s->docroot;
for my $u ( sort keys %CAPS ) {
    $s->add_user( $u, "pw-$u-0123456789" );
    $s->grant( $u, "g-$u", $CAPS{$u}, \@ALL );
}
$s->users( 'group-set', 'g-op', 'manager', 'on' );    # SM991: the operator

sub uapi {
    my ($p) = @_;
    my $out = run_child( [ $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // {};
}
my $TOKEN = uapi( { action => 'token', username => 'tks' } )->{token} // '';

sub api {
    my ( $who, $action, $body, $query ) = @_;
    $query //= "action=$action";
    return $s->call( $who, $action, ( defined $body ? ( body => $body ) : () ), query => $query )
        if $who ne 'tks';
    my $json = defined $body ? encode_json($body) : undef;
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE HTTP_X_CSRF_TOKEN LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{HTTP_AUTHORIZATION} = 'Basic ' . encode_base64( "tks:$TOKEN", '' );
    $ENV{QUERY_STRING}       = $query;
    $ENV{REQUEST_METHOD}     = defined $json ? 'POST'       : 'GET';
    $ENV{CONTENT_LENGTH}     = defined $json ? length $json : 0;
    my $out = run_child( [ $^X, "$root/lazysite-manager-api.pl" ],
        stdin => ( $json // '' ) )->{out};
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}
sub staged { return -f "$d/lazysite/auth/import/$_[0].json" }
sub audit  { open my $fh, '<', "$d/lazysite/logs/audit.log" or return (); return <$fh> }
sub stage {
    my ( $who, $name ) = @_;
    my $r = api( $who, 'accounts-import-stage', { accounts => [ { username => $name } ] } );
    ok( $r->{ok}, "$who stages an import" ) or diag( $r->{error} // $r->{_raw} // '' );
    return $r->{id} // '';
}

my $a = stage( 'tks', 'a1' );
my $b = stage( 'tks', 'b1' );
my $c = stage( 'ckm', 'c1' );

subtest 'nobody else removes it' => sub {
    my $r = api( 'ckm', 'accounts-import-remove', { id => $a } );
    is( $r->{kind} // '', 'forbidden', 'a manage_users holder who did not stage it: refused' );
    ok( staged($a), '...and it is still staged' );
    $r = api( 'tks', 'accounts-import-remove', { id => $c } );
    is( $r->{kind} // '', 'forbidden', 'the partner, on an import another account staged: refused' );
    ok( staged($c), '...still staged' );
    $r = api( 'ckc', 'accounts-import-remove', { id => $a } );
    ok( !$r->{ok}, 'a session without manage_users: refused' );
    ok( staged($a), '...still staged' );
    ok( ( grep { /accounts-import-remove/ && /accounts import \Q$a\E/ && /\| fail \|/ } audit() ),
        'a refused removal is in the trail' );
};

subtest 'the account that staged it removes it' => sub {
    my $r = api( 'tks', 'accounts-import-remove', { id => $a } );
    ok( $r->{ok}, 'the partner removes its own, by token' ) or diag( $r->{error} // $r->{_raw} // '' );
    ok( !staged($a), '...and it is gone' );
    ok( ( grep { /\| tks \| accounts-import-remove \| accounts import \Q$a\E \|.*\| ok \|/ } audit() ),
        '...audited, naming the import' ) or diag( grep { /remove/ } audit() );
    $r = api( 'ckm', 'accounts-import-remove', { id => $c } );
    ok( $r->{ok}, 'a cookie account removes its own' );
    ok( !staged($c), '...gone' );
    $r = api( 'tks', 'accounts-import-remove', { id => $a } );
    is( $r->{kind} // '', 'not-found', 'removed twice: not found' );
    $r = api( 'tks', 'accounts-import-remove', { id => '../../users' } );
    is( $r->{kind} // '', 'invalid', 'an id that is not one: invalid' );
};

subtest 'the operator removes any' => sub {
    my $r = api( 'op', 'accounts-import-remove', { id => $b } );
    ok( $r->{ok}, 'the operator removes the partner\'s import' ) or diag( $r->{error} // '' );
    ok( !staged($b), '...gone' );
    like( $r->{change} // '', qr/staged by tks/, '...saying whose it was' );
    $r = api( 'op', 'accounts-import-apply', { id => $b, confirm => $b } );
    is( $r->{kind} // '', 'not-found', 'and it cannot then be applied' );
    unlike( do { open my $fh, '<', "$d/lazysite/auth/users"; local $/; <$fh> }, qr/^b1:/m,
        '...nothing was created' );
};

done_testing;
