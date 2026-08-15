#!/usr/bin/perl
# The llms.txt registration policy holds for EVERY shipped page, at any depth.
#
# THE POLICY. `llms.txt` tells an AI client what a site is about. On a customer
# site, lazysite's bundled documentation is operational reference for whoever
# maintains it - in a public registry it crowds out the content the site exists
# for. So:
#
#   - shipped documentation registers for sitemap.xml and NOT llms.txt;
#   - starter CONTENT that registers for sitemap.xml also registers for
#     llms.txt, so a new site starts correct and an author opts OUT rather
#     than in.
#
# WHY THIS IS A TEST AND NOT A CONVENTION. The change that established the
# policy was applied with the glob `starter/docs/*.md`, which does not descend.
# `starter/docs/integrations/` was missed, and the miss was invisible in the
# source: a recursive check said two pages still registered while the author's
# non-recursive one said none did. It was found by reading the registry off a
# DEPLOYED site, three days after the change shipped.
#
# That is the sixth time in this repository that a pattern which looked
# exhaustive was not - and the first where the pattern was written while fixing
# a different instance of the same thing. The remedy is the one this project has
# applied five times already: stop asserting the shape of the tree and walk it.
use strict;
use warnings;
use Test::More;
use File::Find;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

# The `register:` block of a page, as a list of registry names. Returns an empty
# list for a page with no block, which is a page that opts into nothing.
sub registers_of {
    my ($path) = @_;
    open my $fh, '<', $path or die "$path: $!";
    my ( @names, $in );
    while ( my $l = <$fh> ) {
        if ( $l        =~ /^register:\s*$/ ) { $in = 1;         next }
        if ( $in && $l =~ /^\s+-\s*(\S+)/ )  { push @names, $1; next }
        last if $in;    # the block ended
    }
    close $fh;
    return @names;
}

# Every .md under a directory, at ANY depth. The whole point of the file.
sub pages_under {
    my ($dir) = @_;
    return () unless -d $dir;
    my @out;
    find(
        { no_chdir => 1,
            wanted => sub { push @out, $_ if /\.md\z/ && -f $_ },
        },
        $dir
    );
    return sort @out;
}

subtest 'bundled documentation does not register for llms.txt' => sub {
    my @docs = pages_under("$root/starter/docs");
    cmp_ok( scalar @docs, '>=', 10, 'found the shipped documentation' );

    # Assert the walk actually descends - a guard on the guard. If this file
    # ever regresses to a non-recursive glob, this is what says so.
    my @nested = grep { m{/starter/docs/[^/]+/} } @docs;
    cmp_ok( scalar @nested, '>=', 1,
        'and the walk reaches pages in SUBDIRECTORIES - the exact case the '
            . 'original change missed' );

    my @offenders = grep { grep { $_ eq 'llms.txt' } registers_of($_) } @docs;
    s{\A\Q$root/\E}{} for @offenders;

    is_deeply( \@offenders, [],
        'no shipped documentation page registers for llms.txt' )
        or diag( join "\n  ",
        '',
        @offenders,
        '',
        'On a customer site these crowd out the site\'s own content in a file',
        'whose whole purpose is to say what the site is about.' );
};

subtest 'starter content registers for both' => sub {
    # Only the root-level starter pages: functional pages (login, logout,
    # forgot) deliberately register for nothing, and are left alone.
    my @content = glob "$root/starter/*.md";
    cmp_ok( scalar @content, '>=', 5, 'found the starter content pages' );

    my @missing;
    for my $p (@content) {
        my @r = registers_of($p);
        next unless grep { $_ eq 'sitemap.xml' } @r;
        next if grep     { $_ eq 'llms.txt' } @r;
        push @missing, $p =~ s{\A\Q$root/\E}{}r;
    }

    is_deeply( \@missing, [],
        'a starter page in the sitemap is also in llms.txt' )
        or diag( join "\n  ",
        '',
        @missing,
        '',
        'These are public content the site wants found. A page discoverable by',
        'a search engine and not by an AI client is an accident, not a policy.' );
};

done_testing();
