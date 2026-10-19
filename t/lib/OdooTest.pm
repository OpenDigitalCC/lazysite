package OdooTest;

# SM747: what the Odoo extension's tests share - where OOM is, a site with the
# extension switched on and configured, and the test operation pack.
#
# OOM IS LOADED FROM A PINNED SNAPSHOT INSIDE THIS REPOSITORY, t/vendor/oom/
# (SM1081): its released library, its test doubles, its data and its spec, taken
# from one commit by tools/vendor-oom.sh and held to a MANIFEST by t/lint/261.
# Release manager, 2026-10-14: "it isn't intended that oom changes will prevent a
# lazysite build ... we can't be testing against odoo to run a lazysite, it's
# just an extension, not core." The gate failed three times on 2026-10-13 and 14
# for changes in OOM's working tree and in the host's perl5 directory, and
# neither is read by a test any more (t/lint/262).
#
# LAZYSITE_OOM_LIB overrides the library, and LAZYSITE_OOM_TEST_LIB the test
# doubles, for ONE purpose: tools/ext-compat.sh, the advisory compatibility tier,
# which runs these same tests against the installed deb and against OOM's tree.
# Nothing in the gate sets them.
#
# THE SNAPSHOT IS A RELEASED 0.09, which satisfies the engine's declared minimum,
# so nothing needs to pretend a version any more (`pretend_released` is kept for
# the tests that call it and does nothing). The refusal of an OOM that is too old
# is tested with old_oom_lib(), a stand-in that says 0.01.
#
# NO NETWORK, EVER. OOM's Context takes an injected transport for tests
# (Odoo::Ops::Context->new(transport => ...)), and the fake Odoo used here is
# OOM's own test double from its t/lib - the same one OOM's suite runs on.
use strict;
use warnings;
use Exporter   qw(import);
use File::Path qw(make_path);
use FindBin;

our @EXPORT_OK = qw(oom_lib oom_test_lib vendor_dir oom_or_skip pretend_released odoo_site enable_odoo write_conf
    fake_shop shop_namespace bind set_key shop_ready quiet);

# A binding is a handler of type odoo; saved through the handler contract, as
# an operator's would be, so its validation runs.
sub bind {
    my ( $docroot, %h ) = @_;
    require Lazysite::Handlers;
    no warnings 'once';
    local $Lazysite::Handlers::DOCROOT = $docroot;
    my $r = Lazysite::Handlers::action_handler_save(
        { type => 'odoo', name => $h{id}, %h }, unconstrained => 1 );
    die "binding $h{id} not saved: $r->{error}\n" unless $r->{ok};
    return $r;
}

sub set_key {
    my ( $docroot, $key ) = @_;
    require Lazysite::Odoo::Secret;
    no warnings 'once';
    local $Lazysite::Odoo::Secret::DOCROOT = $docroot;
    my ( $ok, $why ) = Lazysite::Odoo::Secret::set_key( 'connection', $key // 'k3y-for-tests' );
    die "key not set: $why\n" unless $ok;
    return;
}

# The whole arrangement a call needs: OOM on @INC at the released version, a
# configured site, the key set, the fake shop as the transport. Returns
# ( $docroot, $fake ).
sub shop_ready {
    my (%o) = @_;
    pretend_released();
    require TestHelper;
    my $d = TestHelper::site_tempdir();
    odoo_site( $d, %{ $o{conf} // {} } );
    set_key($d) unless $o{no_key};
    my $fake = fake_shop( %{ $o{shop} // {} } );
    no warnings 'once';
    $Lazysite::Odoo::TRANSPORT = $fake;
    $Lazysite::Odoo::DOCROOT   = $d;
    return ( $d, $fake );
}

# STDERR into a scalar for the duration of a block: the engine logs every
# refusal, and a test reads what it said.
sub quiet {
    my ($code) = @_;
    my $log = '';
    open my $fh, '>', \$log or die $!;
    my @r;
    {
        local *STDERR = $fh;
        @r = $code->();
    }
    return ( $log, @r );
}

# The snapshot's directory, found from this file: t/lib/OdooTest.pm -> t/vendor/oom.
sub vendor_dir {
    require Cwd;
    require File::Basename;
    return Cwd::abs_path( File::Basename::dirname( Cwd::abs_path(__FILE__) ) . '/../vendor/oom' );
}

# SM1185: NO TEST READS THE HOST'S INSTALLED PACKS. OOM's registry, with no
# pack_dirs and no ODOO_OOM_PACK_DIRS, loads whatever sits in the deb's pack
# directory. The day the owner installed odoo-oom-packs 0.36 on this host, its
# `shop` pack claimed `shop.basket` beside this suite's test operation of the same
# name and 40 tests failed with "operation 'shop.basket' claimed by both" - a gate
# that depends on what is installed, which t/lint/262 exists to prevent. Naming a
# directory that does not exist gives the registry no packs; a test that wants
# one passes pack_dirs itself (71), and the oomd processes inherit this.
# tools/ext-compat.sh (LAZYSITE_OOM_LIB set) is the one tier that means the host's.
$ENV{ODOO_OOM_PACK_DIRS} = vendor_dir() . '/no-packs-here'
    unless defined $ENV{ODOO_OOM_PACK_DIRS} || defined $ENV{LAZYSITE_OOM_LIB};

sub oom_lib { return $ENV{LAZYSITE_OOM_LIB} // vendor_dir() . '/lib' }


# A lib holding an Odoo::Ops that says 0.01 and nothing else: the version the
# extension refuses, stood up here so that refusal is tested whatever version
# the OOM tree has reached (it said 0.01 until 2026-10-13).
sub old_oom_lib {
    require TestHelper;
    my $d = TestHelper::site_tempdir();
    make_path("$d/Odoo");
    open my $fh, '>', "$d/Odoo/Ops.pm" or die "Odoo/Ops.pm: $!";
    print {$fh} "package Odoo::Ops;\nour \$VERSION = '0.01';\n1;\n";
    close $fh;
    return $d;
}

# OOM's test doubles (Odoo::Test::FakeOdoo and the fixtures; the deb does not ship them).
sub oom_test_lib {
    return $ENV{LAZYSITE_OOM_TEST_LIB} if defined $ENV{LAZYSITE_OOM_TEST_LIB};
    return vendor_dir() . '/t/lib';
}


# Puts OOM (and its test doubles) on @INC, or skips the whole file.
sub oom_or_skip {
    my $lib = oom_lib();
    unless ( -f "$lib/Odoo/Ops.pm" ) {
        require Test::More;
        Test::More::plan( skip_all => "OOM is not at $lib (set LAZYSITE_OOM_LIB)" );
    }
    unshift @INC, $lib, oom_test_lib();
    return $lib;
}

# Kept for the tests that call it. The snapshot is a released OOM (see the header), so
# there is no version to raise: raising it would be a test saying something its
# library does not.
sub pretend_released {
    require Odoo::Ops;
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
