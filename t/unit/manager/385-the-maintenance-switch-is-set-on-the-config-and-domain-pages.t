#!/usr/bin/perl
# SM1118 (ruled 2026-10-20, #338): THE SWITCH, ITS PAGE AND ITS TIME ARE SETTINGS
# an operator reads and writes from the manager, per domain and for the instance.
#
#   Config page  maintenance (on|off), maintenance_page, maintenance_until:
#                config-read surfaces them, config-set stores them and refuses a
#                value the engine would read as something else
#   Domains page the same three, for ONE domain (an alias.<host>.* line), through
#                domain-set - and not on the create sheet, which would drop them
#
# THE SELF-LOCKOUT GUARD. Switching maintenance ON needs the capability yourself,
# on both pages: the account that closes the site to everyone else must be one the
# closed door lets back in, or the next request is refused and only the host can
# undo it.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);

my $root = repo_root();
plan skip_all => 'manager api missing' unless -f "$root/lazysite-manager-api.pl";

my @ALL = qw(ui api manage_config manage_domains manage_users manage_content maintenance_access);
my $s = new_site( root => $root );
my $d = $s->docroot;
make_path("$d/sites/a");
open my $ix, '>', "$d/sites/a/index.md" or die $!;
print {$ix} "# a\n";
close $ix;

$s->add_user($_) for qw(boss clerk);
$s->grant( 'boss', 'ops', [qw(ui manage_config manage_domains manage_users manage_content maintenance_access)], \@ALL );
$s->grant( 'clerk', 'clerks', [qw(ui manage_config manage_domains)], \@ALL );
sub call { my ( $who, $a, $b ) = @_; return $s->call( $who, $a, ( defined $b ? ( body => $b ) : () ) ) }
sub conf { open my $f, '<', "$d/lazysite/lazysite.conf" or die $!; local $/; return <$f> }
sub set { my ( $who, $k, $v ) = @_; return call( $who, 'config-set', { key => $k, value => $v } ) }

ok( call( 'boss', 'domain-add', { host => 'a.example.org', content_root => 'sites/a', site_url => 'https://a.example.org', site_name => 'A' } )->{ok},
    'a domain to put in maintenance' );

subtest 'config-read surfaces the three settings' => sub {
    my $r = call( 'boss', 'config-read' );
    ok( $r->{ok}, 'config-read answers' );
    for my $k (qw(maintenance maintenance_page maintenance_until)) {
        ok( exists $r->{config}{$k}, "...with $k" );
    }
};

subtest 'the switch takes on and off, nothing else' => sub {
    ok( set( 'boss', maintenance => 'on' )->{ok}, 'on' );
    like( conf(), qr/^maintenance: on$/m, '...is written' );
    ok( set( 'boss', maintenance => 'OFF' )->{ok}, 'off (any case)' );
    like( conf(), qr/^maintenance: off$/m, '...is written, lower case' );
    for my $bad ( 'yes please', 'enabled', 'true', '1', '' ) {
        my $r = set( 'boss', maintenance => $bad );
        ok( !$r->{ok}, "refused: '$bad'" );
        is( $r->{field}, 'maintenance', '...naming the field' ) if length $bad;
    }
    like( conf(), qr/^maintenance: off$/m, 'and the stored value is what it was' );
    is( call( 'boss', 'config-read' )->{config}{maintenance}, 'off', 'config-read says so' );
};

subtest 'you cannot close a door you cannot come back through' => sub {
    my $r = set( 'clerk', maintenance => 'on' );
    ok( !$r->{ok}, 'an account with manage_config and not the capability cannot switch it on' );
    is( $r->{kind}, 'forbidden', '...as forbidden' );
    like( $r->{error} // '', qr/maintenance_access/,  '...naming the capability' );
    like( conf(),            qr/^maintenance: off$/m, '...and nothing was written' );
    ok( set( 'clerk', maintenance => 'off' )->{ok}, 'switching it off needs nothing more' );
};

subtest 'the page is a path on the site or an https address' => sub {
    ok( set( 'boss', maintenance_page => '/closed' )->{ok}, '/closed' );
    ok( set( 'boss', maintenance_page => 'https://status.example.com/down' )->{ok}, 'an https address' );
    for my $bad ( 'closed', '//evil.example/x', 'javascript:alert(1)', 'http://plain.example/', '/a/../b', '/x?y=1' ) {
        my $r = set( 'boss', maintenance_page => $bad );
        ok( !$r->{ok}, "refused: $bad" );
        is( $r->{field}, 'maintenance_page', '...naming the field' );
    }
    like( conf(), qr{^maintenance_page: https://status\.example\.com/down$}m, 'the stored value is the last good one' );
    ok( set( 'boss', maintenance_page => '' )->{ok}, 'blank clears it (the default page)' );
    unlike( conf(), qr/^maintenance_page:\s*\S/m, '...leaving no value' );
};

subtest 'the time is a UTC time we can read' => sub {
    ok( set( 'boss', maintenance_until => '2026-11-01 18:30' )->{ok}, 'a time' );
    like( conf(), qr/^maintenance_until: 2026-11-01 18:30$/m, '...is written' );
    for my $bad ( 'soon', '2026-13-01 00:00', '18:30' ) {
        my $r = set( 'boss', maintenance_until => $bad );
        ok( !$r->{ok}, "refused: $bad" );
        is( $r->{field}, 'maintenance_until', '...naming the field' );
    }
    ok( set( 'boss', maintenance_until => '' )->{ok}, 'blank clears it' );
};

subtest 'a domain is put in maintenance by its own line' => sub {
    my $r = call( 'boss', 'domain-set', { host => 'a.example.org', key => 'maintenance', value => 'on' } );
    ok( $r->{ok}, 'domain-set maintenance on' ) or diag( $r->{error} // '' );
    like( conf(), qr/^alias\.a\.example\.org\.maintenance: on$/m, '...is an alias line for that host' );
    my ($row) = grep { $_->{host} eq 'a.example.org' } @{ call( 'boss', 'domains-list' )->{domains} };
    is( $row->{maintenance}, 'on', 'the domains list shows it' );
    ok( ( grep { $_ eq 'maintenance' } @{ call( 'boss', 'domains-list' )->{keys} } ), '...among the keys a domain can set' );
    ok( call( 'boss', 'domain-set', { host => 'a.example.org', key => 'maintenance_page', value => '/closed' } )->{ok}, 'its own page' );
    ok( call( 'boss', 'domain-set', { host => 'a.example.org', key => 'maintenance_until', value => '2026-11-01 18:30' } )->{ok}, 'its own time' );
    for my $bad ( [ maintenance => 'maybe' ], [ maintenance_page => 'closed' ], [ maintenance_until => 'soon' ] ) {
        my $x = call( 'boss', 'domain-set', { host => 'a.example.org', key => $bad->[0], value => $bad->[1] } );
        ok( !$x->{ok}, "refused: $bad->[0] = $bad->[1]" );
    }
    ok( call( 'boss', 'domain-set', { host => 'a.example.org', key => 'maintenance', value => '' } )->{ok}, 'blank clears the line' );
    unlike( conf(), qr/^alias\.a\.example\.org\.maintenance:\h*\S/m, '...so the domain follows the instance' );
};

subtest 'the same guard on a domain' => sub {
    my $r = call( 'clerk', 'domain-set', { host => 'a.example.org', key => 'maintenance', value => 'on' } );
    ok( !$r->{ok}, 'an account without the capability cannot put a domain in maintenance' );
    is( $r->{kind}, 'forbidden', '...as forbidden' );
    unlike( conf(), qr/^alias\.a\.example\.org\.maintenance:\h*\S/m, '...and nothing was written' );
};

subtest 'the pages carry the fields' => sub {
    my $cfg = do { open my $f, '<', "$root/starter/manager/config.md" or die $!; local $/; <$f> };
    like( $cfg, qr/key: 'maintenance',\s+label: 'Site in maintenance', type: 'toggle'/, 'Config: the switch is a toggle' );
    like( $cfg, qr/key: 'maintenance_page'/,  'Config: the page' );
    like( $cfg, qr/key: 'maintenance_until'/, 'Config: the time' );
    my $dom = do { open my $f, '<', "$root/starter/manager/domains.md" or die $!; local $/; <$f> };
    like( $dom, qr/EDIT_KEYS = \[[^\]]*'maintenance', 'maintenance_page', 'maintenance_until'\]/s, 'Domains: the editor carries them' );
    like( $dom, qr/title: 'Maintenance'.*editOnly: true/, '...in a section of their own' );
    like( $dom, qr/if \(isCreate && s\.editOnly\) return;/, '...which the create sheet does not offer (it would drop them)' );
};

done_testing;
