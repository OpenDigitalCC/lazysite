#!/usr/bin/perl
# SM1053 (n573), the fourth of what the core left unbuilt: an MCP twin of
# accounts-import-stage, declared once on the action (SM943's `mcp => 'tool'`)
# and recorded until now as undecided in t/lint/23. `stage_accounts` stages, and
# only stages: it creates no account, carries no password, and needs
# manage_users as its twin does. The review - list, plan, apply - stays the
# operator's, in the manager, on a cookie: no MCP tool reaches it.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use JSON::PP       qw(encode_json decode_json);
use TestHelper     qw(repo_root run_child);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'mcp missing' unless -f "$root/lazysite-mcp.pl";
local $ENV{LAZYSITE_PROCESSOR} = "$root/lazysite-processor.pl";

my @ALL  = qw(ui api mcp manage_users manage_content);
my %CAPS = (
    op  => [qw(ui manage_users manage_content)],
    mcs => [qw(mcp manage_users manage_content)],
    mcc => [qw(mcp manage_content)],    # no manage_users
);
my $s = new_site( root => $root, conf => "control_api_enabled: true\nmcp_enabled: true\n" );
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
my %tok = map { $_ => ( uapi( { action => 'token', username => $_ } )->{token} // '' ) } qw(mcs mcc);

sub rpc {
    my ( $who, $method, $params ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => 1, method => $method, params => $params // {} } );
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER LAZYSITE_AUTH_TRUSTED HTTP_COOKIE LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{REQUEST_METHOD}     = 'POST';
    $ENV{CONTENT_LENGTH}     = length $body;
    $ENV{HTTP_AUTHORIZATION} = "Bearer $who:$tok{$who}";
    my $resp = run_child( [ $^X, "$root/lazysite-mcp.pl" ],
        stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } || {};
}
sub mcp {
    my $j = rpc( $_[0], 'tools/call', { name => $_[1], arguments => $_[2] } );
    return { ok => 0, error => $j->{error}{message} } if $j->{error};
    return $j->{result}{structuredContent} || { ok => 0, error => 'no structured content',
        text => encode_json( $j->{result} || {} ) };
}
sub tools { return map { $_->{name} } @{ ( rpc( $_[0], 'tools/list' )->{result} || {} )->{tools} || [] } }
sub staged {
    opendir my $dh, "$d/lazysite/auth/import" or return ();
    return grep { /\.json\z/ } readdir $dh;
}
sub users { open my $fh, '<', "$d/lazysite/auth/users" or return ''; local $/; return scalar <$fh> }
sub audit { open my $fh, '<', "$d/lazysite/logs/audit.log" or return (); return <$fh> }

subtest 'the tool is there for manage_users, and is the only import tool' => sub {
    my @t = tools('mcs');
    ok( ( grep { $_ eq 'stage_accounts' } @t ), 'a manage_users MCP grant lists stage_accounts' );
    is_deeply( [ grep { /import|plan_accounts|apply_accounts|list_imports/ } @t ], [],
        '...and no tool to list, plan or apply an import' );
    ok( !( grep { $_ eq 'stage_accounts' } tools('mcc') ), 'a grant without manage_users is not offered it' );
    my $r = mcp( 'mcc', 'stage_accounts', { accounts => [ { username => 'x1' } ] } );
    ok( !$r->{ok}, '...and is refused it' );
    is( scalar( my @f = staged() ), 0, '...staging nothing' );
};

my $id;
subtest 'it stages as the control API does, and creates nothing' => sub {
    my $r = mcp( 'mcs', 'stage_accounts', { accounts => [ { username => 'm1', password => 'x' } ] } );
    ok( !$r->{ok}, 'a row carrying a password: refused' );
    like( $r->{error} // '', qr/no password/, '...saying an import carries none' );
    is( scalar( my @none = staged() ), 0, '...staging nothing' );

    $r = mcp( 'mcs', 'stage_accounts', { accounts => [
                { username => 'm1', email => 'm1@example.org', groups => ['g-mcs'] },
                { username => 'bad name!' } ] } );
    ok( $r->{ok}, 'a list: staged' ) or diag( $r->{error} // $r->{text} // '' );
    is( $r->{staged}, 1, '...one row' );
    is( scalar @{ $r->{invalid} || [] }, 1, '...and the invalid one named' );
    $id = $r->{id} // '';
    unlike( users(), qr/^m1:/m, 'no account was created' );

    my $c = mcp( 'mcs', 'stage_accounts', { csv => "username,email\nc1,c1\@example.org\n" } );
    ok( $c->{ok}, 'a CSV: staged too' ) or diag( $c->{error} // '' );
    ok( ( grep { /stage_accounts/ && /\| mcs \|/ } audit() ), 'the staging is audited, naming the grant' );
};

subtest 'the operator reviews and applies it in the manager' => sub {
    my $p = $s->call( 'op', 'accounts-import-plan', query => "action=accounts-import-plan&id=$id" );
    ok( $p->{ok}, 'the operator plans it' ) or diag( $p->{error} // '' );
    is( $p->{staged_by}, 'mcs', '...staged by the MCP grant' );
    is( $p->{create},    1,     '...one to create' );
    my $r = $s->call( 'op', 'accounts-import-apply', body => { id => $id, confirm => $id } );
    ok( $r->{ok}, 'and applies it' ) or diag( $r->{error} // '' );
    like( users(), qr/^m1:\s*$/m, 'm1 exists, with no password' );
};

done_testing;
