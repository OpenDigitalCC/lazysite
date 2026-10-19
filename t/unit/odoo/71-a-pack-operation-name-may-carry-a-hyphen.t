#!/usr/bin/perl
# SM1178: A PACK'S OPERATION NAME MAY CARRY A HYPHEN INSIDE A SEGMENT
# (crm-page.leads), AS OOM'S OWN RULE ALLOWS.
#
# Field report (lazysite-sites agent, 2026-10-18): OOM 0.32's packaged pack
# `crm-page` names its operations `crm-page.leads`, `crm-page.lead`, ...; the
# extension lists them but handler-save refused every binding to one, "is not an
# operation name (dotted, lower case)", because the pattern had no hyphen. OOM's
# rule (Odoo::Ops::Pack: pack names are lower-case letters, digits and hyphens,
# starting with a letter; Registry: an operation is named <pack>.<op>; core's own
# `stock.link-stranded`) admits a hyphen inside a segment. A hyphen that leads,
# trails or doubles a segment is not a name, whichever side reads it.
#
# OOM's fake Odoo is the transport. No network.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
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

# A pack whose NAME has an underscore (OOM 0.35 renamed crm-page to crm_page and stock.link-stranded to
# stock.link_stranded: a pack name is lower case letters, digits and _; SM1185), in the shape OOM's packs/README.md gives
# (namespace Odoo::Pack::ShopPage for the pack shop_page).
sub make_pack {
    my ($root) = @_;
    put( "$root/shop_page/pack.yaml", <<'YAML' );
name: shop_page
version: 1.0.0
oom_min: "0.30"
namespace: Odoo::Pack::ShopPage
series: [16, 17, 18]
summary: A fixture pack with an underscore in its name
YAML
    put( "$root/shop_page/lib/Odoo/Pack/ShopPage/Names.pm", <<'PM' );
package Odoo::Pack::ShopPage::Names;
use strict;
use warnings;
use parent 'Odoo::Ops::Operation';
sub op_name    { 'shop_page.names' }
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

subtest 'a binding to an underscored pack saves and runs' => sub {
    write_conf( $d, odoo_url => 'https://odoo.example', odoo_db => 'shopdb', odoo_login => 'site-connection',
        odoo_allow_writes => 'true', odoo_packs => OdooTest::shop_namespace(), odoo_pack_dirs => $packs );
    bind( $d, id => 'names', operation => 'shop_page.names', modes => 'public', params => 'n=limit' );
    my ($b) = Lazysite::Odoo::find_binding('names');
    ok( $b, 'the shop_page.names binding is saved and found' );
    my ( undef, $r ) = quiet( sub { Lazysite::Odoo::call( $b, { n => 1 }, mode => 'public', strict => 1 ) } );
    ok( $r->{ok}, 'and runs' ) or diag explain $r;
    is( $r->{report}{rows}[0]{name}, 'Tea', 'with the pack operation\'s answer' );
};

subtest 'the name rule: a hyphen inside a segment, nothing else' => sub {
    for my $ok ( 'crm-page.leads', 'crm-page.lead', 'stock.link-stranded', 'a-b-c.d-e', 'core.has_groups', 'crm.export' ) {
        my ( $b, $why ) = Lazysite::Odoo::Binding::parse( { id => 'x', operation => $ok } );
        ok( $b, "accepted: $ok" ) or diag($why);
    }
    for my $bad ( '-crm.x', 'crm-.x', 'crm.x-', 'crm.-x', 'crm--page.x', 'crm.x--y', 'CRM-page.x', 'crm page.x',
        'crm-page', 'crm-page.', '.leads', 'crm-page..leads', '1crm-page.x' ) {
        my ( $b, $why ) = Lazysite::Odoo::Binding::parse( { id => 'x', operation => $bad } );
        ok( !$b, "refused: $bad" );
        like( $why // '', qr/operation name/, 'as not an operation name' );
    }
};

done_testing;
