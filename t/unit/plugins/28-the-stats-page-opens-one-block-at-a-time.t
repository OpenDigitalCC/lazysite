#!/usr/bin/perl
# SM424: the stats page renders every block at once.
#
# Visits, depth, entry and exit pages, devices, search terms, status codes,
# server errors, journeys and the blocked-address list all render on one page,
# in that order, every time. An operator who came for hits per day scrolls past
# the lot. There is no way to put any of it away and no way to say "not this
# one, ever" - so the page gets longer with each thing it learns to show, and
# every addition costs every operator who does not want it.
#
# WHAT IS ASSERTED
#   every section of the report is inside a collapsible block, not loose
#   the two an operator comes for are OPEN by default - this hides nothing
#     that was previously the answer to the common question
#   the remembered state distinguishes NEVER STORED from SHUT, so a first
#     visit shows the defaults rather than an empty page
#   localStorage is never touched outside a guard - a private window throws on
#     the accessor itself, and the page must still render
#   the two whole cards do not fetch until they are opened
#   NO NEW INLINE EVENT HANDLERS - the manager's CSP debt does not grow here
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root  = repo_root();
my $pagef = "$root/starter/manager/stats.md";
my $cssf  = "$root/starter/lazysite/manager/assets/manager-classic.css";
plan skip_all => "no $pagef" unless -f $pagef;

my $page = do { open my $fh, '<', $pagef or die $!; local $/; <$fh> };

# ---------------------------------------------------------------------
# 1. Nothing in the report is loose any more
# ---------------------------------------------------------------------
# The report is what renderStats() builds. A section heading there that is NOT
# a block summary is a section an operator cannot put away - which is the whole
# defect. `mg-sec` is the heading class, so any remaining literal in that
# function is a section that escaped.
my ($render) = $page =~ m{\nfunction renderStats\(d\)\s*\{(.*?)\n\}\n}s;
ok( length( $render // '' ), 'renderStats can be isolated' )
    or BAIL_OUT( 'renderStats not found - every assertion below would be vacuous' );

my @loose = ( $render =~ m{'<div class="mg-sec">([^<]*)</div>}g );
is_deeply( \@loose, [],
    'no section of the report is rendered outside a collapsible block' )
    or diag( "still loose: " . join( ', ', @loose ) );

# And it is really using blocks, so the test above cannot pass by the report
# having been emptied.
my @keys = ( $render =~ m/block\(\s*'([a-z]+)'/g );
cmp_ok( scalar @keys, '>=', 7, 'the report is built from blocks (not vacuous)' );
is( scalar @keys, scalar( keys %{ { map { $_ => 1 } @keys } } ),
    'every block has its own key - a repeated key would make two sections '
        . 'open and shut together, which reads as a bug in the page' );

# ---------------------------------------------------------------------
# 2. What stays open
# ---------------------------------------------------------------------
# Collapsing EVERYTHING would trade one annoyance for another: an operator who
# opens this page to see how much traffic there was would find nothing at all.
# The default is the LAST argument of that key's own call. A regex with .*?
# across the whole function finds the next `, 1 )` anywhere below it and passes
# whatever this block was given - so the call is parsed out instead. Parens
# inside string literals are common here (' IP' ... ')</span>'), so quoting is
# tracked rather than assumed.
sub block_default {
    my ( $src, $key ) = @_;
    my $at = index( $src, "block( '$key'" );
    return undef if $at < 0;
    my $i = index( $src, '(', $at );
    my ( $depth, $q, $esc, $j ) = ( 0, 0, 0, $i );
    for ( ; $j < length $src; $j++ ) {
        my $c = substr( $src, $j, 1 );
        if ($esc)          { $esc = 0;      next }
        if ( $c eq '\\' )  { $esc = 1;      next }
        if ( $c eq "'" )   { $q   = !$q;    next }
        next if $q;
        $depth++ if $c eq '(';
        if ( $c eq ')' ) { $depth--; last if $depth == 0 }
    }
    my $call = substr( $src, $i, $j - $i + 1 );
    my ($last) = $call =~ /,\s*([01])\s*\)\z/;
    return $last;
}

# Prove the parser before trusting eight assertions to it: a key that is not
# there must come back undef, not a default that happens to be right.
is( block_default( $render, 'no-such-block' ), undef,
    'the call parser returns nothing for a block that is absent' );

for my $open (qw(audience perday pages)) {
    is( block_default( $render, $open ), '1',
        "'$open' is open by default - it is what the page is for" );
}
for my $shut (qw(visits devices search status errors monthly)) {
    is( block_default( $render, $shut ), '0', "'$shut' starts shut" );
}

# ---------------------------------------------------------------------
# 3. NEVER STORED is not the same as SHUT
# ---------------------------------------------------------------------
# The bug this prevents: reading the absence of a stored value as "shut" would
# give a first-time operator a page of closed headings and no figures.
my ($openfn) = $page =~ m{\nfunction blockOpen\(([^\}]*\n)*?\}}s;
like( $page, qr/function blockOpen\(key, openByDefault\)/,
    'the default is a parameter, not a constant' );
like( $page, qr/\(v === null\)\s*\?\s*!!openByDefault/,
    'a never-stored key falls back to the default rather than to shut' );

# ---------------------------------------------------------------------
# 4. localStorage can throw on the ACCESSOR
# ---------------------------------------------------------------------
# In a private window, or with site data blocked, `localStorage` itself throws
# on property access - not just getItem. Every touch must sit inside a guard or
# the whole page dies rendering nothing.
# Actual accesses, not the prose that explains them - a comment naming
# localStorage is not a touch, and counting it would make this fail forever.
my @touches = grep { /localStorage\s*\./ && !m{^\s*//} } split /\n/, $page;
cmp_ok( scalar @touches, '>=', 2, 'localStorage is actually used (not vacuous)' );

# Every touch is in one of the two guarded helpers. Asserted as a COUNT rather
# than by parsing each function out: the point is that no third place learns to
# touch storage directly, and a count catches that however it is written.
my $guarded = 0;
for my $fn (qw(blockOpen statsToggle)) {
    my ($body) = $page =~ /(\nfunction \Q$fn\E\b.*?\n\})/s;
    $body //= '';
    $guarded += ( () = $body =~ /localStorage\s*\./g );
    like( $body, qr/try\s*\{/, "$fn guards its access" );
}
is( $guarded, scalar @touches,
    'every localStorage touch on the page is inside a guarded helper - a '
        . 'private window throws on the accessor itself, so an unguarded one '
        . 'renders nothing at all' );
# Both helpers must carry their own catch - a try with no catch is a syntax
# error, but a catch that rethrows or a helper that guards only the write would
# still take the page down on the read.
like( $page, qr/function blockOpen.*?try\s*\{.*?\}\s*catch\s*\(e\)\s*\{[^}]*return/s,
    'the read returns a usable answer when storage is unavailable' );
like( $page, qr/function statsToggle.*?try\s*\{.*?\}\s*catch\s*\(e\)\s*\{/s,
    'the write is swallowed when there is nothing to remember with' );

# ---------------------------------------------------------------------
# 5. A card nobody opens costs no request
# ---------------------------------------------------------------------
# The page used to fetch a card's contents unconditionally at load, whether or
# not anyone looked. The deferred-fetch machinery is now exercised by the
# journeys card; the blocked-address card it was written for moved to Plugin
# Config in SM703.
like( $page, qr/cardSet\(\s*'card-trails'/,
    'a card is fetched through the machinery that knows whether it is open' );
like( $page, qr/if \(open && !cardLoaded\[key\]\)/,
    'and the fetch happens on the FIRST open only, not on every toggle' );

# SM703: a block is an ACCESS CONTROL - lazysite-auth.pl answers a blocked
# address 403 and exits before anything is served - so it does not belong on a
# page of statistics, where it reads as "hidden from the numbers" rather than
# "refused the site". It lives with the plugin that does the blocking.
unlike( $page, qr/function loadBlocked/,
    'the blocked-address list is not implemented on the statistics page' );
unlike( $page, qr/id="blocked-body"/,
    'and its panel is not here either' );
# The pointer card went too, on the release manager's instruction: "no need to
# say what isn't there". A page of statistics that spends a card explaining
# where a DIFFERENT page keeps an access control is still spending a card on
# something the operator did not come for.
unlike( $page, qr{Blocked addresses},
    'and the page does not keep a card explaining where the list went' );
like( $page, qr/id="trails-card-body" hidden/,
    'the journeys card body starts hidden' );

# THE THIRD ROUND TRIP. Month on month is its own call
# (analyse_visitors&index=1) and ran on every page load whether anyone read the
# deltas or not.
unlike( $page, qr/bindBlocks\(\);\s*\n\s*loadMonthly\(\);/,
    'the monthly deltas are no longer fetched on every render' );
like( $page, qr/var blockLoaders = \{ monthly: loadMonthly \}/,
    'they are fetched through the block that shows them' );
like( $page, qr/if \(!isOpen \|\| blockLoaded\[key\] \|\| !blockLoaders\[key\]\) return;/,
    'and once only, on open' );
# A block the viewer left open is open on arrival and fires no toggle event, so
# binding without an immediate check would leave it saying "Loading..." for
# ever. Counted inside bindBlocks rather than matched by shape: the call in the
# toggle handler has the same text, and a pattern that could match either
# passes whichever one is deleted.
my ($bind) = $page =~ /(\nfunction bindBlocks\(\).*?\n\})/s;
ok( length( $bind // '' ), 'bindBlocks can be isolated' );
my $calls = () = ( $bind // '' ) =~ /blockMaybeLoad\(/g;
is( $calls, 2,
    'bindBlocks both binds the toggle AND checks the block it is binding - a '
        . 'block the viewer left open fires no toggle event, so one call alone '
        . 'leaves it saying "Loading..." for ever' );

# The report itself stays ONE payload: the ingest is incremental and the
# sections are assembled from buckets it has already parsed, so a per-section
# fetch would repeat the ingest rather than divide it. Asserted so a later
# change does not "optimise" it the expensive way.
like( $page, qr/splitting\s+\/\/ THAT would multiply the ingest|multiply the ingest/,
    'and the reason the report is not split is written down' );

# The day list rides on the descriptor the summary already fetched, so filling
# the select must NOT be deferred - only the day's journeys are a round trip.
like( $page, qr/sel\.innerHTML = trailDays\.map/,
    'the day select is still filled without opening the card' );

# ---------------------------------------------------------------------
# 6. No new inline event handlers
# ---------------------------------------------------------------------
# Inline event attributes are why the manager breaks under an enforcing CSP -
# a nonce does not reach an attribute. This change adds UI, so it is exactly
# where that debt would grow.
unlike( $page, qr/\bontoggle\s*=/,
    'the blocks bind their toggle listener rather than inlining it' );
like( $page, qr/addEventListener\('toggle'/,
    'they use addEventListener' );
like( $page, qr/function bindCard/,
    'the card buttons are bound the same way' );
for my $id (qw(card-trails-toggle)) {    # card-blocked moved out, SM703
    like( $page, qr/id="\Q$id\E"[^>]*>/s, "$id exists for bindCard to find" );
    unlike( $page, qr/id="\Q$id\E"[^>]*\bonclick=/s,
        "$id carries no inline onclick" );
}

# The blocks are rebuilt on every render, so binding once at load would leave
# the second render's blocks forgetting what the operator chose.
like( $page, qr/body\.innerHTML = h;\s*\n\s*bindBlocks\(\);/,
    'the blocks are re-bound after each render, not once at load' );

# ---------------------------------------------------------------------
# 7. It is styled, or it renders as a bare disclosure triangle
# ---------------------------------------------------------------------
SKIP: {
    skip 'no manager.css', 2 unless -f $cssf;
    my $css = do { open my $fh, '<', $cssf or die $!; local $/; <$fh> };
    like( $css, qr/\.mg-stat-block\b/, 'the block class exists in the stylesheet' );
    like( $css, qr/\.mg-stat-block > summary[^}]*cursor:\s*pointer/,
        'the summary looks clickable' );
}

done_testing();
