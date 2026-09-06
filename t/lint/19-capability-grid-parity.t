#!/usr/bin/perl
# DRIFT GUARD: the Groups page renders a capability grid (CHANNELS + ACTIONS) an
# operator ticks to grant caps, and the Users page renders a read-only grid
# (PERM_LABELS). Both are hand-maintained JS literals that MUST list every key in
# @CAP_KEYS - otherwise a capability is enforced but ungrantable / invisible in
# the UI (the 0.9.x bug: `feedback` and `notifications` were enforced but missing
# from both grids, so no operator could grant feedback from the manager UI). This
# fails the build unless both grids match @CAP_KEYS exactly - the mechanical
# replacement for the "must match @CAP_KEYS" comment that this class slipped past.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);
use Lazysite::Auth::Settings ();

my $root = repo_root();
sub slurp { open my $fh, '<', $_[0] or die "$_[0]: $!"; local $/; <$fh> }

my @cap_keys = @Lazysite::Auth::Settings::CAP_KEYS;
cmp_ok( scalar @cap_keys, '>=', 16, '@CAP_KEYS is populated' );
my %is_cap = map { $_ => 1 } @cap_keys;

# --- Groups page: CHANNELS + ACTIONS grid --------------------------------------
my $groups = slurp("$root/starter/manager/groups.md");
my %grid;
for my $var (qw(CHANNELS ACTIONS)) {
    my ($blk) = $groups =~ /var \Q$var\E = \[(.*?)\];/s;
    ok( $blk, "groups.md defines $var" );
    $grid{$_} = 1 for ( ( $blk // '' ) =~ /\[\s*'([a-z0-9_]+)'/g );
}
is_deeply( [ sort keys %grid ], [ sort @cap_keys ],
    'groups.md capability grid (CHANNELS+ACTIONS) lists exactly @CAP_KEYS - every capability is grantable in the UI' )
    or diag "grid-only: @{[ sort grep { !$is_cap{$_} } keys %grid ]} | caps-missing-from-grid: @{[ sort grep { !$grid{$_} } @cap_keys ]}";

# --- SM758: every action is shown under exactly one category ------------------
# The grids on the Groups and Users pages are drawn by sections() from the
# capability registry, so the category lives beside the title and the grant
# sentence rather than in either page's JavaScript. Every action must declare
# one of @SECTIONS; sections() must then list each action exactly once.
{
    require Lazysite::Capabilities;
    my %known = map { $_ => 1 } @Lazysite::Capabilities::SECTIONS;
    my @actions = Lazysite::Capabilities::action_keys();
    my @unsectioned = grep { !$known{ Lazysite::Capabilities::section($_) // '' } } @actions;
    is_deeply( \@unsectioned, [], 'every action declares a section from @SECTIONS' )
        or diag "no section, or one not in \@SECTIONS: @unsectioned";
    my @listed = map { @{ $_->[1] } } @{ Lazysite::Capabilities::sections() };
    is_deeply( [ sort @listed ], [ sort @actions ], 'sections() lists every action exactly once' );
    unlike( $groups, qr/var ACTION_SECTIONS/, 'groups.md carries no copy of the sections' );
}

# --- Users page: PERM_LABELS read-only grid ------------------------------------
my $users = slurp("$root/starter/manager/users.md");
my ($pl) = $users =~ /var PERM_LABELS = \{(.*?)\};/s;
ok( $pl, 'users.md defines PERM_LABELS' );
my %perm = map { $_ => 1 } ( ( $pl // '' ) =~ /([a-z0-9_]+)\s*:/g );
is_deeply( [ sort keys %perm ], [ sort @cap_keys ],
    'users.md PERM_LABELS lists exactly @CAP_KEYS - every capability is shown in the per-user grid' )
    or diag "labels-only: @{[ sort grep { !$is_cap{$_} } keys %perm ]} | caps-missing: @{[ sort grep { !$perm{$_} } @cap_keys ]}";

done_testing;
