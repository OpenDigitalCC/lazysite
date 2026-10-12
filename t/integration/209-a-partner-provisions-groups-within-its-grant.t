#!/usr/bin/perl
# SM1050 (inbox 2026-10-12, P-1, P-2, P-3): a partner lists groups and creates
# one, within the delegation limit.
#
# Ruled 2026-10-12, "Yes, within the delegation limit": groups-list (read-only,
# any manage_users holder; a domain-confined caller sees the groups relevant to
# its domains) and group-set (behind manage_users: create a group, grant only
# capabilities the caller holds and may grant, never the operator flag;
# audited), with MCP twins on one declaration.
#
# Callers: op, the cookie operator; tks, a token confined to mine.example.org;
# mcs, an MCP grant confined to the same domain; ckm, a cookie manage_users
# holder bound to no domain (unconfined).
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP       qw(encode_json decode_json);
use IPC::Open2     qw(open2);
use IPC::Open3     qw(open3);
use Symbol         qw(gensym);
use MIME::Base64   qw(encode_base64);
use File::Path     qw(make_path);
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";
local $ENV{LAZYSITE_PROCESSOR} = "$root/lazysite-processor.pl";

my @ALL  = qw(ui api mcp webdav manage_users manage_domains manage_content write_data);
my %CAPS = (
    op  => [qw(ui manage_users manage_domains manage_content webdav write_data)],
    ckm => [qw(ui manage_users manage_content)],
    tks => [qw(api manage_users manage_content webdav write_data)],
    mcs => [qw(mcp manage_users manage_content webdav)],
);

sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $s = new_site( root => $root,
    conf => "control_api_enabled: true\nmcp_enabled: true\n" );
my $d = $s->docroot;
make_path( "$d/sites/mine", "$d/sites/other" );
spit( "$d/sites/$_/index.md", "# $_\n" ) for qw(mine other);
for my $u ( sort keys %CAPS ) {
    $s->add_user( $u, "pw-$u-0123456789" );
    $s->grant( $u, "g-$u", $CAPS{$u}, \@ALL );
}
# The operator group (the `manager` flag, SM991), and another domain's group.
$s->users( 'group-set',    'g-op', 'manager', 'on' );
$s->users( 'group-create', 'other-editors' );
$s->users( 'group-set',    'other-editors', 'webdav', 'on' );

sub uapi {
    my ($p) = @_;
    my ( $o, $i );
    my $pid = open2( $o, $i, $^X, "$root/tools/lazysite-users.pl", '--api', '--docroot', $d );
    print {$i} encode_json($p);
    close $i;
    my $out = do { local $/; <$o> };
    waitpid $pid, 0;
    return eval { decode_json($out) } // {};
}
my %tok = map { $_ => ( uapi( { action => 'token', username => $_ } )->{token} // '' ) } qw(tks mcs);

sub api {
    my ( $who, $action, $body, $query ) = @_;
    $query //= "action=$action";
    return $s->call( $who, $action, ( defined $body ? ( body => $body ) : () ), query => $query )
        if $who !~ /^tk/;
    my $json = defined $body ? encode_json($body) : undef;
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE HTTP_X_CSRF_TOKEN LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{HTTP_AUTHORIZATION} = 'Basic ' . encode_base64( "$who:$tok{$who}", '' );
    $ENV{QUERY_STRING}       = $query;
    $ENV{REQUEST_METHOD}     = defined $json ? 'POST'       : 'GET';
    $ENV{CONTENT_LENGTH}     = defined $json ? length $json : 0;
    my ( $w, $r );
    my $e   = gensym;
    my $pid = open3( $w, $r, $e, $^X, "$root/lazysite-manager-api.pl" );
    print {$w} ( $json // '' );
    close $w;
    my $out = do { local $/; <$r> };
    waitpid $pid, 0;
    my ($jb) = $out =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // { _raw => $out };
}

sub mcp {
    my ( $who, $tool, $args ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => 'tools/call',
            params => { name => $tool, arguments => $args } } );
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER LAZYSITE_AUTH_TRUSTED HTTP_COOKIE LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{REQUEST_METHOD}     = 'POST';
    $ENV{CONTENT_LENGTH}     = length $body;
    $ENV{HTTP_AUTHORIZATION} = "Bearer $who:$tok{$who}";
    my ( $out, $in );
    my $pid = open2( $out, $in, $^X, "$root/lazysite-mcp.pl" );
    print {$in} $body;
    close $in;
    my $resp = do { local $/; <$out> };
    waitpid $pid, 0;
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    my $j = eval { decode_json( $jb // '' ) } || {};
    return { ok => 0, error => $j->{error}{message} } if $j->{error};
    return $j->{result}{structuredContent} || { ok => 0, error => 'no structured content' };
}

for my $set (
    [ 'domain-add', { host => 'mine.example.org',  content_root => 'sites/mine' } ],
    [ 'domain-add', { host => 'other.example.org', content_root => 'sites/other' } ],
    [ 'domain-set', { host => 'mine.example.org', key => 'allowed_groups', value => 'g-tks, g-mcs' } ],
    [ 'domain-set', { host => 'other.example.org', key => 'allowed_groups', value => 'other-editors' } ],
    )
{
    my $r = api( 'op', @$set );
    ok( $r->{ok}, "set up: $set->[0] $set->[1]{host}" ) or diag( $r->{error} // '' );
}

sub names { return join ',', sort map { $_->{name} } @{ $_[0]{groups} || [] } }
sub group_rec {
    open my $fh, '<', "$d/lazysite/auth/groups-settings.json" or return {};
    local $/;
    my $j = eval { decode_json(<$fh>) } || {};
    return $j->{ $_[0] };
}
sub audit_lines {
    open my $fh, '<', "$d/lazysite/logs/audit.log" or return ();
    return grep { /group-set/ } <$fh>;
}

subtest 'groups-list: a confined token sees its domain\'s groups, its own, and none else' => sub {
    my $r = api( 'tks', 'groups-list' );
    ok( $r->{ok}, 'served' ) or diag( $r->{error} // $r->{_raw} // '' );
    is( names($r), 'g-mcs,g-tks', "mine's allowed groups (its own among them)" );
    my ($own) = grep { $_->{name} eq 'g-tks' } @{ $r->{groups} || [] };
    is_deeply( [ sort @{ $own->{caps} || [] } ], [ sort @{ $CAPS{tks} } ], '...with the capabilities each turns on' );
    is( $own->{members}, 1, '...and how many accounts are in it' );
};

subtest 'groups-list: the unconfined see every group' => sub {
    my $r   = api( 'op', 'groups-list' );
    my %has = map { $_->{name} => 1 } @{ $r->{groups} || [] };
    is_deeply( [ grep { !$has{$_} } qw(g-ckm g-mcs g-op g-tks other-editors) ], [],
        "the operator: every group, other domains' among them (and the store's seeded ones)" );
    my ($opg) = grep { $_->{name} eq 'g-op' } @{ $r->{groups} || [] };
    ok( $opg->{operator}, '...the operator group marked as such' );
    is( names( api( 'ckm', 'groups-list' ) ), names($r), 'a cookie manage_users holder bound to no domain' );
};

subtest 'group-set: a confined token creates a role within its grant' => sub {
    my $r = api( 'tks', 'group-set', { group => 'authors', caps => { webdav => JSON::PP::true(), write_data => JSON::PP::true() } } );
    ok( $r->{ok}, 'authors created with webdav and write_data' ) or diag( $r->{error} // '' );
    ok( $r->{created}, '...reported as created' );
    is_deeply( $r->{granted}, [qw(webdav write_data)], '...naming what it granted' );
    my $rec = group_rec('authors');
    ok( $rec && $rec->{webdav} && $rec->{write_data}, '...and the store holds it' );
    is( $rec->{created_by}, 'tks', '...recording who made it' );
    ok( !$rec->{manager}, '...not the operator group' );
    like( names( api( 'tks', 'groups-list' ) ), qr/\bauthors\b/, 'groups-list now shows it to its creator' );
    my @a = audit_lines();
    ok( ( grep { /\@authors/ && /created \+webdav,\+write_data/ } @a ), 'one audit row names the group and the change' )
        or diag( join '', @a );

    $r = api( 'tks', 'group-set', { group => 'authors', caps => { write_data => JSON::PP::false() } } );
    ok( $r->{ok}, 'its creator revokes a capability' ) or diag( $r->{error} // '' );
    is_deeply( $r->{revoked}, ['write_data'], '...reported' );
    ok( !group_rec('authors')->{write_data}, '...and stored' );
};

subtest 'group-set: the delegation limit, and nothing written on a refusal' => sub {
    my $r = api( 'tks', 'group-set', { group => 'admins', caps => { webdav => JSON::PP::true(), manage_domains => JSON::PP::true() } } );
    ok( !$r->{ok}, 'a capability the token does not hold: refused' );
    is( $r->{kind}, 'forbidden', '...forbidden' );
    is_deeply( $r->{not_held}, ['manage_domains'], '...naming it' );
    ok( !group_rec('admins'), '...and the group was not created' );

    $r = api( 'tks', 'group-set', { group => 'admins', caps => { manager => JSON::PP::true() } } );
    ok( !$r->{ok}, 'the operator flag: refused' );
    like( $r->{error} // '', qr/operator flag/, '...saying so' );
    ok( !group_rec('admins'), '...nothing created' );

    $r = api( 'op', 'group-set', { group => 'admins', caps => { manager => JSON::PP::true() } } );
    ok( !$r->{ok}, 'the operator flag: refused to the operator too' );

    $r = api( 'tks', 'group-set', { group => 'other-editors', caps => { webdav => JSON::PP::false() } } );
    ok( !$r->{ok},                            "another domain's group: refused" );
    ok( group_rec('other-editors')->{webdav}, '...and unchanged' );

    $r = api( 'tks', 'group-set', { group => 'g-op', caps => { webdav => JSON::PP::true() } } );
    ok( !$r->{ok}, 'the operator group: refused' );

    $r = api( 'tks', 'group-set', { group => 'g-tks', caps => { write_data => JSON::PP::false() } } );
    ok( !$r->{ok}, 'its own group, which it did not create: refused' );

    $r = api( 'tks', 'group-set', { group => 'bad name!', caps => {} } );
    is( $r->{kind}, 'invalid', 'a bad name: invalid' );
    $r = api( 'tks', 'group-set', { group => 'x1', caps => { flying => JSON::PP::true() } } );
    is( $r->{kind}, 'invalid', 'an unknown capability: invalid' );
    ok( !group_rec('x1'), '...nothing created' );

    $r = api( 'ckm', 'group-set', { group => 'ck-role', caps => { webdav => JSON::PP::true() } } );
    ok( !$r->{ok}, 'a cookie manage_users holder without webdav cannot grant it either' );
    $r = api( 'ckm', 'group-set', { group => 'ck-role', caps => { manage_content => JSON::PP::true() } } );
    ok( $r->{ok}, '...and grants what it holds' ) or diag( $r->{error} // '' );
};

subtest 'the MCP twins answer as the control API does' => sub {
    is( names( mcp( 'mcs', 'list_groups', {} ) ), names( api( 'tks', 'groups-list' ) ) =~ s/authors,//r,
        'list_groups: the same groups, less the one tks created' );
    my $r = mcp( 'mcs', 'set_group', { group => 'm-authors', caps => { webdav => JSON::PP::true() } } );
    ok( $r->{ok}, 'set_group creates within the grant' ) or diag( $r->{error} // '' );
    is( group_rec('m-authors')->{created_by}, 'mcs', '...recording its creator' );
    $r = mcp( 'mcs', 'set_group', { group => 'm-admins', caps => { write_data => JSON::PP::true() } } );
    ok( !$r->{ok}, 'set_group refuses a capability the grant does not hold' );
    $r = mcp( 'mcs', 'set_group', { group => 'authors', caps => { webdav => JSON::PP::false() } } );
    ok( !$r->{ok}, "set_group refuses a group another account created" );
};

subtest 'a cookie group-create cannot name its creator' => sub {
    my $r = api( 'op', 'users', { action => 'group-create', group => 'planted', created_by => 'tks' } );
    ok( $r->{ok}, 'the group is created' ) or diag( $r->{error} // '' );
    ok( !exists group_rec('planted')->{created_by}, '...without the creator it named' );
    my $l = api( 'tks', 'groups-list' );
    unlike( names($l), qr/\bplanted\b/, '...so the token is not handed it' );
};

done_testing;
