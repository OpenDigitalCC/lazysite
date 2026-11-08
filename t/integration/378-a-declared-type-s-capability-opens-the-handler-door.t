#!/usr/bin/perl
# SM1369 X4, ruling 192: THE HANDLER DOOR OPENS FOR A CAPABILITY A DECLARED
# HANDLER TYPE NAMES, AND THE TYPE STILL DECIDES.
#
# The six handler and schedule actions (list, save, delete) opened for the four
# destination capabilities core's types name. The Odoo type is gated by
# manage_odoo (ruling 178), so the door opens for manage_odoo too: a group
# holding it alone manages Odoo bindings and their schedules, and is refused a
# core destination's handler. On a site with an Odoo binding and a core file
# handler:
#
#   * the tables every door derives from (the token gate need_caps, the cookie
#     gate cookie_caps) admit manage_odoo to the six actions once the site's
#     index is mirrored, and are core's four again once it is not;
#   * through the real MCP server, an agent holding manage_odoo alone is listed
#     the handler and schedule tools, sees the Odoo binding and not the core
#     handler, schedules and unschedules the binding, and is refused deleting
#     the core handler and saving one of a core type, by the type's capability;
#   * an agent holding neither is listed none of them.
#
# Sabotage: drop the widen_handler_door call from Declared::mirror_index and the
# tables, the listing and every call above fail; drop the narrowing from
# action_schedule_list and the core handler's entry is listed to the agent.
use strict;
use warnings;
use Test::More;
use File::Path ();
use JSON::PP qw(encode_json decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root run_child);
use OdooTest   qw(oom_or_skip shop_ready bind quiet);

BEGIN { oom_or_skip() }
use Lazysite::Handlers              ();
use Lazysite::ControlApi::Actions   ();
use Lazysite::Extensions::Declared  ();

my $root = repo_root();
my $mcp  = "$root/lazysite-mcp.pl";
my ( $d, $fake ) = shop_ready();
my $LZ = "$d/lazysite";
quiet( sub { bind( $d, id => 'list', operation => 'shop.products', modes => 'public, scheduled' ) } );
{
    no warnings 'once';
    local $Lazysite::Handlers::DOCROOT = $d;
    my ( undef, $f ) = quiet( sub {
            Lazysite::Handlers::action_handler_save( { id => 'store', type => 'file', name => 'store', path => 'contact' },
                unconstrained => 1 );
    } );
    ok( $f->{ok}, 'a core handler (file) beside the binding' ) or diag explain $f;
    my ( undef, $s ) = quiet( sub {
            Lazysite::Handlers::action_schedule_save( { id => 'store-tick', handler => 'store', every => 3600 },
                unconstrained => 1 );
    } );
    ok( $s->{ok}, '...and a schedule entry for it' ) or diag explain $s;
}

open my $cf, '>>', "$LZ/lazysite.conf" or die $!;
print {$cf} "mcp_enabled: true\n";
close $cf;

# ---- the tables the doors derive from ----
subtest 'the gate tables admit manage_odoo to the six, while the index is mirrored' => sub {
    Lazysite::Extensions::Declared::mirror($LZ);
    my $need   = Lazysite::ControlApi::Actions::need_caps();
    my %cookie = Lazysite::ControlApi::Actions::cookie_caps();
    for my $a (@Lazysite::ControlApi::Actions::HANDLER_DOOR) {
        ok( ( grep { $_ eq 'manage_odoo' } @{ $need->{$a} } ), "$a: the token gate admits manage_odoo" );
        like( $cookie{$a}, qr/(?:\A|\|)manage_odoo(?:\||\z)/, "$a: and the cookie gate" );
    }
    Lazysite::Extensions::Declared::unmirror();
    $need = Lazysite::ControlApi::Actions::need_caps();
    is_deeply( $need->{'handler-save'}, [qw(manage_forms manage_data manage_connectors manage_notifications)],
        'without the index the door is core\'s four again' );
};

# ---- the MCP door ----
my $stub = "$d/users-stub.pl";
open my $sf, '>', $stub or die $!;
print {$sf} <<'STUB';
use strict; use warnings; use JSON::PP qw(encode_json decode_json);
my $r = eval { decode_json( do { local $/; <STDIN> } ) } || {};
my $u = $r->{username} // '';
my %caps = ( mcp => 1, ( $u eq 'odoo-only' ? ( manage_odoo => 1 ) : () ) );
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
    my $resp = run_child( [ $^X, "-I$root/lib", $mcp ], stdin => $body, stderr => 'inherit' )->{out};
    my ($jb) = $resp =~ /\r?\n\r?\n(.*)/s;
    return eval { decode_json( $jb // '' ) } // {};
}

sub tool {
    my ( $who, $name, $args ) = @_;
    my $r = mcp( $who, 'tools/call', { name => $name, arguments => $args // {} } );
    return $r->{result}{structuredContent} // { rpc_error => $r->{error} };
}

my @DOOR = qw(list_handlers save_handler delete_handler list_schedule save_schedule delete_schedule);

subtest 'manage_odoo alone: the Odoo binding and its schedule, through MCP' => sub {
    my %listed = map { $_->{name} => 1 } @{ mcp( 'odoo-only', 'tools/list' )->{result}{tools} || [] };
    ok( $listed{$_}, "$_ is listed" ) for @DOOR;

    my $l = tool( 'odoo-only', 'list_handlers' );
    my %ids = map { $_->{id} => 1 } @{ $l->{handlers} || [] };
    ok( $ids{list}, 'the Odoo binding is listed' ) or diag explain $l;
    ok( !$ids{store}, '...and the core handler is not' );

    my $s = tool( 'odoo-only', 'save_schedule', { id => 'list-tick', handler => 'list', every => 3600 } );
    ok( $s->{ok}, 'the binding is scheduled' ) or diag explain $s;
    my $ls = tool( 'odoo-only', 'list_schedule' );
    my %e = map { $_->{id} => 1 } @{ $ls->{schedule} || [] };
    ok( $e{'list-tick'}, 'its entry is listed' ) or diag explain $ls;
    ok( !$e{'store-tick'}, '...and the core handler\'s entry is not' );
    my $ds = tool( 'odoo-only', 'delete_schedule', { id => 'list-tick' } );
    ok( $ds->{ok}, 'and unscheduled' ) or diag explain $ds;
};

subtest 'manage_odoo alone: refused a core destination\'s handler' => sub {
    my $del = tool( 'odoo-only', 'delete_handler', { id => 'store' } );
    ok( !$del->{ok}, 'deleting the core file handler is refused' );
    like( $del->{error} // '', qr/needs the 'manage_forms' permission - the destination decides/, '...by the type\'s capability, past the door' );
    my $sv = tool( 'odoo-only', 'save_handler', { id => 'mine', type => 'file', name => 'mine', path => 'x' } );
    ok( !$sv->{ok}, 'saving a handler of a core type is refused' );
    like( $sv->{error} // '', qr/needs the 'manage_forms' permission - the destination decides/, '...by the type\'s capability, past the door' );
    my $ds = tool( 'odoo-only', 'delete_schedule', { id => 'store-tick' } );
    ok( !$ds->{ok}, 'and so is removing the core handler\'s schedule entry' );
};

subtest 'neither capability: none of the six' => sub {
    my %listed = map { $_->{name} => 1 } @{ mcp( 'nobody', 'tools/list' )->{result}{tools} || [] };
    ok( !$listed{$_}, "$_ is not listed" ) for @DOOR;
};

done_testing();
