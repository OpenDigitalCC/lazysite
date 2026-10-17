#!/usr/bin/perl
# SM1164 D0: A SITE'S OWN OPERATION PACK BINDS LIKE core.read, AND A BINDING MAY
# FEED core.set / core.make's set.<field> PARAMETERS.
#
# Inbox L7 addendum (2026-10-18), section 1: OOM 0.30+ loads packs from
# directories (`pack_dirs`), and 0.29's core.set / core.make take one `set.<field>`
# parameter per field. Two things stood in the way here: nothing passed
# pack_dirs, and a binding's parameter names were [a-z][a-z0-9_]*, so a dot was
# refused. A pack is CODE, so the directory is held to the site's own tree (or the
# packaged packs directory); anything else is refused by name when the
# config loads. The plain-value rule (str, int, bool only from a request) is
# unchanged: a set.<field> value is a plain value.
#
# OOM's fake Odoo is the transport. No network.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use Cwd        ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);
use OdooTest   qw(oom_or_skip shop_ready bind quiet write_conf);

BEGIN { oom_or_skip() }
use Lazysite::Odoo          ();
use Lazysite::Odoo::Binding ();

sub put {
    my ( $path, $text ) = @_;
    ( my $dir = $path ) =~ s{/[^/]+\z}{};
    make_path($dir);
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $text;
    close $fh;
}

# A pack of one read operation, in the shape OOM's packs/README.md gives.
sub make_pack {
    my ($root) = @_;
    put( "$root/shopx/pack.yaml", <<'YAML' );
name: shopx
version: 1.0.0
oom_min: "0.30"
namespace: Odoo::Pack::Shopx
series: [16, 17, 18]
summary: A fixture pack for the lazysite tests
YAML
    put( "$root/shopx/lib/Odoo/Pack/Shopx/Names.pm", <<'PM' );
package Odoo::Pack::Shopx::Names;
use strict;
use warnings;
use parent 'Odoo::Ops::Operation';
sub op_name    { 'shopx.names' }
sub summary    { 'The product names' }
sub params     { return { limit => { type => 'int', default => 20 } } }
sub read_scope { return { 'x.product' => ['search_read'] } }
sub report {
    my ($self) = @_;
    return { rows => $self->model('x.product')->search_read( [], ['name'], limit => $self->param('limit') ) };
}
1;
PM
    return;
}

my ( $d, $fake ) = shop_ready();
my $packs = "$d/lazysite/odoo-packs";
make_pack($packs);

subtest 'a pack directory under the site binds and runs' => sub {
    write_conf( $d, odoo_url => 'https://odoo.example', odoo_db => 'shopdb', odoo_login => 'site-connection',
        odoo_allow_writes => 'true', odoo_packs => OdooTest::shop_namespace(), odoo_pack_dirs => $packs );
    my ( $c, $why ) = Lazysite::Odoo::connection();
    ok( $c, 'the config loads' ) or diag($why);
    is_deeply( $c->{pack_dirs}, [ Cwd::abs_path($packs) ], 'and keeps the directory' );

    bind( $d, id => 'names', operation => 'shopx.names', modes => 'public', params => 'n=limit' );
    my ($b) = Lazysite::Odoo::find_binding('names');
    ok( $b, 'the <pack>.<op> binding is saved and found' );
    my ( undef, $r ) = quiet( sub { Lazysite::Odoo::call( $b, { n => 1 }, mode => 'public', strict => 1 ) } );
    ok( $r->{ok}, 'and runs' ) or diag explain $r;
    is( $r->{report}{rows}[0]{name},    'Tea', 'with the pack operation\'s answer' );
    is( scalar @{ $r->{report}{rows} }, 1,     '...given the request\'s limit' );
};

subtest 'a pack directory outside the site is refused, by name' => sub {
    my $out = site_tempdir();    # another tree entirely
    make_pack("$out/packs");
    for my $dir ( "$out/packs", '/etc', 'relative/packs', "$packs/../../../etc", "$packs:$out/packs" ) {
        write_conf( $d, odoo_url => 'https://odoo.example', odoo_db => 'shopdb', odoo_login => 'site-connection',
            odoo_pack_dirs => $dir );
        my ( $c, $why ) = Lazysite::Odoo::connection();
        ok( !$c, "refused: $dir" );
        like( $why, qr/odoo_pack_dirs/, 'the setting is named' );
    }
    write_conf( $d, odoo_url => 'https://odoo.example', odoo_db => 'shopdb', odoo_login => 'site-connection',
        odoo_pack_dirs => "$out/packs" );
    my ( undef, $why ) = Lazysite::Odoo::connection();
    like( $why, qr/\Q$out\/packs\E/, 'the directory is named' );

    write_conf( $d, odoo_url => 'https://odoo.example', odoo_db => 'shopdb', odoo_login => 'site-connection',
        odoo_pack_dirs => "$packs/missing" );
    ( undef, $why ) = Lazysite::Odoo::connection();
    like( $why, qr/missing.*(?:not a directory|does not exist)/, 'a directory that is not there is refused too' );

    symlink( $out, "$d/lazysite/odoo-escape" ) or die $!;
    write_conf( $d, odoo_url => 'https://odoo.example', odoo_db => 'shopdb', odoo_login => 'site-connection',
        odoo_pack_dirs => "$d/lazysite/odoo-escape/packs" );
    ( undef, $why ) = Lazysite::Odoo::connection();
    like( $why, qr/odoo_pack_dirs/, 'a symlink out of the tree does not get a directory in' );

    write_conf( $d, odoo_url => 'https://odoo.example', odoo_db => 'shopdb', odoo_login => 'site-connection' );
    my ($c) = Lazysite::Odoo::connection();
    is_deeply( $c->{pack_dirs}, [], 'unset is none' );
};

subtest 'set.<field> is a parameter name, and only that shape' => sub {
    for my $ok ( 'set.name', 'set.x_studio_note1', 'set.partner_id' ) {
        my ( $b, $why ) = Lazysite::Odoo::Binding::parse(
            { id => 'x', operation => 'core.set', params => "v=$ok", fixed => 'model=x.product,id=1' } );
        ok( $b, "accepted: $ok" ) or diag($why);
    }
    for my $bad ( 'set.Name', 'set.', 'set.a.b', 'set.1a', 'Set.name', 'set._x', 'sets.name' ) {
        my ( $b, $why ) = Lazysite::Odoo::Binding::parse(
            { id => 'x', operation => 'core.set', params => "v=$bad" } );
        ok( !$b, "refused: $bad" );
        like( $why, qr/parameter name/, 'as not a parameter name' );
    }
    my ( $b, $why ) = Lazysite::Odoo::Binding::parse(
        { id => 'x', operation => 'core.set', params => 'v=a.b' } );
    ok( !$b, 'every other name keeps today\'s rule' );
};

subtest 'a binding sets a field through core.set' => sub {
    write_conf( $d, odoo_url => 'https://odoo.example', odoo_db => 'shopdb', odoo_login => 'site-connection',
        odoo_allow_writes => 'true' );
    bind( $d, id => 'rename', operation => 'core.set', modes => 'authenticated', callers => 'staff',
        apply => 'immediate', params => 'id=id,title=set.name', fixed => 'model=x.product' );
    my ($b) = Lazysite::Odoo::find_binding('rename');
    ok( $b, 'the binding is saved' );
    my %STAFF = ( mode => 'authenticated', actor => 'sam', groups => ['staff'] );
    my ( $log, $r ) = quiet( sub { Lazysite::Odoo::call( $b, { id => 1, title => 'Green tea' }, %STAFF, strict => 1 ) } );
    ok( $r->{ok}, 'it runs' ) or diag explain [ $r, $log ];
    my $name = $fake->record( 'x.product', 1 )->{name};
    is( $name, 'Green tea', 'and the field has changed in Odoo' );

    # a json-typed parameter still cannot be fed by a request
    my ( $bad, $why ) = Lazysite::Odoo::Binding::parse(
        { id => 'x', operation => 'core.set', params => 'v=set.name', fixed => 'set.name=Y' } );
    ok( !$bad, 'one source per set.<field>' );
    like( $why, qr/set\.name.*one source/, 'named' );
};

done_testing;
