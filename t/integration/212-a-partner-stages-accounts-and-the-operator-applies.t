#!/usr/bin/perl
# SM1053 (inbox 2026-10-12, P-5), ruled 2026-10-12, "Operator-run import": a
# partner uploads an accounts file (usernames, emails, groups; NO passwords) to a
# staging location; the operator reviews a dry-run diff in the manager and
# applies; accounts get claim links; groups limited to those that exist;
# audited; SM268's cookie-only account creation unchanged for partners.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP       qw(encode_json decode_json);
use MIME::Base64   qw(encode_base64);
use File::Path     qw(make_path);
use TestHelper     qw(repo_root run_child);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";
local $ENV{LAZYSITE_PROCESSOR} = "$root/lazysite-processor.pl";

my @ALL  = qw(ui api manage_users manage_domains manage_content);
my %CAPS = (
    op  => [qw(ui manage_users manage_domains manage_content)],
    tks => [qw(api manage_users manage_content)],
    ckc => [qw(ui manage_content)],
    ckm => [qw(ui manage_users)],    # SM991: user management, not the operator
);
my $s = new_site( root => $root, conf => "control_api_enabled: true\n" );
my $d = $s->docroot;
make_path("$d/sites/mine");
for my $u ( sort keys %CAPS ) {
    $s->add_user( $u, "pw-$u-0123456789" );
    $s->grant( $u, "g-$u", $CAPS{$u}, \@ALL );
}

sub uapi {
    my ($p) = @_;
    my $out = run_child( [ $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d ],
        stdin => encode_json($p), stderr => 'inherit' )->{out};
    return eval { decode_json($out) } // {};
}
my $TOKEN = uapi( { action => 'token', username => 'tks' } )->{token} // '';
for my $g (qw(authors)) {
    ok( uapi( { action => 'group-create', group => $g } )->{ok}, "set up: group $g" );
}
$s->users( 'group-set', 'members', 'registration', 'on' );
# SM991: the operator is a member of the operator group (the `manager` flag);
# manage_users alone is user management.
$s->users( 'group-set', 'g-op', 'manager', 'on' );

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

ok( api( 'op', 'domain-add', { host => 'mine.example.org', content_root => 'sites/mine' } )->{ok}, 'set up: a domain' );
ok( api( 'op', 'domain-set', { host => 'mine.example.org', key => 'allowed_groups', value => 'g-tks' } )->{ok},
    '...the partner confined to it' );

sub staged_files {
    opendir my $dh, "$d/lazysite/auth/import" or return 0;
    return scalar grep { /\.json\z/ } readdir $dh;
}
sub settings { return uapi( { action => 'settings-get', username => $_[0] } )->{settings} || {} }
sub members { return uapi( { action => 'groups' } )->{groups} || {} }
sub users { open my $fh, '<', "$d/lazysite/auth/users" or return ''; local $/; return scalar <$fh> }

my $id;
subtest 'the partner stages; nothing exists yet' => sub {
    my $r = api( 'tks', 'accounts-import-stage', { accounts => [ { username => 'm1', password => 'x' } ] } );
    ok( !$r->{ok}, 'a row carrying a password: refused' );
    like( $r->{error} // '', qr/no password/, '...saying an import carries none' );
    is( staged_files(), 0, '...and nothing was staged' );

    $r = api( 'tks', 'accounts-import-stage', { accounts => [
                { username => 'm1', email => 'm1@example.org', groups => [ 'authors', 'nogroup' ] },
                { username => 'm2', email => 'm2@example.org', groups => [] },
                { username => 'op', email => 'op@example.org' },
                { username => 'bad name!' } ] } );
    ok( $r->{ok}, 'a list: staged' ) or diag( $r->{error} // $r->{_raw} // '' );
    is( $r->{staged},                    3, '...three rows' );
    is( scalar @{ $r->{invalid} || [] }, 1, '...and the invalid one named' );
    $id = $r->{id};
    like( $id // '', qr/\A\d{8}-\d{6}-[0-9a-f]{8}\z/, '...under an id' );
    unlike( users(), qr/^m1:/m, 'no account was created by staging' );

    my $c = api( 'tks', 'accounts-import-stage', { csv => "username,email,groups\nc1,c1\@example.org,authors\n" } );
    ok( $c->{ok}, 'a CSV: staged too' ) or diag( $c->{error} // '' );
};

subtest 'the review and the apply are the operator\'s' => sub {
    for my $a (qw(accounts-import-list accounts-import-plan)) {
        my $r = api( 'tks', $a, undef, "action=$a&id=$id" );
        ok( !$r->{ok}, "the token: $a refused" );
    }
    my $r = api( 'tks', 'accounts-import-apply', { id => $id, confirm => $id } );
    ok( !$r->{ok}, 'the token: apply refused' );
    $r = api( 'ckc', 'accounts-import-plan', undef, "action=accounts-import-plan&id=$id" );
    ok( !$r->{ok}, 'a cookie session without manage_users: refused' );
    $r = api( 'ckm', 'accounts-import-plan', undef, "action=accounts-import-plan&id=$id" );
    ok( !$r->{ok}, 'a cookie manage_users holder that is not the operator: refused (SM991)' );
    unlike( users(), qr/^m1:/m, 'and no account was created' );
};

subtest 'the dry run says what applying would do, and does nothing' => sub {
    my $p = api( 'op', 'accounts-import-plan', undef, "action=accounts-import-plan&id=$id" );
    ok( $p->{ok}, 'the operator plans it' ) or diag( $p->{error} // '' );
    is( $p->{create}, 2, 'two to create' );
    is( $p->{skip},   1, 'one exists, skipped' );
    is_deeply( $p->{groups_missing}, ['nogroup'], 'the group that does not exist, named' );
    my ($m1) = grep { $_->{username} eq 'm1' } @{ $p->{rows} || [] };
    is_deeply( $m1->{groups}, ['authors'], 'm1 joins authors only' );
    unlike( users(), qr/^m1:/m, 'and nothing was created' );
    is( scalar @{ api( 'op', 'accounts-import-list' )->{imports} || [] }, 2, 'the list shows both staged imports' );
};

subtest 'the operator applies' => sub {
    my $r = api( 'op', 'accounts-import-apply', { id => $id } );
    is( $r->{kind} // '', 'invalid', 'without confirm: invalid' );
    unlike( users(), qr/^m1:/m, '...nothing created' );

    $r = api( 'op', 'accounts-import-apply', { id => $id, confirm => $id } );
    ok( $r->{ok}, 'applied' ) or diag( $r->{error} // '' );
    is_deeply( [ sort map { $_->{username} } @{ $r->{created} || [] } ], [qw(m1 m2)], 'm1 and m2 created' )
        or diag( encode_json( $r->{failed} || [] ) );
    is_deeply( [ map { $_->{username} } @{ $r->{skipped} || [] } ], ['op'], 'the existing account skipped' );
    my ($m1) = grep { $_->{username} eq 'm1' } @{ $r->{created} || [] };
    like( $m1->{claim_path} // '', qr{/claim},    'each with a claim link' );
    like( users(),                 qr/^m1:\s*$/m, 'm1 has no password' );
    is( settings('m1')->{email}, 'm1@example.org', 'its address is recorded' );
    my $g = members();
    ok( ( grep { $_ eq 'm1' } @{ $g->{authors} || [] } ), 'm1 is in authors' );
    ok( !( grep { $_ eq 'm2' } @{ $g->{members} || [] } ), 'm2 is not put in the registration group' );
    ok( !exists $g->{nogroup}, 'the group that does not exist was not created' );

    $r = api( 'op', 'accounts-import-apply', { id => $id, confirm => $id } );
    is( $r->{kind} // '', 'conflict', 'a second apply: refused' );

    open my $fh, '<', "$d/lazysite/logs/audit.log" or die $!;
    my @log = <$fh>;
    ok( ( grep { /accounts-import-apply/ && /created 2/ } @log ), 'the apply is audited with what it did' );
    ok( ( grep { /user-account-approve/ && /\bm1\b/ } @log ), '...and each account by the users tool' );
};

done_testing;
