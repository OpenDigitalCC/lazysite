#!/usr/bin/perl
# SM1369 X4, ruling 178: THE ODOO HANDLER TYPE IS GATED BY manage_odoo, AND THE
# UPGRADE KEEPS EVERYONE WHO COULD CONFIGURE A BINDING ABLE TO.
#
# Until 0.16.8 the type's `cap` was manage_connectors (C-14). Now it is
# manage_odoo, the extension's own capability, which a group holding
# manage_connectors is topped up with (ruling 71) - by the users tool and by the
# upgrade's own step (ruling 167). On a site as 0.16.8 left it - an Odoo binding
# saved, a schedule entry running it, a group holding manage_connectors and
# nothing else, a group whose operator declined manage_odoo (0) - and through
# the upgrade's step (lazysite-users.pl capability-top-up, as install.pl runs
# it):
#
#   - the type's cap is manage_odoo, in the catalogue and to the scheduler
#     (cap_for_type, the one function both ask);
#   - before the top-up, the manage_connectors group can no longer delete or
#     schedule the binding, and the refusal names manage_odoo (why the step runs);
#   - after it, that group's member lists, schedules and deletes the binding;
#   - the declined group stays declined: refused, naming manage_odoo;
#   - the binding saved before the change is listed, with its cap.
#
# Sabotage: put `cap => 'manage_connectors'` back in extensions/odoo.pl and the
# first assertion and the declined group's refusals fail.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json encode_json);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root grant_caps add_account env_passthrough run_child);
use OdooTest   qw(oom_or_skip shop_ready quiet bind);

BEGIN { oom_or_skip() }
use Lazysite::Handlers       ();
use Lazysite::Auth::Settings ();

my $root = repo_root();
my ( $d, $fake ) = shop_ready();
my $LZ = "$d/lazysite";
$Lazysite::Handlers::DOCROOT = $d;
make_path("$LZ/auth");
grant_caps( $d, 'boss', 'ui' );

# The group store as 0.16.8 left it: manage_connectors held, manage_odoo never decided
# (cora), or declined by the operator (dina).
add_account( $d, $_ ) for qw(cora dina);
grant_caps( $d, 'cora', 'manage_connectors' );
grant_caps( $d, 'dina', 'manage_connectors' );
{
    my $f  = "$LZ/auth/groups-settings.json";
    my $gs = decode_json( do { open my $fh, '<', $f or die $!; local $/; <$fh> } );
    $gs->{'role-dina'}{manage_odoo} = 0;
    open my $fh, '>', $f or die $!;
    print {$fh} encode_json($gs);
    close $fh;
}

quiet( sub { bind( $d, id => 'list', operation => 'shop.products', modes => 'public' ) } );
my ( undef, $sched ) = quiet( sub { Lazysite::Handlers::action_schedule_save( { id => 'nightly', handler => 'list', every => 3600 },
            unconstrained => 1 ) } );

sub caps_of {
    my ($u) = @_;
    no warnings 'once';
    local $Lazysite::Auth::Settings::AUTH_DIR = "$LZ/auth";
    return Lazysite::Auth::Settings::caps_for($u) || {};
}
sub who { my ($u) = @_; return ( user => $u, caps => caps_of($u) ) }

is( Lazysite::Handlers::cap_for_type('odoo'), 'manage_odoo', 'the Odoo handler type is gated by manage_odoo (ruling 178)' );

subtest 'as 0.16.8 left the groups: manage_connectors alone no longer reaches a binding' => sub {
    ok( !caps_of('cora')->{manage_odoo}, 'cora holds manage_connectors and not manage_odoo' );
    my $r = Lazysite::Handlers::action_schedule_save( { id => 'more', handler => 'list', every => 7200 }, who('cora') );
    is( $r->{kind}, 'forbidden', 'scheduling the binding is refused' );
    like( $r->{error} // '', qr/manage_odoo/, '...naming manage_odoo' );
};

# The upgrade's step, as install.pl runs it (run_capability_top_up).
my $run = do {
    local %ENV = ( %ENV, env_passthrough() );
    run_child( [ $^X, "-I$root/lib", "$root/tools/lazysite-users.pl", '--docroot', $d, 'capability-top-up' ] );
};
like( $run->{out} // '', qr/topped up: .*role-cora \(manage_odoo\)/, 'the upgrade\'s top-up names the group it topped up' )
    or diag( ( $run->{out} // '' ) . ( $run->{err} // '' ) );
unlike( $run->{out} // '', qr/role-dina/, '...and not the one whose operator declined' );

subtest 'after the upgrade: whoever held manage_connectors still configures the binding' => sub {
    ok( caps_of('cora')->{manage_odoo}, 'cora holds manage_odoo' );
    my $l = Lazysite::Handlers::action_handler_list( who('cora') );
    my ($h) = grep { $_->{id} eq 'list' } @{ $l->{handlers} || [] };
    ok( $h, 'the binding saved before the change is listed' );
    is( $h->{cap}, 'manage_odoo', '...with its capability' );
    my ( undef, $s ) = quiet( sub { Lazysite::Handlers::action_schedule_save( { id => 'more', handler => 'list', every => 7200 }, who('cora') ) } );
    ok( $s->{ok}, 'it can be scheduled' ) or diag explain $s;
    ok( $sched->{ok}, 'and the entry 0.16.8 saved stands' );
};

subtest 'a declined manage_odoo stays declined' => sub {
    ok( !caps_of('dina')->{manage_odoo}, 'dina still does not hold manage_odoo' );
    my $r = Lazysite::Handlers::action_handler_delete( 'list', who('dina') );
    is( $r->{kind}, 'forbidden', 'deleting the binding is refused' );
    like( $r->{error} // '', qr/manage_odoo/, '...naming manage_odoo' );
    my $l = Lazysite::Handlers::action_handler_list( who('dina') );
    ok( $l->{ok}, 'the list answers' );
};

subtest 'and the topped-up group deletes it once nothing uses it' => sub {
    quiet( sub { Lazysite::Handlers::action_schedule_delete( $_, who('cora') ) for qw(nightly more) } );
    my ( undef, $r ) = quiet( sub { Lazysite::Handlers::action_handler_delete( 'list', who('cora') ) } );
    ok( $r->{ok}, 'deleted' ) or diag explain $r;
};

done_testing();
