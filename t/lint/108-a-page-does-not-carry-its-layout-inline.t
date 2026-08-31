#!/usr/bin/perl
# The mechanical reason a manager defect keeps coming back after it is fixed.
#
# Three fixes this session changed nothing, silently, and all three failed the
# same way: a rule was written in the stylesheet where it could not win.
#
#   1. INLINE STYLE. Sessions' device cell carried
#      `style="max-width:20rem;white-space:nowrap"` and its actions cell
#      `style="white-space:nowrap"`. Every sheet rule written to make that
#      column wrap lost to them - an inline style beats any selector here -
#      so the table went on overflowing and the fix looked applied.
#   2. THE WRONG DISPLAY MODEL. "A checkbox belongs beside its label" set
#      flex-direction on .mg-field, which the dense form makes a GRID. Flex
#      properties on a grid do nothing at all, and nothing says so.
#   3. SOURCE ORDER. The narrow-width header rules sat 400 lines above the
#      base rule they had to beat, and lost at equal specificity.
#
# Only the first is checkable as text, so that is what this holds: a CEILING
# per page, ratcheting down. A page may lose inline styles freely; gaining one
# fails here, with the count to prove it. The other two are caught by the
# rendered-layout check (tools/manager-layout-check.js), which needs a
# browser and so cannot live in this tier.
#
# The ceilings are a debt register, not a target. Every one of these is a
# layout decision that belongs in the sheet, where the guide can show it and
# a theme can restyle it.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $dir = repo_root() . '/starter/manager';
opendir my $dh, $dir or plan skip_all => "no $dir";
my @pages = sort grep { /\.md\z/ } readdir $dh;
closedir $dh;
plan skip_all => 'no manager pages' unless @pages;

# Measured 2026-08-31. Lower a number when you remove one; never raise one.
my %CEILING = (
    'appearance.md'     => 18,
    'audit.md'          => 7,
    'backups.md'        => 16,
    'cache.md'          => 2,
    'config.md'         => 4,
    'data.md'           => 49,
    'domains.md'        => 79,
    'edit.md'           => 14,
    'files.md'          => 23,
    'groups.md'         => 19,
    'index.md'          => 0,
    'nav.md'            => 16,
    'plugin-config.md'  => 43,
    'plugins.md'        => 0,
    'sessions.md'       => 21,
    'stats.md'          => 12,
    'style-guide.md'    => 4,
    'themes.md'         => 0,
    'users.md'          => 28,
);

my $total = 0;
for my $p (@pages) {
    my $src = do {
        open my $fh, '<', "$dir/$p" or die $!;
        local $/;
        <$fh>;
    };
    my $n = () = $src =~ /style="[^"]*"/g;
    $total += $n;

    my $cap = $CEILING{$p};
    if ( !defined $cap ) {
        is( $n, 0, "$p: a new page carries no inline style" )
            or diag( 'A page written after this check has no debt to inherit. '
                . 'Put the rule in the stylesheet, where the style guide can '
                . 'show it and a theme can restyle it.' );
        next;
    }
    cmp_ok( $n, '<=', $cap, "$p: inline styles $n (ceiling $cap)" )
        or diag( "$p gained an inline style. Whatever it does, the stylesheet "
            . 'cannot override it - which is how a fixed defect comes back '
            . 'looking unfixed.' );
}

diag("inline styles across the manager: $total");
done_testing();
