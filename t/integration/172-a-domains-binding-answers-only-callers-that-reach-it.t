#!/usr/bin/perl
# SM747 E-Q1 (as recommended, approved 2026-10-13), through the real control
# API and MCP server: a signed-in caller has no host, so a binding with a
# `domain:` runs for it only if it reaches that domain, by SM976's one rule.
#
# Callers: op, the cookie operator (reaches every domain); tks and tko, control
# API tokens confined to shop.example and other.example; mcs and mco, MCP
# grants confined the same way. Every one is in the bindings' callers, so the
# only thing that differs is where it reaches.
#
# The children get OOM's fake Odoo with PERL5OPT=-MOdooInject (t/lib), so
# nothing reaches a network.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use JSON::PP       qw(encode_json decode_json);
use IPC::Open2     qw(open2);
use IPC::Open3     qw(open3);
use Symbol         qw(gensym);
use MIME::Base64   qw(encode_base64);
use File::Path     qw(make_path);
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);
use OdooTest       qw(oom_or_skip pretend_released odoo_site set_key bind);

BEGIN { oom_or_skip() }

my $root = repo_root();
pretend_released();

my @ALL  = qw(ui api mcp manage_users manage_domains manage_content);
my %CAPS = (
    op  => [qw(ui manage_users manage_domains manage_content)],
    tks => ['api'],
    tko => ['api'],
    mcs => ['mcp'],
    mco => ['mcp'],
);

my $s = new_site( root => $root, conf => "control_api_enabled: true\nmcp_enabled: true\n" );
my $d = $s->docroot;
make_path( "$d/sites/shop", "$d/sites/other" );
for my $u ( sort keys %CAPS ) {
    $s->add_user( $u, "pw-$u-0123456789" );
    $s->grant( $u, "g-$u",  $CAPS{$u}, \@ALL );
    $s->grant( $u, 'staff', [],        [] );
}

local $ENV{PERL5OPT}         = "-I$root/t/lib -MOdooInject";
local $ENV{LAZYSITE_OOM_LIB} = OdooTest::oom_lib();

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
my %tok = map { $_ => ( uapi( { action => 'token', username => $_ } )->{token} // '' ) } qw(tks tko mcs mco);

sub api {
    my ( $who, $action, $body ) = @_;
    return $s->call( $who, $action, ( defined $body ? ( body => $body ) : () ) ) if $who eq 'op';
    my $json = defined $body ? encode_json($body) : undef;
    local %ENV = %ENV;
    delete @ENV{qw(HTTP_X_REMOTE_USER HTTP_X_REMOTE_GROUPS LAZYSITE_AUTH_TRUSTED HTTP_COOKIE HTTP_X_CSRF_TOKEN LAZYSITE_USERS_TOOL)};
    $ENV{DOCUMENT_ROOT}      = $d;
    $ENV{HTTP_AUTHORIZATION} = 'Basic ' . encode_base64( "$who:$tok{$who}", '' );
    $ENV{QUERY_STRING}       = "action=$action";
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
    my $body = encode_json(
        { jsonrpc => '2.0', id => 1, method => 'tools/call', params => { name => $tool, arguments => $args // {} } } );
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
    [ 'domain-add', { host => 'shop.example',  content_root => 'sites/shop' } ],
    [ 'domain-add', { host => 'other.example', content_root => 'sites/other' } ],
    [ 'domain-set', { host => 'shop.example', key => 'allowed_groups', value => 'g-tks, g-mcs' } ],
    [ 'domain-set', { host => 'other.example', key => 'allowed_groups', value => 'g-tko, g-mco' } ],
    )
{
    my $r = api( 'op', @$set );
    ok( $r->{ok}, "set up: $set->[0] $set->[1]{host}" ) or diag( $r->{error} // '' );
}
odoo_site($d);
set_key($d);
bind( $d, id => 'shop-list', domain => 'shop.example', operation => 'shop.products', modes => 'authenticated',
    callers => 'staff' );
bind( $d, id => 'all-list', operation => 'shop.products', modes => 'authenticated', callers => 'staff' );

sub ids { return join ',', sort map { $_->{id} } @{ $_[0]{bindings} || [] } }

subtest 'the control API: the caller\'s own reach' => sub {
    my $r = api( 'op', 'odoo-run', { binding => 'shop-list' } );
    ok( $r->{ok}, 'the operator reaches every domain: runs' ) or diag explain $r;
    $r = api( 'tks', 'odoo-run', { binding => 'shop-list' } );
    ok( $r->{ok}, 'a token confined to the domain: runs' ) or diag explain $r;
    $r = api( 'tko', 'odoo-run', { binding => 'shop-list' } );
    is( $r->{kind} // '', 'wrong-domain', 'a token confined to another domain: refused' ) or diag explain $r;
    like( $r->{error} // '', qr/does not reach the domain shop\.example/, 'saying so' );
    ok( api( 'tko', 'odoo-run', { binding => 'all-list' } )->{ok}, 'a binding with no domain runs for it' );
    is( ids( api( 'tko', 'odoo-bindings' ) ), 'all-list', 'and it is offered only that one' );
    is( ids( api( 'tks', 'odoo-bindings' ) ), 'all-list,shop-list', 'the domain\'s token is offered both' );
};

subtest 'MCP: the grant\'s own reach' => sub {
    my $r = mcp( 'mcs', 'odoo_run', { binding => 'shop-list' } );
    ok( $r->{ok}, 'a grant confined to the domain: runs' ) or diag explain $r;
    $r = mcp( 'mco', 'odoo_run', { binding => 'shop-list' } );
    ok( !$r->{ok}, 'a grant confined to another domain: refused' );
    like( $r->{error} // '', qr/does not reach the domain shop\.example/, 'saying so' );
    ok( mcp( 'mco', 'odoo_run', { binding => 'all-list' } )->{ok}, 'a binding with no domain runs for it' );
    is( ids( mcp( 'mco', 'odoo_bindings' ) ), 'all-list', 'and it is offered only that one' );
};

done_testing();
