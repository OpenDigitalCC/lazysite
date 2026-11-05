#!/usr/bin/perl
# SM1333 (ruling 78): THE PRIMARY IS A ROW IN THE DOMAIN LIST, AND ITS ACCESS IS
# SET THERE LIKE ANY DOMAIN'S.
#
# SM1332 made the primary grantable (the bare `allowed_groups:` line). This is
# the write and the listing on the surfaces: domain-set and domain_access_edit
# take the host '(default)' for the access keys (and only those), every listing
# shows the primary's row with its own access, and a secondary row no longer
# shows the primary's access as inherited - DomainAccess never inherited it, and
# Groups reads the row. End to end on the manager API: a manager scoped to one
# domain is shown the primary once the operator names its group on the
# primary's row, and not before.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);
use lib repo_root() . '/lib';
use Lazysite::Manager::Domains ();

plan skip_all => 'manager api missing' unless -f repo_root() . '/lazysite-manager-api.pl';

my @ALL = qw(ui manage_domains manage_users manage_config manage_content);
my $s   = new_site( root => repo_root() );
$s->add_user('boss');
$s->grant( 'boss', 'bosses', [qw(ui manage_domains manage_users)], \@ALL );
$s->add_user('dm');
$s->grant( 'dm', 'domainfolk', [qw(ui manage_domains)], \@ALL );
$s->add_user('ot');
$s->users( 'group-add', 'ot', 'others' );
$Lazysite::Manager::Domains::DOCROOT = $s->docroot;

sub conf {
    open my $fh, '<', $s->docroot . '/lazysite/lazysite.conf' or die $!;
    local $/;
    return scalar <$fh>;
}
sub row { my ( $r, $h ) = @_; my ($d) = grep { $_->{host} eq $h } @{ $r->{domains} || [] }; return $d }
sub hosts { my ($r) = @_; return [ map { $_->{host} } @{ $r->{domains} || [] } ] }

my $add = $s->call( 'boss', 'domain-add',
    body => { host => 'mine.example.org', content_root => 'sites/mine',
        site_url => 'https://mine.example.org', site_name => 'Mine' } );
ok( $add->{ok}, 'set up mine.example.org' ) or diag( $add->{error} // '' );
ok( $s->call( 'boss', 'domain-set', body => { host => 'mine.example.org', key => 'allowed_groups', value => 'domainfolk' } )->{ok},
    'dm is scoped to mine.example.org' );

subtest 'scoped to a secondary: the primary is not listed (today)' => sub {
    my $r = $s->call( 'dm', 'domains-list' );
    ok( $r->{ok}, 'domains-list' ) or diag( $r->{error} // '' );
    is_deeply( hosts($r), ['mine.example.org'], 'its domain only' );
};

subtest 'the operator grants the primary on its row' => sub {
    my $r = $s->call( 'boss', 'domain-set', body => { host => '(default)', key => 'allowed_groups', value => '@domainfolk' } );
    ok( $r->{ok}, 'domain-set on (default)' ) or diag( $r->{error} // '' );
    is( $r->{host}, '(default)', 'answered for the primary' );
    like( conf(), qr/^allowed_groups: domainfolk$/m, 'the bare line, the plain name' );
    unlike( conf(), qr/^alias\.\(default\)/m, 'not an alias line' );
};

subtest 'grants add: the scoped manager now reaches both' => sub {
    my $r = $s->call( 'dm', 'domains-list' );
    is_deeply( hosts($r), [ '(default)', 'mine.example.org' ], 'the primary and its domain' );
    is( row( $r, '(default)' )->{allowed_groups}, 'domainfolk', 'the primary row shows its own access' );
    is( row( $r, 'mine.example.org' )->{allowed_groups}, 'domainfolk', 'the secondary shows its own' );
};

subtest 'a secondary does not inherit the primary\'s access' => sub {
    ok( $s->call( 'boss', 'domain-set', body => { host => 'mine.example.org', key => 'allowed_groups', value => 'bosses' } )->{ok},
        'mine.example.org names another group' );
    ok( $s->call( 'boss', 'domain-set', body => { host => 'mine.example.org', key => 'allowed_groups', value => '' } )->{ok},
        '...then none' );
    my $r = $s->call( 'boss', 'domains-list' );
    my $m = row( $r, 'mine.example.org' );
    is( $m->{allowed_groups}, '', 'its access is empty, not the primary\'s' );
    ok( !$m->{allowed_groups_inherited}, '...and not shown as inherited' );
    my $d = Lazysite::Manager::Domains::domains_list();
    is( row( $d, 'mine.example.org' )->{allowed_groups}, '', 'the module listing agrees' );
    is( row( $d, '(default)' )->{allowed_groups}, 'domainfolk', 'and shows the primary row' );
    # A domain that never had an access line of its own.
    ok( $s->call( 'boss', 'domain-add', body => { host => 'bare.example.org', content_root => 'sites/bare',
                site_url => 'https://bare.example.org', site_name => 'Bare' } )->{ok}, 'bare.example.org added' );
    my $b = row( $s->call( 'boss', 'domains-list' ), 'bare.example.org' );
    is( $b->{allowed_groups}, '', 'domains-list: no access line, no access - not the primary\'s' );
    ok( !$b->{allowed_groups_inherited}, '...and not shown as inherited' );
    my $bm = row( Lazysite::Manager::Domains::domains_list(), 'bare.example.org' );
    is( $bm->{allowed_groups}, '', 'domains_list (MCP list_domains, Groups) likewise' );
    ok( !$bm->{allowed_groups_inherited}, '...not inherited' );
};

subtest 'the primary row takes its access keys only, and names that exist' => sub {
    my $r = $s->call( 'boss', 'domain-set', body => { host => '(default)', key => 'site_name', value => 'X' } );
    ok( !$r->{ok}, 'site_name on the primary row is refused' );
    like( $r->{error} // '', qr/access keys here.*Config page/, '...pointing at Config' );
    $r = $s->call( 'boss', 'domain-set', body => { host => '(default)', key => 'allowed_groups', value => 'nosuch' } );
    is( $r->{kind}, 'unknown-principals', 'a group the site does not have is refused' );
    like( $r->{error}, qr/\(default\)'s allowed_groups is unchanged/, '...naming the row' );
};

subtest 'one name in or out of the primary row (lazysite-domains group-add)' => sub {
    no warnings 'once';
    local $Lazysite::Auth::Settings::AUTH_DIR  = $s->docroot . '/lazysite/auth';
    my $r = Lazysite::Manager::Domains::domain_access_edit( '(default)', 'allowed_groups', 'add', '@others' );
    ok( $r->{ok} && $r->{changed}, 'added' ) or diag( $r->{error} // '' );
    is( $r->{value}, 'domainfolk, others', 'the others kept' );
    $r = Lazysite::Manager::Domains::domain_access_edit( '', 'allowed_groups', 'add', 'others' );
    ok( $r->{ok} && !$r->{changed}, '"" is the primary too; already there, nothing changed' );
    $r = Lazysite::Manager::Domains::domain_access_edit( '(default)', 'allowed_groups', 'remove', 'domainfolk' );
    is( $r->{value}, 'others', 'removed' );
    like( conf(), qr/^allowed_groups: others$/m, 'the bare line is the list' );
};

subtest 'taken off the primary row: the scoped manager loses the primary again' => sub {
    ok( $s->call( 'boss', 'domain-set', body => { host => 'mine.example.org', key => 'allowed_groups', value => 'domainfolk' } )->{ok},
        'dm is scoped to mine.example.org again' );
    is_deeply( hosts( $s->call( 'dm', 'domains-list' ) ), ['mine.example.org'],
        'the primary row names others only: its domain, no primary' );
};

# A grant on the primary's row confines as a grant on any row does: a manager
# (not the operator group, which is never confined) whose group no domain named
# reached every domain, and one whose group only the primary's row names reaches
# the primary (and the domains serving its content).
subtest 'a group named only on the primary row is confined to the primary' => sub {
    ok( $s->call( 'boss', 'domain-set', body => { host => '(default)', key => 'allowed_groups', value => 'others, bosses' } )->{ok},
        'the operator names its own group on the primary row' );
    is_deeply( hosts( $s->call( 'boss', 'domains-list' ) ), ['(default)'], 'and now reaches the primary only' );
    my $r = $s->call( 'boss', 'domain-set', body => { host => 'mine.example.org', key => 'site_name', value => 'X' } );
    like( $r->{error} // '', qr/outside your assigned scope \(the primary site\)/, 'its scope is named as the primary site' );
    ok( $s->call( 'boss', 'domain-set', body => { host => '(default)', key => 'allowed_groups', value => 'others' } )->{ok},
        'it reaches the primary row, so it can take itself off it' );
    is_deeply( hosts( $s->call( 'boss', 'domains-list' ) ), [ '(default)', 'mine.example.org', 'bare.example.org' ], 'and reaches every domain again' );
};

# SM1334: the group pin is an access key like the others.
subtest 'locked_groups is set as an access key' => sub {
    my $r = $s->call( 'boss', 'domain-set', body => { host => 'mine.example.org', key => 'locked_groups', value => '@others' } );
    ok( $r->{ok}, 'domain-set locked_groups' ) or diag( $r->{error} // '' );
    like( conf(), qr/^alias\.mine\.example\.org\.locked_groups: others$/m, 'stored as the plain name' );
    is( row( $s->call( 'boss', 'domains-list' ), 'mine.example.org' )->{locked_groups}, 'others', 'listed' );
    $r = $s->call( 'boss', 'domain-set', body => { host => '(default)', key => 'locked_groups', value => 'others' } );
    ok( $r->{ok}, 'and on the primary row' ) or diag( $r->{error} // '' );
    like( conf(), qr/^locked_groups: others$/m, 'the bare line' );
    $r = $s->call( 'boss', 'domain-set', body => { host => 'mine.example.org', key => 'locked_groups', value => 'nosuch' } );
    is( $r->{kind}, 'unknown-principals', 'a group the site does not have is refused' );
    $r = $s->call( 'dm', 'domain-set', body => { host => 'mine.example.org', key => 'locked_groups', value => '' } );
    like( $r->{error} // '', qr/Users & groups/, 'without manage_users it is refused, as the other access keys are' );
};

done_testing();
