#!/usr/bin/perl
# n818 (SM1440, field finding O-1 of the 0.16.11 pass): group-settings-set with
# address_limit (or addresses, addresses_deny) on a group that does not exist said
# the profile was missing, because the profile check ran before the group was
# looked up. The group is looked up first; nothing is written.
#
# Sabotage: drop the group lookup in the address branch of cmd_group_settings_set in
# tools/lazysite-users.pl and the first subtest fails.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir run_child);

my $script = repo_root() . '/tools/lazysite-users.pl';

sub api {
    my ($req) = @_;
    my $out = run_child( [ $^X, $script, '--docroot', $main::d, '--api' ], stdin => encode_json($req), stderr => 'inherit' )->{out} // '';
    my ($json) = $out =~ /(\{.*\})/s;
    return eval { decode_json($json) } || { ok => 0, error => "unparsed: $out" };
}
sub store { open my $fh, '<', "$main::d/lazysite/auth/groups-settings.json" or return {}; local $/; decode_json(<$fh>) }

our $d = site_tempdir();
make_path("$d/lazysite/auth");
open my $cf, '>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;
run_child( [ $^X, $script, '--docroot', $d, 'setup-sysop', '--user', 'op', 'secretpw1234' ], stderr => 'inherit' );
api( { action => 'group-create', group => 'g-ed' } );

my $set = sub { my ( $g, $k, $v ) = @_; api( { action => 'group-settings-set', group => $g, key => $k, value => $v, actor => 'op' } ) };

subtest 'a missing group is named as missing, before the profile' => sub {
    for my $c ( [ address_limit => { addresses => ['zz93-none'], addresses_deny => [] } ],
        [ addresses => 'zz93-none' ], [ addresses_deny => 'zz93-none' ] ) {
        my ( $k, $v ) = @$c;
        my $r = $set->( 'zz93-nogroup', $k, $v );
        ok( !$r->{ok}, "$k: refused" ) or diag explain $r;
        like( $r->{error} // '', qr/group 'zz93-nogroup' does not exist/, "$k: the group is the thing said to be missing" );
        unlike( $r->{error} // '', qr/address profile/i, "$k: and no profile is mentioned" );
        like( $r->{error} // '', qr/Nothing was changed/, "$k: nothing changed" );
        ok( !exists store()->{'zz93-nogroup'}, "$k: no group record was made" );
    }
};

subtest 'a group that exists still gets the missing-profile refusal' => sub {
    my $r = $set->( 'g-ed', 'addresses', 'zz93-none' );
    ok( !$r->{ok}, 'refused' );
    like( $r->{error} // '', qr/address profile.*zz93-none/, 'naming the profile' );
};

done_testing();
