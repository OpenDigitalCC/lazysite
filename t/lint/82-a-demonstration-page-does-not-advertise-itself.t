#!/usr/bin/perl
# SM486: a demonstration page must not put itself in a customer's sitemap.
#
# MEASURED ON NINE LIVE SITES. Four of them served `/lazysite-demo` publicly,
# and on the poultry-feed site it rendered under the client's own name:
#
#     <title>lazysite Feature Test - Marriage &amp; Morris</title>
#
# It was also in that site's public sitemap.xml, so it was OFFERED TO SEARCH
# ENGINES rather than merely left reachable. The page declared
# `register: [llms.txt, sitemap.xml]` and did exactly what it was told.
#
# The operator's complaint was that cleaning up boilerplate is tedious. The
# measurement showed something worse: the cleanup is UNRELIABLE and it fails
# SILENTLY. Nothing on the site says the page is still there, and the one place
# that advertises it is the sitemap, which nobody reads.
#
# So the tedium is worth reducing and the advertising has to stop, and those
# are different fixes. This is the second one, and it is the one that cannot be
# left to whoever remembers.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root    = repo_root();
my @starter = glob("$root/starter/*.md");
ok( scalar @starter, 'there are starter pages to check' )
    or BAIL_OUT('no starter pages found');

sub front_matter {
    my ($p) = @_;
    open my $fh, '<', $p or die $!;
    my $s = do { local $/; <$fh> };
    close $fh;
    my ($fm) = $s =~ /\A---\s*\n(.*?)\n---\s*\n/s;
    return $fm // '';
}

subtest 'every starter page says which kind it is' => sub {
    # THREE KINDS, and the difference matters when somebody is deleting:
    #
    #   infrastructure  the engine addresses it by path. Deleting
    #                   search-results.md turns site search silently off -
    #                   the box just stops working, with no error anywhere.
    #   demonstration   showroom. Safe to delete, and meant to be.
    #   content         a real page, to be edited or replaced.
    #
    # A single "delete me at handover" folder cannot hold all three, and
    # putting the infrastructure in one would invite exactly the deletion that
    # breaks search and the password-reset round trip.
    for my $p (@starter) {
        my $name = $p;
        $name =~ s{.*/}{};
        my $fm = front_matter($p);
        next unless $fm =~ /^provenance:\s*lazysite-starter/m;
        like( $fm, qr/^starter_role:\s*(?:infrastructure|demonstration|content)\s*$/m,
            "$name declares a starter_role" )
            or diag( 'Without it an operator clearing boilerplate cannot tell '
                . 'a page they may delete from one that turns a feature off.' );
    }
};

subtest 'A DEMONSTRATION PAGE REGISTERS ITSELF NOWHERE' => sub {
    my $checked = 0;
    for my $p (@starter) {
        my $name = $p;
        $name =~ s{.*/}{};
        my $fm = front_matter($p);
        next unless $fm =~ /^starter_role:\s*demonstration\s*$/m;
        $checked++;
        unlike( $fm, qr/^register:/m,
            "$name does not register itself in any registry" )
            or diag( 'This is how a feature-test page ended up in a poultry '
                . "feed merchant's sitemap, under their own site name, "
                . 'offered to search engines.' );
    }
    ok( $checked, "there are demonstration pages, and $checked were checked" )
        or diag( 'If nothing is marked `demonstration` this subtest passes '
            . 'while checking nothing at all.' );
};

subtest 'and the real pages still do register' => sub {
    # The rule is about demonstrations, not about registration. A site's own
    # contact page belongs in its sitemap, and a check that stopped that would
    # have traded one silent fault for another.
    my $fm = front_matter("$root/starter/contact.md");
    like( $fm, qr/^register:/m, 'contact.md still registers itself' )
        or diag( 'Removing a real page from the sitemap would be a worse bug '
            . 'than the one being fixed.' );
};

subtest 'infrastructure pages are not marked deletable' => sub {
    # search-results.md is the one that matters: the search form posts to
    # /search-results, and search is switched on by the file EXISTING. Marking
    # it as a demonstration would put it on the list of things to delete at
    # handover, and site search would turn itself off with no error.
    for my $f (qw(search-results.md search-index.md logout.md forgot.md)) {
        my $p = "$root/starter/$f";
        next unless -f $p;
        my $fm = front_matter($p);
        like( $fm, qr/^starter_role:\s*infrastructure\s*$/m,
            "$f is marked infrastructure" )
            or diag( 'Deleting it does not remove a page, it removes a '
                . 'FEATURE, and nothing reports that it has gone.' );
    }
};

done_testing();
