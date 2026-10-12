package OdooTest;

# SM747: what the Odoo extension's tests share - where OOM is, a site with the
# extension switched on and configured, and the test operation pack.
#
# OOM IS LOADED FROM ITS TREE, on a library path, because the deb that will
# carry the Ops layer (libodoo-oom-perl 0.02, filed to OOM 2026-10-12) does not
# exist yet. LAZYSITE_OOM_LIB overrides the default; a host without the tree
# SKIPS, cleanly and by name, as t/lint/207 does for the same tree.
#
# THE TREE SAYS 0.01. The engine refuses below 0.02, which is the point of the
# declaration, so a test that needs OOM to RUN raises $Odoo::Ops::VERSION to
# the version the deb will carry - `pretend_released()` - and says so. The
# refusal of 0.01 itself is tested without it.
#
# NO NETWORK, EVER. OOM's Context takes an injected transport for tests
# (Odoo::Ops::Context->new(transport => ...)), and the fake Odoo used here is
# OOM's own test double from its t/lib - the same one OOM's suite runs on.
use strict;
use warnings;
use Exporter   qw(import);
use File::Path qw(make_path);
use FindBin;

our @EXPORT_OK = qw(oom_lib oom_or_skip pretend_released odoo_site enable_odoo write_conf
    fake_shop shop_namespace);

sub oom_lib { return $ENV{LAZYSITE_OOM_LIB} // '/srv/projects/odoo/oom/lib' }

sub _oom_test_lib { ( my $t = oom_lib() ) =~ s{/lib\z}{/t/lib}; return $t }

# Puts OOM (and its test doubles) on @INC, or skips the whole file.
sub oom_or_skip {
    my $lib = oom_lib();
    unless ( -f "$lib/Odoo/Ops.pm" ) {
        require Test::More;
        Test::More::plan( skip_all => "OOM is not at $lib (set LAZYSITE_OOM_LIB)" );
    }
    unshift @INC, $lib, _oom_test_lib();
    return $lib;
}

sub pretend_released {
    require Odoo::Ops;
    no warnings 'once';
    $Odoo::Ops::VERSION = '0.02';
    return;
}

sub write_conf {
    my ( $docroot, %kv ) = @_;
    make_path("$docroot/lazysite");
    open my $fh, '>', "$docroot/lazysite/odoo.conf" or die "odoo.conf: $!";
    print {$fh} "$_: $kv{$_}\n" for sort keys %kv;
    close $fh;
    return;
}

sub enable_odoo {
    my ($docroot) = @_;
    make_path("$docroot/lazysite");
    open my $fh, '>>', "$docroot/lazysite/lazysite.conf" or die "lazysite.conf: $!";
    print {$fh} "plugins:\n  - plugins/odoo.pl\n";
    close $fh;
    return;
}

# A configured site: extension on, a connection, writes on unless told.
sub odoo_site {
    my ( $docroot, %over ) = @_;
    enable_odoo($docroot);
    write_conf( $docroot,
        odoo_url          => 'https://odoo.example',
        odoo_db           => 'shopdb',
        odoo_login        => 'site-connection',
        odoo_allow_writes => 'true',
        odoo_packs        => shop_namespace(),
        %over );
    return $docroot;
}

# THE TEST PACK. A small shop - products, and a basket per visitor - in the
# shape an OOM operation pack takes, under t/lib so it is fixture, not engine.
sub shop_namespace { return 'LazysiteTest::OdooOps' }

# OOM's fake Odoo, serving the models the test pack names. Fake model names,
# deliberately not Odoo's: the pack is a fixture of the SHAPE.
sub fake_shop {
    my (%o) = @_;
    require Odoo::Test::FakeOdoo;
    return Odoo::Test::FakeOdoo->new(
        fields => {
            'x.product' => {
                name => { type => 'char', string => 'Name', portable_type => 'text' },
                price => { type => 'float', string => 'Price', portable_type => 'decimal' },
            },
            'x.basket' => {
                basket_key => { type => 'char', string => 'Key', portable_type => 'text' },
                product_id => { type => 'integer', string => 'Product', portable_type => 'integer' },
                qty => { type => 'integer', string => 'Quantity', portable_type => 'integer' },
            },
        },
        records => {
            'x.product' => [ { name => 'Tea', price => 3.5 }, { name => 'Cake', price => 2.25 } ],
            %{ $o{records} // {} },
        },
        %{ $o{fake} // {} },
    );
}

1;
