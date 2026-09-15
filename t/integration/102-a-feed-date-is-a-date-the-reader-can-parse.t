#!/usr/bin/perl
# SM888 A1 / K2: the shipped feeds emitted the front-matter date RAW.
#
# `date: 2026-08-14` in a page's front matter went straight into RSS's
# <pubDate> and Atom's <updated>. Neither accepts it:
#
#   RSS 2.0  pubDate  RFC 822 / 1123 - "Thu, 14 Aug 2026 00:00:00 +0000"
#   Atom     updated  RFC 3339       - "2026-08-14T00:00:00Z"
#
# A reader given a date it cannot parse shows the item as undated, or dates it
# "now" and re-sorts the feed on every fetch. It is not a crash, which is why
# it survived: every feed this project has ever published has been wrong, and
# the feeds still looked fine in a browser.
#
# THE TEMPLATES ARE THE SHIPPED ONES, copied from starter/ rather than written
# here, for t/integration/54's reason: the defect lived in a shipped template,
# so a fixture carrying its own would assert that the test's copy was right.
#
# AND THE FIX IS IN THE DATA, NOT ONLY THE TEMPLATE. The registry templates
# install under bucket `seed`, so an upgrade does not replace them: a site
# installed last year keeps the template it was given. Fixing only
# starter/ would fix new sites and leave every existing feed wrong, which is
# every feed that has a subscriber.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Copy qw(copy);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_test_site run_processor repo_root site_tempdir);

my $root    = repo_root();
my $docroot = site_tempdir();
setup_test_site($docroot);

make_path("$docroot/lazysite/templates/registries");
for my $tt ( glob "$root/starter/lazysite/templates/registries/*.tt" ) {
    ( my $base = $tt ) =~ s{.*/}{};
    copy( $tt, "$docroot/lazysite/templates/registries/$base" ) or die "copy $tt: $!";
}

sub page {
    my ( $rel, $title, $date ) = @_;
    my $path = "$docroot/$rel";
    ( my $dir = $path ) =~ s{/[^/]+\z}{};
    make_path($dir) unless -d $dir;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} "---\ntitle: $title\n";
    print {$fh} "date: $date\n" if defined $date;
    print {$fh} "register:\n  - feed.rss\n  - feed.atom\n---\n\nBody.\n";
    close $fh;
    return;
}

page( 'index.md', 'Home',  '2026-08-14' );
page( 'two.md',   'Two',   '2026-08-15 09:30' );
page( 'three.md', 'Three', 'last Tuesday' );    # not a date at all

run_processor( $docroot, $_ ) for qw(/ /two /three);

sub body_of {
    my ($out) = @_;
    $out //= '';
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return $out;
}

my $rss  = body_of( scalar run_processor( $docroot, '/feed.rss' ) );
my $atom = body_of( scalar run_processor( $docroot, '/feed.atom' ) );

# BY ITEM, NOT BY POSITION. The feed's order is the registry's, not the
# fixture's - here it is Home, Three, Two - so indexing into the date list
# compares the wrong page against the wrong expectation, which the first draft
# of this file did and reported as an engine fault.
# WITHIN ONE ITEM, too: the channel has a <title> of its own, and a pattern
# that walks from any title to the next date pairs the CHANNEL's title with the
# FIRST item's date and shifts every row by one.
sub dated {
    my ( $xml, $tag, $item ) = @_;
    my %by_title;
    while ( $xml =~ m{<$item>(.*?)</$item>}gs ) {
        my $block = $1;
        my ($t) = $block =~ m{<title>(.*?)</title>}s;
        my ($v) = $block =~ m{<$tag>(.*?)</$tag>}s;
        $by_title{$t} = $v if defined $t && defined $v;
    }
    return \%by_title;
}

subtest 'RSS pubDate is RFC 822' => sub {
    my $by    = dated( $rss, 'pubDate', 'item' );
    my @dates = values %$by;
    cmp_ok( scalar @dates, '>=', 2, 'the feed listed the dated pages' )
        or diag($rss);

    # "Fri, 14 Aug 2026 00:00:00 +0000" - day name, day, month name, year,
    # time, numeric zone. A bare ISO date matches none of it.
    # ONE qr//, not three joined with `.`: concatenating qr objects yields a
    # STRING, and Test::More's like() refuses a string pattern - which fails
    # the assertion for a reason that has nothing to do with the feed.
    my $RFC822 = qr{
        \A (?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) ,\s
        \d{2} \s (?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \s
        \d{4} \s \d{2}:\d{2}:\d{2} \s [+-]\d{4} \z
    }x;

    my ($iso) = grep { /^\d{4}-\d{2}-\d{2}/ } @dates;
    ok( !$iso, 'no raw ISO date reached a pubDate' )
        or diag( "got: $iso\n"
            . 'RSS readers cannot parse this. Every item dated with it is '
            . 'shown undated, or dated "now" and re-sorted on each fetch.' );

    like( $by->{Home}, $RFC822, 'a date-only front matter becomes RFC 822' );
    like( $by->{Two},  $RFC822, 'and so does one carrying a time' );
    like( $by->{Home}, qr/^Fri, 14 Aug 2026 00:00:00 \+0000$/,
        'the day and month are NAMED, in English' )
        or diag( 'strftime %a/%b are locale dependent - a host with a '
            . 'non-English locale would publish month names no feed '
            . 'specification recognises, on some hosts and not others.' );
};

subtest 'Atom updated is RFC 3339' => sub {
    my $by = dated( $atom, 'updated', 'entry' );
    cmp_ok( scalar keys %$by, '>=', 2, 'the feed listed the dated pages' );
    my $R3339 = qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-]\d{2}:\d{2})$/;
    like( $by->{Home}, $R3339, 'a date-only front matter gains a time and a zone' );
    like( $by->{Two},  $R3339, 'and a date with a time keeps it' );
    like( $by->{Two}, qr/T09:30:00/, 'the time it was given, not midnight' );
};

subtest 'the two feeds do not get the same string' => sub {
    # The discriminating measure. One shared "formatted date" would satisfy
    # either check on its own and be wrong in one of the two feeds - which is
    # the shape of the original defect, one value used in two places that
    # want different things.
    my ($r) = $rss  =~ m{<pubDate>(.*?)</pubDate>}s;
    my ($a) = $atom =~ m{<updated>(.*?)</updated>}s;
    isnt( $r, $a, 'RSS and Atom are formatted for their own specifications' );
};

subtest 'a date nothing can parse is passed through, not invented' => sub {
    # Three's date is prose. The engine does not guess what it meant and does
    # not substitute "now": a feed that quietly dates an item to the moment it
    # was generated re-sorts itself on every fetch and tells the sysop nothing.
    like( $rss, qr/last Tuesday/,
        "an unparseable date reaches the feed as the sysop wrote it" )
        or diag( 'Passed through deliberately: the alternative is inventing a '
            . 'date, and the page is the place to fix it.' );
};

done_testing();
