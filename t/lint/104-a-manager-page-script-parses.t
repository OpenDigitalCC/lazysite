#!/usr/bin/perl
# Every manager page's <script> block parses.
#
# WHAT HAPPENED. A restructure of the Groups page left `renderGroups` calling
# `oneGroup(...)` and `SECTIONS.map(...)` where neither was ever defined: an
# editing script printed its success message and then aborted BEFORE writing
# the file, so half an edit landed and the half that reported "ok" did not. The
# page shipped, the whole lint tier passed, and the Groups list sat on
# "Loading…" for ever - a ReferenceError stops the handler and nothing else
# says a word.
#
# Nothing in this suite read page JavaScript. Every other lint here reads the
# SOURCE as text - which is why a page could be syntactically broken and still
# satisfy all of them.
#
# This asks a parser. It is not a linter and makes no judgement about style: it
# answers the one question the tier could not, which is whether the code the
# browser is handed can run at all.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);

my $node = `sh -c 'command -v node 2>/dev/null'`;
chomp $node;
plan skip_all => 'node is not installed; cannot parse page scripts'
    unless length $node && -x $node;

my $root = "$FindBin::Bin/../..";
my $dir  = tempdir( CLEANUP => 1 );
my @pages = sort glob "$root/starter/manager/*.md";
ok( scalar @pages, 'manager pages were found' ) or BAIL_OUT('no pages');

my @broken;
for my $f (@pages) {
    ( my $name = $f ) =~ s{.*/}{};
    my $src = do { open my $fh, '<', $f or die $!; local $/; <$fh> };

    # Every script block on the page, each checked on its own: they are
    # separate scripts to the browser, and a later one still runs when an
    # earlier one throws.
    my $n = 0;
    while ( $src =~ /<script(?![^>]*\bsrc=)[^>]*>(.*?)<\/script>/gs ) {
        my $js = $1;
        next unless $js =~ /\S/;
        $n++;
        my $tmp = "$dir/$name.$n.js";
        open my $out, '>', $tmp or die $!;
        print {$out} $js;
        close $out;
        my $err = `$node --check "$tmp" 2>&1`;
        next if $? == 0;
        $err =~ s/\Q$tmp\E/$name/g;
        $err =~ s/\s+\z//;
        push @broken, "$name (block $n):\n      " . join( "\n      ", split /\n/, $err );
    }
}

is( "@broken", '', 'every manager page script parses' )
    or diag( "\n  " . join( "\n  ", @broken )
        . "\n\n  A page whose script does not parse renders its markup and does\n"
        . "  nothing: no handler binds, no list loads, and the panel sits on\n"
        . "  its placeholder. Nothing in the log, and every other lint passes." );

done_testing();
