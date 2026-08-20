#!/usr/bin/perl
# SM432: a page and a same-named directory cannot both ship.
#
# starter/docs/features.md and starter/docs/features/ both exist in the
# tracked payload. features.md serves, the leaf pages under features/ serve,
# and the canonical extensionless URL - /docs/features, the only one
# sitemap.xml advertises - is shadowed by the directory and lands on a 404.
# So the single URL the site publishes about itself is the single URL that
# fails, and a visitor following the site's own index is the one person who
# meets it.
#
# NO ENGINE TEST CAN CATCH THE SERVING FAILURE. The 301 comes back as
# charset=iso-8859-1, so the front end resolves it before the engine is
# consulted - the same blind spot the outside-in probe exists for. What CAN be
# caught, cheaply and here, is the collision that causes it: two things
# claiming one URL, in content we ship.
#
# There are NO collisions now. The one this lint was written beside -
# starter/docs/features.md shadowed by starter/docs/features/ - was resolved by
# moving the page to features/index.md, which keeps its published URL
# (canonical_url_for maps foo/index.md to /foo) and needs no alias and no
# redirect. So the exclusion list is empty, which is the state it should be in:
# an entry here is a URL somebody has decided to leave broken.
use strict;
use warnings;
use Test::More;
use File::Find;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $docs = "$root/starter/docs";
plan skip_all => 'no starter/docs' unless -d $docs;

# The known collision, awaiting the SM432 decision. Adding to this list is a
# deliberate act with a URL consequence, which is the point of it being a list.
my %KNOWN = ();

my @collisions;
find(
    { no_chdir => 1,
        wanted => sub {
            return unless -d $_;
            my $md = "$_.md";
            return unless -f $md;
            ( my $rel = $_ ) =~ s{^\Q$docs\E/?}{};
            push @collisions, $rel if length $rel;
        },
    },
    $docs
);

my @unexpected = grep { !$KNOWN{$_} } @collisions;

is_deeply( \@unexpected, [],
    'no page in starter/docs is shadowed by a same-named directory' )
    or diag( "These claim the same URL twice:\n  "
        . join( "\n  ", @unexpected )
        . "\n\nThe extensionless canonical URL - the one sitemap.xml"
        . " publishes - resolves to the DIRECTORY, so the page becomes"
        . " unreachable at its own address. Rename one side, and give the"
        . " name that loses an alias on its successor. See SM432." );

# Any exclusion must still describe the tree: an entry for a collision that no
# longer exists is how a list stops being a record of anything. (This fired for
# real when features/ was resolved - the entry had to come out as part of the
# same change, not as a follow-up.)
for my $k ( sort keys %KNOWN ) {
    ok( ( grep { $_ eq $k } @collisions ),
        "the known collision '$k' is still present ($KNOWN{$k})" )
        or diag( 'If this was resolved, remove it from %KNOWN - an exclusion '
            . 'for something that no longer exists is how a list stops '
            . 'describing the tree.' );
}

done_testing();
