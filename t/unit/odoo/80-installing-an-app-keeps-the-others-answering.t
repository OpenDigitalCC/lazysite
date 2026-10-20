#!/usr/bin/perl
# n699 (OOM Lab, oom-pick FINDINGS L-4): "Installing one app rewrites `odoo_packs`;
# while another app was installed, this app's operations answered 404 'no operation
# installed' for a few seconds."
#
# THE CAUSE. A pack's operations are found from `odoo_packs` in lazysite/odoo.conf, read
# afresh by every call (Lazysite::Odoo::connection, registry). SM1172 made the file
# write atomic and the read-modify-write of one save locked. What it left (its "Not
# changed") is the CLIENT's side: an app that installs by reading the list, appending
# its namespace and saving the whole value is a read-modify-write across two requests,
# so two installs that overlap each save a list without the other's namespace, and
# the dropped app answers "no operation 'x' is installed" until something saves it
# again. plugin-save has had no way to ADD to the list. It now has: `add`, merged into
# the list the file holds when the lock is taken.
#
# What stays true of the call path while the list changes (checked here too):
#   * a binding's stored declaration is stamped with the packs (Odoo::Decl); a change
#     of the list makes the stamp miss, and the call reads the registry in-process
#     ONCE and carries on - it does not answer 404 while the list still has its pack;
#   * with odoo_daemon on and oomd restarting (no socket), the call runs in-process.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Copy qw(copy);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir);
use OdooTest   qw(oom_or_skip bind quiet write_conf odoo_site set_key fake_shop);

BEGIN { oom_or_skip() }
use Lazysite::Odoo             ();
use Lazysite::Manager::Plugins ();

OdooTest::pretend_released();
my $root   = repo_root();
my $parent = site_tempdir();
my $d      = "$parent/public_html";
make_path( "$d/lazysite", "$parent/plugins" );
copy( "$root/plugins/odoo.pl", "$parent/plugins/odoo.pl" ) or die $!;
chmod 0755, "$parent/plugins/odoo.pl";
local $ENV{PERL5LIB} = "$root/lib" . ( $ENV{PERL5LIB} ? ":$ENV{PERL5LIB}" : '' );

my $PACK_A = 'LazysiteTest::OdooOps';       # shop.products
my $PACK_B = 'LazysiteTest::OdooCustom';    # shopc.rename
my $conf   = "$d/lazysite/odoo.conf";

OdooTest::enable_odoo($d);
write_conf( $d, odoo_url => 'https://odoo.example', odoo_db => 'shopdb', odoo_login => 'site-connection',
    odoo_allow_writes => 'true', odoo_packs => $PACK_A );
set_key($d);
{ no warnings 'once'; $Lazysite::Odoo::TRANSPORT = fake_shop(); $Lazysite::Odoo::DOCROOT = $d; }
$Lazysite::Manager::Plugins::DOCROOT = $d;

sub conf_text  { open my $h, '<', $conf or return ''; local $/; return <$h> }
sub packs_line { return conf_text() =~ /^odoo_packs:[ \t]*(.*)$/m ? $1 : '' }
sub save { return Lazysite::Manager::Plugins::action_plugin_save( undef, 'plugins/odoo.pl', @_ ) }

bind( $d, id => 'products', operation => 'shop.products', modes => 'public', params => 'limit=limit' );
sub call_a {
    my ($b) = Lazysite::Odoo::find_binding('products');
    my ( undef, $r ) = quiet( sub { Lazysite::Odoo::call( $b, {}, mode => 'public', ip => '192.0.2.7' ) } );
    return $r;
}

subtest 'add puts a namespace into the list the file holds now' => sub {
    my $r = save( {}, { odoo_packs => $PACK_B } );
    ok( $r->{ok}, 'the add is accepted' ) or diag explain $r;
    is( packs_line(), "$PACK_A,$PACK_B", 'the list holds the first app and the new one' );
    is_deeply( $r->{changed}, ['odoo_packs'], 'and the save says what changed' );
    $r = save( {}, { odoo_packs => $PACK_B } );
    is_deeply( $r->{changed}, [], 'adding what is there changes nothing' );
    is( packs_line(), "$PACK_A,$PACK_B", 'and the list is the same' );
};

subtest 'two installs that each read the list before the other saved both land' => sub {
    write_conf( $d, odoo_url => 'https://odoo.example', odoo_db => 'shopdb', odoo_login => 'site-connection',
        odoo_allow_writes => 'true', odoo_packs => $PACK_A );
 # Install B and install C, each having read the list as "A" and neither seeing the other.
    save( {}, { odoo_packs => $PACK_B } );
    save( {}, { odoo_packs => 'LazysiteTest::OdooFail' } );
    is( packs_line(), "$PACK_A,$PACK_B,LazysiteTest::OdooFail", 'all three namespaces are in the list' );
    is( ( () = conf_text() =~ /^odoo_url:/mg ), 1, 'the keys no one touched are kept, once' );
    save( {}, { odoo_pack_dirs => '/srv/one' } );
    save( {}, { odoo_pack_dirs => '/srv/two' } );
    like( conf_text(), qr{^odoo_pack_dirs: /srv/one:/srv/two$}m, 'a directory list joins with its own separator' );
};

subtest 'add refuses what is not a list setting or not one plain item' => sub {
    my $before = conf_text();
    my $r      = save( {}, { odoo_url => 'https://x.example' } );
    is( $r->{ok},    0,          'a setting that is not a list takes no add' );
    is( $r->{field}, 'odoo_url', 'naming it' );
    $r = save( {}, { odoo_packs => "A::B\nodoo_url: https://evil.example" } );
    is( $r->{ok}, 0, 'an item with a line break is refused' );
    $r = save( {}, { odoo_packs => ['A::B,C::D'] } );
    is( $r->{ok},    0,       'an item carrying the separator is refused' );
    is( conf_text(), $before, 'and none of them wrote anything' );
};

subtest 'adding the second app leaves the first app\'s operations answering' => sub {
    write_conf( $d, odoo_url => 'https://odoo.example', odoo_db => 'shopdb', odoo_login => 'site-connection',
        odoo_allow_writes => 'true', odoo_packs => $PACK_A, odoo_daemon => 'on' );
    my $r = call_a();
    ok( $r->{ok}, 'before: app A answers' ) or diag explain $r;
    # The binding's stored declaration is stamped with the packs [A].
    save( {}, { odoo_packs => $PACK_B } );
    is( packs_line(), "$PACK_A,$PACK_B", 'app B is installed' );
    $r = call_a();
    ok( $r->{ok}, 'after: app A still answers (the stamp missed, the registry was read, the call went on)' )
        or diag explain $r;
    unlike( $r->{error} // '', qr/no operation/, 'and not "no operation installed"' );
    is( Lazysite::Odoo::last_via(), 'in-process', 'in-process, as oomd is not running (the restart window)' );
    # The old behaviour, a whole-value save from B's view alone, is what drops A:
    save( { odoo_packs => $PACK_B } );
    $r = call_a();
    ok( !$r->{ok}, 'a whole-value save of B alone does drop A (why the add exists)' );
    like( $r->{error} // '', qr/no operation 'shop\.products' is installed/, '...with the 404 the lab saw' );
};

done_testing;
