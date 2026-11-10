#!/usr/bin/perl
# SM1422 (ruling 214, Q129): A MANAGE_CONFIG HOLDER CANNOT POINT A NEW MAP ENTRY
# AT A CAPABILITY GROUP THE MAP ALREADY NAMES.
#
# Found against a real provider (n801, a local authentik): the operator saved
# `staff = staff`, where the site group `staff` carries a capability; an account
# holding only manage_config then saved `members = staff` beside it, and every
# member of the provider's `members` group signed in holding the capability. The
# check kept any entry whose site group the stored map already named; what it
# keeps is the entry, the provider group and the site group together.
#
# Through the real manager API (extension-save), as the settings form sends it:
#
#   * the editor's new entry to a capability group the map already names, from
#     another provider group, is refused `forbidden` and nothing is written;
#   * so is moving the operator's entry to another provider group;
#   * the editor still keeps the operator's entry while adding a plain-group one;
#   * the operator may add the entry the editor was refused.
#
# Sabotage: put back the target-only comparison in validate_group_map (an entry is
# kept when any stored entry names its site group); the first two refusals pass.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper     qw(repo_root index_extensions);
use ManagerSession qw(new_site);

$ENV{LAZYSITE_LOG_LEVEL} = 'ERROR';
my $root = repo_root();
my $s    = new_site( root => $root,
    conf => "control_api_enabled: true\nextensions:\n  - extensions/oidc.pl\n" );
my $d  = $s->docroot;
my $lz = "$d/lazysite";
sub slurp { my ($p) = @_; open my $fh, '<', $p or return ''; local $/; my $t = <$fh>; close $fh; return $t }
my $idx = index_extensions($d);
ok( ( grep { $_ eq 'oidc' } @{ $idx->{indexed} || [] } ), 'the OIDC extension is on and indexed' ) or diag explain $idx;

# The operator, an editor holding manage_config, and `staff`, which carries a capability.
$s->add_user('boss');
$s->users( 'group-add', 'boss', 'ops' );
$s->users( 'group-set', 'ops', 'manager', 'on' );
$s->add_user('ed');
$s->grant( 'ed', 'config-eds', [qw(ui manage_config)], [qw(ui manage_config)] );
$s->add_user('sam');
$s->grant( 'sam', 'staff', ['analytics'], ['analytics'] );

sub save {
    my ( $who, @map ) = @_;
    return $s->call( $who, 'extension-save', query => 'action=extension-save&extension=oidc',
        body => { script => 'extensions/oidc.pl', values => { providers => [
            { name => 'corp', issuer => 'http://127.0.0.1:9/corp', client_id => 'example-site', group_map => \@map } ] } },
        groups => 1 );
}
sub map_line { return ( slurp("$lz/oidc.conf") =~ /^corp\.group_map: (.*)$/m )[0] // '' }

my $r = save( 'boss', [qw(staff staff)] );
ok( $r->{ok}, 'the operator maps staff = staff' ) or diag explain $r;

subtest 'a new entry to a capability group the map already names' => sub {
    $r = save( 'ed', [qw(staff staff)], [qw(members staff)] );
    is( $r->{kind}, 'forbidden', 'the editor adding members = staff is refused' ) or diag explain $r;
    like( $r->{error} // '', qr/'staff' carries capabilities.*only the operator/, '...saying why' );
    is( $s->last_status, 403, '...as 403' );
    is( map_line(), 'staff = staff', '...and nothing is written' );
    $r = save( 'ed', [qw(everyone staff)] );
    is( $r->{kind}, 'forbidden', 'moving the entry to another provider group is refused too' ) or diag explain $r;
    is( map_line(), 'staff = staff', '...and nothing is written' );
};

subtest 'what the editor may still do, and the operator' => sub {
    $r = save( 'ed', [qw(staff staff)], [qw(members readers)] );
    ok( $r->{ok}, 'the editor keeps the operator\'s entry while adding a plain-group one' ) or diag explain $r;
    is( map_line(), 'staff = staff, members = readers', '...both written' );
    $r = save( 'boss', [qw(staff staff)], [qw(members readers)], [qw(members staff)] );
    ok( $r->{ok}, 'the operator may add members = staff' ) or diag explain $r;
    $r = save( 'ed', [qw(staff staff)], [qw(members readers)], [qw(members staff)] );
    ok( $r->{ok}, '...which the editor then keeps' ) or diag explain $r;
};

done_testing;
