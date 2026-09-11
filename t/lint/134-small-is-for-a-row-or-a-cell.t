#!/usr/bin/perl
# SM847: a small button is small only inside a list row or a table cell.
#
# Reported by the release manager on 0.13.12: most buttons are the standard
# size, and some - Refresh, Show, a user's Edit - are smaller. .mg-btn-sm was a
# named size with no rule for where it belongs, used 147 times, and the style
# guide itself showed it in a toolbar beside a standard Add. The ruling of
# 2026-09-11: small is for controls inside a list row or a table cell, where a
# row carries several and the list is dense; everywhere else, the standard size.
#
# The rule lives in the STYLESHEET, not at the call sites: the size applies only
# under the row and cell containers, so a toolbar button is standard whatever its
# markup says, and no page can reintroduce the mismatch by reaching for the
# class. This pins that - in every style, and with the same containers in each.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my @ROW = ( '.mg-row', 'td', '.mg-handler-item', '.mg-nav-item', '.mg-file-item', '.mg-notif-item' );
my %lists;

for my $style (qw(modern classic accessible)) {
    my $f = "$root/starter/lazysite/manager/assets/manager-$style.css";
    open my $fh, '<', $f or die "$f: $!";
    my $css = do { local $/; <$fh> };
    close $fh;
    $css =~ s{/\*.*?\*/}{}gs;    # a comment describing the rule is not the rule

    my @rules = $css =~ /([^{}]*\bmg-btn-sm\b[^{}]*)\{/g;
    ok( @rules, "$style: styles the small button at all" ) or next;
    for my $sel (@rules) {
        for my $part ( map { s/^\s+|\s+$//gr } split /,/, $sel ) {
            next unless $part =~ /\bmg-btn-sm\b/;
            unlike( $part, qr/\A\.mg-btn-sm\b/, "$style: '$part' is scoped to a container, never bare" );
            my ($ctx) = $part =~ /\A(\S+)\s+\.mg-btn-sm\z/;
            ok( defined $ctx && ( grep { $_ eq $ctx } @ROW ), "$style: '$part' - its container is a list row or cell" );
            push @{ $lists{$style} }, $ctx if defined $ctx;
        }
    }
}

is_deeply( [ sort @{ $lists{$_} || [] } ], [ sort @ROW ], "$_: sizes small in exactly the row and cell containers" )
    for qw(modern classic accessible);

done_testing();
