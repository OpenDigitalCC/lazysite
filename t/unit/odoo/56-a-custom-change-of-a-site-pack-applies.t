#!/usr/bin/perl
# SM1170 (inbox L-12, 2026-10-17): A `custom` CHANGE OF A SITE PACK APPLIES.
#
# "A `custom` change of a SITE pack cannot be applied through the extension.
# `Lazysite::Odoo::registry()` sets `ODOO_OPS_NAMESPACES` with `local` while it
# looks the operation up and plans; `Odoo::Ops::Runner->apply` builds a fresh
# registry without the site's namespaces, cannot find the operation's class, and
# the apply ends `apply-incomplete` with "no operation 'lab.stock.move'"."
#
# The Runner finds a custom change's class by name with Registry->new and no
# arguments, which reads the process environment alone. So the site's packs
# (odoo_packs) and pack directories (odoo_pack_dirs, SM1164 D0) must be in the
# environment for the apply too. Plan and confirm are separate calls here, as
# they are in two requests, and nothing is set process-wide: the environment is
# checked bare before and after.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use OdooTest qw(oom_or_skip shop_ready bind quiet write_conf);

BEGIN { oom_or_skip() }
use Lazysite::Odoo ();

sub put {
    my ( $path, $text ) = @_;
    ( my $dir = $path ) =~ s{/[^/]+\z}{};
    make_path($dir);
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $text;
    close $fh;
}

# The same operation as t/lib/LazysiteTest/OdooCustom/Rename.pm, as a pack in a directory.
sub make_pack {
    my ($root) = @_;
    put( "$root/shopz/pack.yaml", <<'YAML' );
name: shopz
version: 1.0.0
oom_min: "0.30"
namespace: Odoo::Pack::Shopz
series: [16, 17, 18]
summary: A fixture pack with a custom change
YAML
    put( "$root/shopz/lib/Odoo/Pack/Shopz/Rename.pm", <<'PM' );
package Odoo::Pack::Shopz::Rename;
use strict;
use warnings;
use parent 'Odoo::Ops::Operation';
sub op_name     { 'shopz.rename' }
sub summary     { 'Rename a product' }
sub params      { return { id => { type => 'int', required => 1 }, name => { type => 'str', required => 1 } } }
sub read_scope  { return { 'x.product' => ['search_read'] } }
sub write_scope { return { 'x.product' => ['write'] } }
sub plan {
    my ($self) = @_;
    my $id   = $self->param('id');
    my $plan = $self->new_plan( input_count => 1 );
    my $have = $self->model('x.product')->search_read( [ [ 'id', '=', $id ] ], ['name'] );
    return $plan unless @$have;
    $plan->add( bucket => 'renamed', action => 'custom', handler => $self->op_name, kind => 'rename',
        model => 'x.product', id => $id, before => { name => $have->[0]{name} },
        vals  => { name => $self->param('name') }, line => "rename product $id" );
    return $plan;
}
sub apply_custom {
    my ( $class, $client, $c ) = @_;
    $client->model('x.product')->write( [ $c->{id} ], { name => $c->{vals}{name} } );
    return { id => $c->{id}, reported => 'write', after => { id => $c->{id}, name => $c->{vals}{name} } };
}
sub undo_custom { my ( $class, $e ) = @_; return ( { name => $e->{before}{name} }, undef ) }
1;
PM
    return;
}

my ( $d, $fake ) = shop_ready();
my $packs = "$d/lazysite/odoo-packs";
make_pack($packs);

# SM1185: OdooTest points ODOO_OOM_PACK_DIRS at a directory with no packs so no test reads the
# host's installed packs; "bare" means that value is still the one it set.
my $NO_PACKS = $ENV{ODOO_OOM_PACK_DIRS};

my %STAFF = ( mode => 'authenticated', actor => 'sam', groups => ['staff'] );
my %CONN  = ( odoo_url => 'https://odoo.example', odoo_db => 'shopdb', odoo_login => 'site-connection',
    odoo_allow_writes => 'true' );

sub env_bare {
    return ( !grep { exists $ENV{$_} } qw(ODOO_OPS_NAMESPACES XDG_CACHE_HOME) )
        && ( $ENV{ODOO_OOM_PACK_DIRS} // '' ) eq ( $NO_PACKS // '' );
}

sub name_of { return $fake->record( 'x.product', 1 )->{name} }

sub plan_then_confirm {
    my ( $id, $op, $name ) = @_;
    my $before = name_of();
    my ($b) = Lazysite::Odoo::find_binding($id);
    my ( undef, $p ) = quiet( sub { Lazysite::Odoo::call( $b, { id => 1, name => $name }, %STAFF, strict => 1 ) } );
    ok( $p->{planned}, "$id: a plan, not a write" ) or diag explain $p;
    is( name_of(), $before, "$id: nothing written yet" );
    my ( undef, $c ) = quiet( sub { Lazysite::Odoo::confirm( $p->{plan}, %STAFF ) } );
    return $c;
}

ok( env_bare(), 'the test process starts with none of the pack environment set' );

subtest 'a pack from odoo_packs: plan in one call, confirm in another' => sub {
    write_conf( $d, %CONN, odoo_packs => 'LazysiteTest::OdooCustom' );
    bind( $d, id => 'rename-ns', operation => 'shopc.rename', modes => 'authenticated', callers => 'staff',
        params => 'id=id,name=name' );
    my $c = plan_then_confirm( 'rename-ns', 'shopc.rename', 'Green tea' );
    ok( $c->{ok} && $c->{applied}, 'it applies' ) or diag explain $c;
    is( name_of(), 'Green tea', 'and Odoo has the change' );
    ok( env_bare(), 'and nothing was left in the environment' );
};

subtest 'a pack from odoo_pack_dirs: plan in one call, confirm in another' => sub {
    write_conf( $d, %CONN, odoo_pack_dirs => $packs );
    bind( $d, id => 'rename-dir', operation => 'shopz.rename', modes => 'authenticated', callers => 'staff',
        params => 'id=id,name=name' );
    my $c = plan_then_confirm( 'rename-dir', 'shopz.rename', 'Black tea' );
    ok( $c->{ok} && $c->{applied}, 'it applies' ) or diag explain $c;
    is( name_of(), 'Black tea', 'and Odoo has the change' );
    ok( env_bare(), 'and nothing was left in the environment' );
};

subtest 'an immediate binding applies in the one request' => sub {
    write_conf( $d, %CONN, odoo_packs => 'LazysiteTest::OdooCustom' );
    bind( $d, id => 'rename-now', operation => 'shopc.rename', modes => 'authenticated', callers => 'staff',
        apply => 'immediate', params => 'id=id,name=name' );
    my ($b) = Lazysite::Odoo::find_binding('rename-now');
    my ( undef, $r ) = quiet( sub { Lazysite::Odoo::call( $b, { id => 1, name => 'Iced tea' }, %STAFF, strict => 1 ) } );
    ok( $r->{ok} && $r->{applied}, 'it applies' ) or diag explain $r;
    is( name_of(), 'Iced tea', 'and Odoo has the change' );

    write_conf( $d, %CONN, odoo_pack_dirs => $packs );
    bind( $d, id => 'rename-dir-now', operation => 'shopz.rename', modes => 'authenticated', callers => 'staff',
        apply => 'immediate', params => 'id=id,name=name' );
    ($b) = Lazysite::Odoo::find_binding('rename-dir-now');
    ( undef, $r ) = quiet( sub { Lazysite::Odoo::call( $b, { id => 1, name => 'Chai' }, %STAFF, strict => 1 ) } );
    ok( $r->{ok} && $r->{applied}, 'a pack directory applies too' ) or diag explain $r;
    is( name_of(), 'Chai', 'and Odoo has that change' );
    ok( env_bare(), 'nothing was left in the environment' );
};

done_testing;
