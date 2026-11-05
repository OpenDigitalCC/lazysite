#!/usr/bin/perl
# SM675: a capability owned by an extension grants nothing while that extension is off,
# and the Groups grid offered it as an ordinary checkbox.
#
# manage_data grants no table access with the data extension disabled;
# manage_briefs grants no brief action with briefs disabled - every one returns
# "the briefs extension is disabled" before it looks at capabilities at all. An
# operator granted one, the grid showed it on, whoami reported it held, and the
# surface refused.
#
# MARKED, NOT HIDDEN, and that is the decision worth defending. A group already
# holding the capability keeps holding it when the extension goes off; hiding the
# row would hide a grant still recorded in the store, which the operator could
# then neither see, audit nor revoke. SM439, SM615 and SM668 each closed exactly
# that shape - no hidden case where access is active or potentially active.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper     qw(repo_root);
use ManagerSession qw(new_site);

plan skip_all => 'manager api missing' unless -f repo_root() . '/lazysite-manager-api.pl';

sub site_with {
    my ($extensions) = @_;
    my $s = new_site(
        root => repo_root(),
        conf => "site_name: T\ncontrol_api_enabled: true\n"
            . ( $extensions ? "extensions:\n" . join( '', map {"  - $_\n"} @{$extensions} ) : '' )
    );
    $s->add_user('boss');
    $s->grant( 'boss', 'bosses', [qw(ui manage_users manage_config)],
        [qw(ui manage_users manage_config manage_data manage_briefs)] );
    return $s;
}

subtest 'the map is DERIVED from what each extension declares it owns' => sub {
    my $s = site_with( ['extensions/data.pl'] );
    my $r = $s->call( 'boss', 'channel-services' );
    ok( $r->{ok}, 'the call succeeds' ) or diag( $r->{error} // '' );

    my $cp = $r->{capability_extension} || {};
    ok( $cp->{manage_data}, 'manage_data is reported as extension-owned' )
        or diag( 'The data extension declares owns.capabilities; a hand-kept map '
            . 'here would be another copy of a fact the extension already states.' );
    is( $cp->{manage_data}{extension}, 'data', 'naming the extension that owns it' );

    # THE DERIVATION ITSELF, rather than a roll-call of capability names. Every
    # entry must correspond to a declaration in the extension it names - that is
    # the property that keeps this map from becoming another hand-kept copy,
    # and it holds whatever capabilities exist, so a capability added later
    # (SM682's write_data, say) appears here without this test changing.
    my $pl = $s->call( 'boss', 'extension-list' );
    my %declared;
    for my $p ( @{ $pl->{extensions} || [] } ) {
        next unless ref $p->{owns} eq 'HASH' && ref $p->{owns}{capabilities} eq 'ARRAY';
        $declared{$_} = $p->{id} for @{ $p->{owns}{capabilities} };
    }
    my @wrong = grep { ( $cp->{$_}{extension} // '' ) ne ( $declared{$_} // '' ) }
        sort keys %{$cp};
    is_deeply( \@wrong, [],
        'every entry names the extension that actually declares it' )
        or diag( 'The map must be derived from owns.capabilities, not listed '
            . 'here - a hand-kept copy is wrong the first time an extension '
            . 'changes.' );
};

subtest 'enabled and disabled are told apart' => sub {
    my $on = site_with( ['extensions/data.pl'] );
    my $r1 = $on->call( 'boss', 'channel-services' );
    is( ( $r1->{capability_extension} || {} )->{manage_data}{enabled}, JSON::PP::true,
        'an enabled extension reports enabled' );

    my $off = site_with( [] );    # no extensions at all
    my $r2  = $off->call( 'boss', 'channel-services' );
    my $cp  = $r2->{capability_extension} || {};
    if ( $cp->{manage_data} ) {
        is( $cp->{manage_data}{enabled}, JSON::PP::false,
            'a disabled extension reports disabled' )
            or diag( 'If a disabled extension reported enabled, the grid would '
                . 'stay silent about exactly the case this exists for.' );
    }
    else {
        pass( 'an extension that is not installed is simply absent from the map' );
    }
};

subtest 'the grid marks it, and does not hide it' => sub {
    my $src = do {
        open my $fh, '<', repo_root() . '/starter/manager/groups.md' or die $!;
        local $/;
        <$fh>;
    };
    like( $src, qr/capabilityExtension\[c\[0\]\]/,
        'the grid consults the map' );
    like( $src, qr/owner\.enabled === false/,
        'and marks a capability whose extension is off' );

    # The row must still RENDER. A `return ''` or a filter on the capability
    # list would hide a grant that is still in the store.
    unlike( $src, qr/owner\.enabled === false\s*\)\s*\{\s*return/,
        'the row is not suppressed when the extension is off' )
        or diag( 'Hiding it would hide a grant the group still holds - which '
            . 'SM439, SM615 and SM668 each closed elsewhere.' );
};

done_testing();
