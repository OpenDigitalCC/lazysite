#!/usr/bin/perl
# SM622/SM623: the services a connection needs, said before the operator spends
# time on one that cannot work.
#
# The 0.9.0 killswitches turned every remote surface off by default, which is
# the right posture and left two holes in the manager:
#
#   1. The connector panel minted a connect code, started a 30-minute countdown
#      and polled for a connection that could not happen, because mcp_enabled or
#      oauth_enabled was off. What the operator sees is a code that "did not
#      work" - with a Regenerate button beside it - so the code gets blamed and
#      re-minted. Exactly the misreading SM621 documents for the OAuth-client
#      radio, arriving from a different direction.
#   2. The five toggles were ordered by when they were added, so the two a web
#      connector needs sat either side of one it does not.
#
# THE COUPLING THIS TEST EXISTS FOR: the preset sets are written out by hand,
# because the schema says which GROUP a toggle is in and the preset says what a
# WORKING setup is - allowed to differ. Allowed to differ is exactly how a
# toggle joins a group and is silently left out of its own button, so the two
# are pinned to each other here.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;

my $page = "$FindBin::Bin/../../../starter/manager/config.md";
plan skip_all => "no $page" unless -f $page;
chomp( my $node = `sh -c 'command -v node || command -v nodejs' 2>/dev/null` );
plan skip_all => 'node not installed' unless length $node && -x $node;

my $src = do { open my $fh, '<', $page or die $!; local $/; <$fh> };

my ($presets) = $src =~ /(var SERVICE_PRESETS = \{.*?\n\};)/s;
ok( $presets, 'the page defines the service presets' ) or do { done_testing(); exit };

# Every service toggle, with the group it sits in - read from the schema text
# rather than restated here, so this cannot drift from the page.
my %group_of;
while ( $src =~ /\{ key: '(\w+_enabled)',.*?group: '([^']+)'/gs ) {
    $group_of{$1} = $2;
}
ok( scalar keys %group_of >= 5, 'found the service toggles and their groups' )
    or diag( explain \%group_of );

my $dir = tempdir( CLEANUP => 1 );
open my $js, '>', "$dir/p.js" or die $!;
print {$js} "$presets\nconsole.log(JSON.stringify(SERVICE_PRESETS));\n";
close $js;
my $got = eval {
    require JSON::PP;
    JSON::PP::decode_json(`\Q$node\E \Q$dir/p.js\E 2>&1`);
};
ok( $got, 'the presets evaluate' ) or do { done_testing(); exit };

# --- 1. each preset covers exactly its own group ----------------------------
# Which group a preset belongs to is read from the field carrying group_preset,
# so adding a group needs no change here.
my %preset_group;
while ( $src =~ /group: '([^']+)', group_preset: '(\w+)'/g ) { $preset_group{$2} = $1 }
is( scalar keys %preset_group, scalar keys %$got,
    'every preset is anchored to a group, and every anchored group has a preset' )
    or diag( explain [ \%preset_group, [ sort keys %$got ] ] );

for my $name ( sort keys %$got ) {
    my $grp = $preset_group{$name};
    ok( $grp, "preset '$name' names a group" ) or next;

    my @in_group  = sort grep { $group_of{$_} eq $grp } keys %group_of;
    my @in_preset = sort keys %{ $got->{$name}{sets} };

    is_deeply( \@in_preset, \@in_group,
        "preset '$name' sets exactly the toggles in its group - no member left behind" )
        or diag("group: @in_group\npreset: @in_preset");

    # A preset that turned something OFF would be a different and much more
    # dangerous control than the one the button promises.
    my @off = grep { $got->{$name}{sets}{$_} ne 'enabled' } @in_preset;
    is_deeply( \@off, [], "preset '$name' only turns things ON" );
}

# --- 2. the web and agent groups are actually different ---------------------
# The whole point of the split. If both presets set the same keys the grouping
# is decoration.
{
    my @web   = sort keys %{ $got->{web}{sets}   || {} };
    my @agent = sort keys %{ $got->{agent}{sets} || {} };
    isnt( join( ',', @web ), join( ',', @agent ),
        'the two connection types need different services' );
    ok( ( grep { $_ eq 'oauth_enabled' } @web ),
        'the WEB preset includes OAuth - without it the sign-in prompt never appears' );
    ok( !( grep { $_ eq 'oauth_enabled' } @agent ),
        'and the AGENT preset does not, because a token is presented directly' );
    ok( ( grep { $_ eq 'token_exchange_enabled' } @agent ),
        'the AGENT preset includes the pairing-key exchange - without it a brief cannot be redeemed' );
}

# --- 3. the preset does not save --------------------------------------------
# Turning a remote surface on is exactly the change that should be looked at
# once before it reaches a live site.
{
    my ($fn) = $src =~ /(function applyPreset\(name\).*?\n\})/s;
    ok( $fn, 'applyPreset is present' );
    unlike( $fn, qr/saveSiteSettings|apiCall/,
        'applying a preset does not save by itself' );
    like( $fn, qr/markSiteDirty/, 'it marks the form dirty so Save is offered' );
    like( $fn, qr/press Save/,    'and says plainly that nothing is applied yet' );
}

done_testing();
