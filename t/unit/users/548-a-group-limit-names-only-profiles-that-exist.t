#!/usr/bin/perl
# n812 (ruling 234): ADDRESS LISTS ARE PREDEFINED AND SELECTABLE ONLY. A group's
# address limit (group-settings-set: addresses, addresses_deny, address_limit) that
# names a profile the store does not hold is refused, naming it, and nothing is
# written - as a file or folder rule is (t/integration/730). Before, the Groups page's
# door took any valid-looking name, and the group's grants then counted from no
# address at all.
#
# Sabotage: drop the missing-profile block from the address-limit branch of
# group-settings-set in tools/lazysite-users.pl and the refusals fail.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(site_tempdir run_child);

my $script = "$FindBin::Bin/../../../tools/lazysite-users.pl";

sub api {
    my ( $d, $req ) = @_;
    my $out = run_child( [ $^X, $script, '--docroot', $d, '--api' ], stdin => encode_json($req), stderr => 'inherit' )->{out} // '';
    my ($json) = $out =~ /(\{.*\})/s;
    return eval { decode_json($json) } || { ok => 0, error => "unparsed: $out" };
}
sub store { my ($d) = @_; open my $fh, '<', "$d/lazysite/auth/groups-settings.json" or return {}; local $/; decode_json(<$fh>) }

my $d = site_tempdir();
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;
run_child( [ $^X, $script, '--docroot', $d, 'setup-sysop', '--user', 'op', 'secretpw1234' ], stderr => 'inherit' );
api( $d, { action => 'group-create', group => 'g-ed' } );    # n818: the group exists before a limit is set on it
run_child( [ $^X, $script, '--docroot', $d, 'address-profile-set', 'office', '--entry', '203.0.113.0/24' ], stderr => 'inherit' );

my $set = sub { api( $d, { action => 'group-settings-set', group => 'g-ed', key => $_[0], value => $_[1], actor => 'op' } ) };

subtest 'a profile the store lacks is refused, naming it, whichever key carries it' => sub {
    for my $c ( [ addresses => 'zz92-allow' ], [ addresses_deny => 'zz92-allow, office' ],
        [ address_limit => { addresses => ['zz92-allow'], addresses_deny => [] } ] ) {
        my ( $k, $v ) = @$c;
        my $r = $set->( $k, $v );
        ok( !$r->{ok}, "$k: refused" ) or diag explain $r;
        like( $r->{error} // '', qr/zz92-allow/, "$k: naming the missing profile" );
        unlike( $r->{error} // '', qr/\boffice\b/, "$k: and not the one that exists" );
        ok( !exists( store($d)->{'g-ed'}{addresses} ) && !exists( store($d)->{'g-ed'}{addresses_deny} ), "$k: the group has no limit" );
    }
};

subtest 'a profile the store holds is accepted, and clearing needs none' => sub {
    my $r = $set->( 'addresses', 'office' );
    ok( $r->{ok}, 'accepted' ) or diag explain $r;
    is_deeply( store($d)->{'g-ed'}{addresses}, ['office'], 'and stored' );
    $r = $set->( 'addresses', '' );
    ok( $r->{ok}, 'an empty value clears' ) or diag explain $r;
    ok( !exists store($d)->{'g-ed'}{addresses}, 'and it clears' );
};

done_testing();
