#!/usr/bin/perl
# SM747 E (R5: "All operations should also be mcp tools"; Q2: "MCP will use the
# default or specified account"): the Odoo tools, reproduced through the real
# MCP server.
#
#   * the four operator tools are manage_connectors' and the key is never
#     returned;
#   * an agent runs a BOUND operation under the binding's own callers, as the
#     connection user or its grant's own account - never as a visitor;
#   * a capless account is listed none of the operator tools.
#
# The server is a child process; OOM's fake Odoo is put into it with
# PERL5OPT=-MOdooInject (t/lib), so nothing reaches a network and nothing in
# the product looks for a test hook.
use strict;
use warnings;
use Test::More;
use File::Path ();
use JSON::PP   qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root run_child);
use OdooTest   qw(oom_or_skip shop_ready bind quiet);

BEGIN { oom_or_skip() }

my $root = repo_root();
my $mcp  = "$root/lazysite-mcp.pl";
my ( $d, $fake ) = shop_ready();
bind( $d, id => 'list', operation => 'shop.products', modes => 'authenticated', callers => 'agents',
    params => 'n=limit' );
bind( $d, id => 'basket', operation => 'shop.basket', modes => 'authenticated, public', callers => 'agents',
    visitor_param => 'basket_key' );

open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "mcp_enabled: true\n";
close $cf;
File::Path::make_path("$d/lazysite/auth");
open my $gf, '>', "$d/lazysite/auth/groups" or die $!;
print {$gf} "agents: agent\n";
close $gf;

my $stub = "$d/users-stub.pl";
open my $sf, '>', $stub or die $!;
print {$sf} <<'STUB';
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $r = eval { decode_json( do { local $/; <STDIN> } ) } || {};
my $u = $r->{username} // '';
my %caps = ( mcp => 1, ( $u eq 'op' ? ( manage_connectors => 1 ) : () ) );
print encode_json( { ok => 1, settings => \%caps } );
STUB
close $sf;
chmod 0755, $stub;

my $id = 0;
sub mcp {
    my ( $who, $method, $params ) = @_;
    my $body = encode_json( { jsonrpc => '2.0', id => ++$id, method => $method, params => $params // {} } );
    local %ENV = %ENV;
    $ENV{DOCUMENT_ROOT}       = $d;
    $ENV{REQUEST_METHOD}      = 'POST';
    $ENV{CONTENT_LENGTH}      = length $body;
    $ENV{LAZYSITE_USERS_TOOL} = $stub;
    $ENV{HTTP_AUTHORIZATION}  = "Bearer $who:lzs_tok";
    $ENV{PERL5OPT}            = "-I$root/t/lib -MOdooInject";
    $ENV{LAZYSITE_OOM_LIB}    = OdooTest::oom_lib();
    my $resp = run_child( [ $^X, "-I$root/lib", $mcp ],
        stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // {};
}

sub tool {
    my ( $who, $name, $args ) = @_;
    my $r = mcp( $who, 'tools/call', { name => $name, arguments => $args // {} } );
    return $r->{result}{structuredContent} // { rpc_error => $r->{error} };
}

my $KEY = 'mcp-set-k3y-77';

subtest 'the tools are listed by grant' => sub {
    my %op = map { $_->{name} => 1 } @{ mcp( 'op', 'tools/list' )->{result}{tools} || [] };
    my %agent = map { $_->{name} => 1 } @{ mcp( 'agent', 'tools/list' )->{result}{tools} || [] };
    ok( $op{$_}, "manage_connectors sees $_" ) for qw(odoo_status odoo_calls odoo_secret_set odoo_secret_clear);
    ok( !$agent{$_}, "a capless agent does not see $_" ) for qw(odoo_status odoo_secret_set);
    ok( $agent{$_}, "but sees $_ - the binding decides" ) for qw(odoo_bindings odoo_run odoo_confirm);
};

subtest 'the operator tools, and the key never comes back' => sub {
    my $r = tool( 'op', 'odoo_secret_set', { secret => $KEY, grant => 'agent', login => 'odoo-agent' } );
    ok( $r->{ok}, 'a grant\'s own account set over MCP' ) or diag explain $r;
    my $s = tool( 'op', 'odoo_status' );
    is( $s->{has_secret},       1,            'the connection user has a key' );
    is( $s->{grants}[0]{login}, 'odoo-agent', 'the grant is listed' );
    unlike( encode_json($s), qr/\Q$KEY\E|k3y-for-tests/, 'and no key is returned' );
    my $refused = tool( 'agent', 'odoo_secret_set', { secret => 'x' } );
    ok( !$refused->{ok}, 'a capless agent cannot set a key' );
};

subtest 'an agent runs a bound operation, as its own account' => sub {
    my $r = tool( 'agent', 'odoo_bindings' );
    is_deeply( [ map { $_->{id} } @{ $r->{bindings} || [] } ], ['list'],
        'it is offered the binding it may run, and not the visitor one' );
    $r = tool( 'agent', 'odoo_run', { binding => 'list', params => { n => 1 } } );
    ok( $r->{ok}, 'the read answers' ) or diag explain $r;
    is( scalar @{ $r->{report}{rows} || [] }, 1, 'with Odoo\'s rows' );
    my $calls = tool( 'op', 'odoo_calls', { binding => 'list' } );
    is( $calls->{calls}[0]{login}, 'odoo-agent', 'run as the grant\'s own Odoo account (Q2)' );
    is( $calls->{calls}[0]{actor}, 'agent',      'recorded as the agent' );
};

subtest 'never as a visitor, never outside the binding\'s callers' => sub {
    my $r = tool( 'agent', 'odoo_run', { binding => 'basket' } );
    like( $r->{error} // '', qr/never a visitor's/, 'a visitor binding is refused' );
    $r = tool( 'op', 'odoo_run', { binding => 'list' } );
    ok( $r->{ok}, 'manage_connectors is the override, as for a connector' ) or diag explain $r;
    $r = tool( 'agent', 'odoo_run', { binding => 'list', params => { n => 1, extra => 1 } } );
    like( $r->{error} // '', qr/does not take: extra/, 'an unmapped field is refused' );
};

subtest 'clearing the grant puts the agent back on the connection user' => sub {
    ok( tool( 'op', 'odoo_secret_clear', { grant => 'agent' } )->{ok}, 'cleared' );
    tool( 'agent', 'odoo_run', { binding => 'list' } );
    is( tool( 'op', 'odoo_calls', { binding => 'list' } )->{calls}[0]{login}, 'site-connection',
        'the default account' );
};

done_testing();
