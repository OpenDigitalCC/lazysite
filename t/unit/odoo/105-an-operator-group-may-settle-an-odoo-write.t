#!/usr/bin/perl
# SM1276 (rulings 10a-10c, 2026-10-23): a change of an Odoo run whose answer never
# came, and that cannot be read back, is settled by a person: the run's own maker,
# or a holder of a new capability, `settle_odoo_writes`, who may decide on any run
# and dismiss one. The Odoo extension declares it (t/lint/76: a capability is core
# or plugin-owned), it is grantable (@CAP_KEYS), and an operator (manager) group
# holds it: on a new site, and by the SM645 top-up on a site seeded before it
# existed. A declined 0 stays declined.
use strict;
use warnings;
use Test::More;
use JSON::PP qw(decode_json encode_json);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(repo_root site_tempdir run_child);
use Lazysite::Auth::Settings ();
use Lazysite::Capabilities   ();

my $root = repo_root();
my $CAP  = 'settle_odoo_writes';

subtest 'the Odoo extension declares it, and it is grantable' => sub {
    my $r = run_child( [ $^X, "$root/extensions/odoo.pl", '--describe' ] );
    my $d = eval { decode_json( $r->{out} ) } || {};
    is_deeply( $d->{owns}{capabilities}, [$CAP], 'extensions/odoo.pl owns it' );
    ok( ( grep { $_ eq $CAP } @Lazysite::Auth::Settings::CAP_KEYS ), 'it is in @CAP_KEYS' );
    my $info = Lazysite::Capabilities::describe()->{capabilities}{$CAP};
    ok( $info, 'and described' );
    like( $info->{title} // '', qr/Settle an Odoo write/, 'by what it does' );
};

sub slurp { open my $f, '<', $_[0] or die "$_[0]: $!"; local $/; my $s = <$f>; close $f; return $s }
sub spit  { open my $f, '>', $_[0] or die "$_[0]: $!"; print {$f} $_[1]; close $f; return }
sub users {
    my ( $d, @args ) = @_;
    return run_child( [ $^X, "-I$root/lib", "$root/tools/lazysite-users.pl", '--docroot', $d, @args ], stderr => 'merge' );
}
sub sysops {
    my ($d) = @_;
    return decode_json( slurp("$d/lazysite/auth/groups-settings.json") )->{sysops} || {};
}

my $d = site_tempdir();
make_path("$d/lazysite/auth");
spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
my $r = users( $d, 'setup-sysop', '--user', 'sjm', 'pw123456789-long-enough' );
is( $r->{status}, 0, 'setup-sysop ran' ) or diag $r->{out};

subtest 'a new site\'s operator group holds it' => sub {
    is( sysops($d)->{$CAP}, 1, 'sysops holds it' );
};

subtest 'an operator group seeded before it existed is topped up, and a decline stays' => sub {
    my $p  = "$d/lazysite/auth/groups-settings.json";
    my $gs = decode_json( slurp($p) );
    delete $gs->{sysops}{$CAP};
    spit( $p, JSON::PP->new->canonical->encode($gs) );
    ok( !exists sysops($d)->{$CAP}, 'aged: never decided' );
    my $t = users( $d, 'group-reach', 'sysops' );
    is( sysops($d)->{$CAP}, 1, 'the top-up grants it' ) or diag $t->{out};

    $gs = decode_json( slurp($p) );
    $gs->{sysops}{$CAP} = 0;
    spit( $p, JSON::PP->new->canonical->encode($gs) );
    users( $d, 'group-reach', 'sysops' );
    is( sysops($d)->{$CAP}, 0, 'a declined 0 is left as the operator decided' );
};

done_testing;
