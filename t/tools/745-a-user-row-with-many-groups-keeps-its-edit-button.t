#!/usr/bin/perl
# SM1470: AN ACCOUNT ROW WITH MANY ROLE CHIPS KEEPS ITS EDIT BUTTON.
#
# starter/manager/users.md renderUserRow builds one `.mg-acc-line` row: name, tags, a chip
# per role, a spacer, flags and the Edit button. `.mg-acc-line` was a nowrap flex row and
# `flex-wrap: wrap` applied only inside the narrow-width media query, so on a wide screen an
# account holding many roles ran its chips off the row and pushed the Edit button out of
# view; the account could not be edited.
#
# The fix is two rules in each of the three manager styles, kept in step: the row wraps at
# EVERY width (a top-level rule, not one inside @media), and a button in the row does not
# shrink. Each subtest fails against the old CSS: no top-level wrap, no unshrinkable button.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root   = repo_root();
my @sheets = sort glob "$root/starter/lazysite/manager/assets/manager-*.css";
cmp_ok( scalar @sheets, '==', 3, 'three manager styles' );

for my $f (@sheets) {
    ( my $style = $f ) =~ s{.*/manager-}{};
    $style =~ s/\.css$//;
    open my $fh, '<:utf8', $f or die "$f: $!";
    my $src = do { local $/; <$fh> };
    close $fh;

    # Top level only: drop every @media block (indented rules inside it) before looking.
    ( my $top = $src ) =~ s/^\@media[^\{]*\{.*?^\}//msg;

    my ($row) = $top =~ /^\.mg-acc-line \{([^}]*)\}/m;
    ok( defined $row, "$style: a top-level .mg-acc-line rule" ) or next;
    like( $row, qr/flex-wrap:\s*wrap/, "$style: the account row wraps at every width" );

    like( $top, qr/^\.mg-acc-line \.mg-btn \{[^}]*flex:\s*0 0 auto/m,
        "$style: a button in the row never shrinks, so Edit stays clickable" );
}

# The row the report is about is the one the users page builds.
open my $u, '<:utf8', "$root/starter/manager/users.md" or die $!;
my $page = do { local $/; <$u> };
close $u;
like( $page, qr/<summary class="mg-acc-line">' \+ line/, 'users page renders its row as .mg-acc-line' );
like( $page, qr/mg-btn mg-btn-sm mg-configbtn/,          'the Edit button is a .mg-btn in that row' );

done_testing;
