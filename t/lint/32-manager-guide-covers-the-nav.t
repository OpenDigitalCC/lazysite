#!/usr/bin/perl
# SM153: the manager UI guide is MENU-COMPLETE, and stays that way.
#
# A walkthrough document that is not checked drifts the moment a menu item is
# added, and its value is exactly its completeness - a reviewer trusting it to
# cover the surface is misled by one missing entry in a way they cannot detect.
#
# So the coverage rule is enforced rather than promised: read the nav out of the
# manager layout, read the covered items out of the guide chunks, and fail on
# either direction of drift. A new menu item cannot ship without a guide entry,
# and a retired one cannot leave a stale entry behind.
#
# An item that genuinely should not have a walkthrough is declared in a chunk as
# `Intentionally omitted: <reason>` and counts as covered - a decision recorded,
# not an oversight. (SM153's own filing asks for exactly that escape hatch.)
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root   = repo_root();
my $layout = "$root/starter/lazysite/manager/layout.tt";
my $dir    = "$root/docs/manager-ui-guide";

ok( -f $layout, 'the manager layout is where the nav lives' ) or done_testing, exit;
ok( -d $dir,    'the guide directory exists' )                or done_testing, exit;

# --- the nav, as shipped ----------------------------------------------------
# Every <a href="/manager/..."> inside the nav block, with its link text. The
# text is what a reviewer sees and therefore what the guide must name.
my $src = do { local ( @ARGV, $/ ) = $layout; <> };
# The capture group is load-bearing: a list-context match with NO group returns
# (1) on success, so `my ($nav) = ...` would silently be the number 1 and every
# check below would pass against an empty nav. That is exactly the vacuous-pass
# the count assertion further down exists to catch - and it caught it.
my ($nav) = $src =~ m{(<nav class="mg-nav".*?</nav>)}s;
ok( $nav, 'the nav block was found - if this fails the parse below is lying' )
    or done_testing, exit;

my %seen;
my @items;
while ( $nav =~ m{<a\s+href="(/manager[^"]*)"[^>]*>(.*?)</a>}gs ) {
    my ( $href, $text ) = ( $1, $2 );
    $text =~ s/&\#?\w+;//g;    # padlocks, ampersand entities
    $text =~ s/<[^>]*>//g;
    $text =~ s/^\s+|\s+$//g;
    next unless length $text;
    next if $seen{$text}++;    # a gated item appears twice (granted + padlocked)
    push @items, $text;
}

cmp_ok( scalar @items, '>=', 10,
    'the nav parsed to a plausible number of items (a broken parse would pass '
        . 'everything below vacuously)' )
    or diag explain \@items;

# --- what the guide covers --------------------------------------------------
opendir my $dh, $dir or die $!;
my @chunks = sort grep { /\.md\z/ } readdir $dh;
closedir $dh;

cmp_ok( scalar @chunks, '>=', 5, 'the guide is chunked, not a monolith' );

my $guide = '';
for my $c (@chunks) {
    $guide .= do { local ( @ARGV, $/ ) = "$dir/$c"; <> };
}

# Every chunk carries front matter, so the merge produces one document rather
# than a pile with a stray title in the middle.
for my $c (@chunks) {
    my $body = do { local ( @ARGV, $/ ) = "$dir/$c"; <> };
    like( $body, qr/\A---\n(?:[^\n]*\n)*?title:/, "$c opens with front matter" );
}

# --- the coverage rule, both directions -------------------------------------
my @uncovered;
for my $item (@items) {
    # Match the item's words in a heading or an `Intentionally omitted` line.
    # Loose on purpose: "Sessions & keys" is written "Sessions and keys", and a
    # guide forced to copy entity-encoded nav text verbatim would be worse to
    # read for the benefit of a regex.
    my @words = grep { length > 2 } split /[^A-Za-z]+/, $item;
    next unless @words;
    my $pat = join '.{0,12}', map {quotemeta} @words;
    push @uncovered, $item unless $guide =~ /$pat/i;
}
is( "@uncovered", '',
    'every manager nav item has a guide entry (or a recorded omission)' )
    or diag "NOT COVERED by docs/manager-ui-guide/: @uncovered";

# The per-item template is the guide's contract with its reader. A chunk that
# drops Negative is the one that matters: it is where an unenforced capability
# hides, and it is the part a hurried author leaves out.
for my $c ( grep { !/^00-/ } @chunks ) {
    my $body = do { local ( @ARGV, $/ ) = "$dir/$c"; <> };
    next if $body =~ /^Intentionally omitted:/m && $body !~ /^Where\n/m;
    like( $body, qr/^Where\n/m,  "$c uses the Where field" );
    like( $body, qr/^Do\n/m,     "$c uses the Do field" );
    like( $body, qr/^Expect\n/m, "$c uses the Expect field" );
    like( $body, qr/^Negative\n/m,
        "$c states what an under-privileged user should see" );
}

done_testing();
