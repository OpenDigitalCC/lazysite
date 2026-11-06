#!/usr/bin/perl
# SM1371 (ruling 122): A GRANT THAT NEEDS AN EXTENSION NAMES IT, AND THE MANAGER
# OFFERS THE ENABLE IN THE SAME STEP.
#
# Granting manage_data while the data extension is off did nothing (SM675 marks
# such a grant dormant on the grid), and the operator was left to find the
# Extensions page. The capability map the Groups page reads now carries the
# owning extension's script - what extension-enable takes - and ticking the
# grant asks whether to enable it there and then. The enable stays its own
# explicit act (a confirm) through extension-enable, which needs manage_config
# and is audited like every other extension switch.
#
# With the change reverted: capability_extension carries no `script`, and the
# Groups page has no offer after a grant.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);

my $root = repo_root();

subtest 'the capability map names the extension and its script' => sub {
    my $s = new_site( root => $root, conf => "control_api_enabled: true\n" );
    $s->add_user('boss');
    $s->grant( 'boss', 'admins', [qw(ui manage_users manage_config)], [qw(ui manage_users manage_config)] );
    my $r = $s->call( 'boss', 'channel-services', query => 'action=channel-services' );
    ok( $r->{ok}, 'channel-services answers' ) or diag explain $r;
    my $e = ( $r->{capability_extension} || {} )->{manage_data};
    ok( $e, 'manage_data is owned by an extension' ) or return;
    is( $e->{extension}, 'data', '...the data extension' );
    ok( !$e->{enabled}, '...which is off here' );
    like( $e->{script} // '', qr{data\.pl\z}, '...and the map carries the script extension-enable takes' );
    my $w = ( $r->{capability_extension} || {} )->{write_data};
    is( $w && $w->{script}, $e->{script}, 'write_data names the same extension' );
};

subtest 'the Groups page offers the enable when the grant is made' => sub {
    my $src = do { open my $fh, '<', "$root/starter/manager/groups.md" or die $!; local $/; <$fh> };
    my ($toggle) = $src =~ /(function toggleSetting\b.*?\n\})/s;
    ok( $toggle, 'toggleSetting located' );
    like( $toggle, qr/if \(on\) offerExtensionFor\(key\)/, 'a grant switched ON asks about its extension' );
    my ($offer) = $src =~ /(function offerExtensionFor\b.*?\n\})/s;
    ok( $offer, 'offerExtensionFor located' ) or return;
    like( $offer, qr/owner\.enabled !== false/, 'only when the owning extension is off' );
    like( $offer, qr/mgConfirm\(/, 'the enable is a question the operator answers' );
    like( $offer, qr/action=extension-enable/, '...answered through extension-enable' );
    like( $offer, qr/script: owner\.script/, '...with the script the map names' );
    like( $offer, qr/needs the ' \+ name/, 'and the question names the extension' );
};

done_testing();
