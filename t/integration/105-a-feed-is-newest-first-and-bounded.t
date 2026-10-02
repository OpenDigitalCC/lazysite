#!/usr/bin/perl
# SM942 FO1/FO2/FO3: the generated feeds list items NEWEST FIRST, and the item
# count is bounded.
#
# Reported from xisl.com: 59 pages, every pubDate correct, and the items in
# FILENAME order. An aggregator taking the first N entries of a large feed gets
# an arbitrary slice - "the latest 10" was ten articles chosen by path.
#
# THE FIXTURE'S FILENAMES DISAGREE WITH ITS DATES, DELIBERATELY. A fixture whose
# path order happened to match its date order would pass this file with the sort
# removed, which is the trap SM942 FO2 was written to avoid: assert the EMITTED
# ORDER, never that a sort was called.
#
#   apple   2026-01-05   first by path, OLDEST
#   banana  2026-09-20   second by path, NEWEST
#   cherry  2026-05-10   third by path, middle
#
# So the correct output is banana, cherry, apple - which is neither path order
# nor its reverse.
#
# AND THE SORT IS IN THE ENGINE, NOT THE TEMPLATE. The registry templates
# install under bucket `seed`, so an upgrade never replaces them: a template-side
# sort would fix new sites and leave every feed that HAS a subscriber in filename
# order. Same reasoning as the date formatting beside it (t/integration/102), and
# the templates here are the SHIPPED ones for the same reason.
#
# THE OTHER HALF OF THE TRAP: by the time a template sees `page.date` it is the
# RFC 822 string ("Mon, 05 Jan 2026 ..."), so sorting THAT orders by weekday
# name. The engine sorts on the raw ISO value before formatting. The dates below
# are chosen so that a weekday-name sort gives a different answer: Jan 5 is a
# Monday, Sep 20 a Sunday, May 10 a Sunday.
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

sub body_of {
    my ($out) = @_;
    $out //= '';
    $out =~ s/\A.*?\r?\n\r?\n//s;
    return $out;
}

# A GENERATED REGISTRY IS A CACHED FILE, rebuilt only when it is older than the
# registry TTL - so a request made straight after a change legitimately serves
# the PREVIOUS feed. Two drafts of this file got that wrong: the first read the
# stale feed as an engine fault (a missing page, an unapplied cap), and the
# second unlinked "$docroot/feed.rss", which is not where the artefact lives.
#
# It is written to _registry_cache_path(): lazysite/cache/registries/<key>/<name>,
# where the key is the content root relative to the docroot, or `_root` for the
# docroot itself. Removing THAT is how a test asks for a rebuild - and it is not
# a workaround for a defect, it is the cache behaving as designed (SM251).
my $REG_CACHE = "$docroot/lazysite/cache/registries/_root";

sub feed {
    my ($which) = @_;
    unlink "$REG_CACHE/feed.rss", "$REG_CACHE/feed.atom";
    return body_of( scalar run_processor( $docroot, "/$which" ) );
}

# The titles in the order they appear, which is the whole point of this file.
sub titles_in_order {
    my ( $xml, $item ) = @_;
    my @out;
    while ( $xml =~ m{<$item>(.*?)</$item>}gs ) {
        my $block = $1;
        push @out, $1 if $block =~ m{<title>(.*?)</title>}s;
    }
    return @out;
}

page( 'apple.md',  'Apple',  '2026-01-05' );
page( 'banana.md', 'Banana', '2026-09-20' );
page( 'cherry.md', 'Cherry', '2026-05-10' );
run_processor( $docroot, $_ ) for qw(/apple /banana /cherry);

my $rss  = feed('feed.rss');
my $atom = feed('feed.atom');

subtest 'RSS lists newest first' => sub {
    my @t = titles_in_order( $rss, 'item' );
    is_deeply( \@t, [ 'Banana', 'Cherry', 'Apple' ],
        'newest first, which is neither path order nor its reverse' )
        or diag($rss);
};

subtest 'Atom lists newest first' => sub {
    my @t = titles_in_order( $atom, 'entry' );
    is_deeply( \@t, [ 'Banana', 'Cherry', 'Apple' ], 'same order in both feeds' )
        or diag($atom);
};

subtest 'the channel carries its own timestamp' => sub {
    # New sites only: the templates are bucket `seed`, so an existing site keeps
    # the template it was given and gets the ORDER without this element. The
    # variable is always passed, so adding the element to an older template is a
    # one-line edit the operator can make.
    like( $rss, qr{<lastBuildDate>\s*\w+, 20 Sep 2026}s,
        'RSS lastBuildDate is the newest item, in RFC 822' )
        or diag($rss);
    like( $atom, qr{<updated>\s*2026-09-20}s,
        'Atom feed-level updated is the newest item, in RFC 3339' )
        or diag($atom);
};

subtest 'a page with no `date:` is dated from its file, and sorts by that' => sub {
    # MEASURED, because the first draft of this subtest asserted the opposite and
    # was simply wrong: a page with no `date:` in its front matter is NOT undated.
    # It takes its FILE MTIME - set the mtime to 2026-01-01 and the feed says
    # "Thu, 01 Jan 2026". So there is no undated case to place at either end, and
    # the sort has one rule rather than a rule and an exception.
    #
    # Worth pinning even though it is pre-existing: the sort now depends on it. A
    # change that made the fallback "now" instead would silently push every
    # dateless page to the top of every reader.
    page( 'damson.md', 'Damson', undef );
    my $then = 1767225600;    # 2026-01-01, older than every dated page here
    utime( $then, $then, "$docroot/damson.md" )
        or plan skip_all => "cannot set mtime: $!";
    run_processor( $docroot, '/damson' );

    my $r = feed('feed.rss');
    my @t = titles_in_order( $r, 'item' );
    is( $t[-1], 'Damson',
        'an mtime-dated page sorts by that date like any other - last here, '
            . 'because 2026-01-01 is the oldest in the fixture' )
        or diag($r);
    like( $r, qr{<title>Damson</title>.*?<pubDate>\w+, 01 Jan 2026}s,
        'and the date it carries is the file mtime, not "now"' )
        or diag($r);
    unlink "$docroot/damson.md";
};

subtest 'feed_items bounds the list, newest kept' => sub {
    # FO3, ruled 2026-10-02: cap at 50 by default, configurable. Set to 2 here so
    # the fixture does not need 51 pages to prove the mechanism.
    my $conf = "$docroot/lazysite/lazysite.conf";
    open my $fh, '>>', $conf or die "$conf: $!";
    print {$fh} "feed_items: 2\n";
    close $fh;

    my $r = feed('feed.rss');
    my @t = titles_in_order( $r, 'item' );
    is( scalar @t, 2, 'two items, not three' ) or diag($r);
    is_deeply( \@t, [ 'Banana', 'Cherry' ],
        'and they are the NEWEST two - a cap that kept the oldest would be a '
            . 'second defect wearing the first one\'s clothes' );
};

subtest 'the cap can be switched off, and a bad value is ignored' => sub {
    my $conf = "$docroot/lazysite/lazysite.conf";
    for my $val ( '0', 'lots' ) {
        open my $fh, '<', $conf or die $!;
        my @l = grep { !/^feed_items:/ } <$fh>;
        close $fh;
        open my $w, '>', $conf or die $!;
        print {$w} @l, "feed_items: $val\n";
        close $w;

        my @t = titles_in_order( feed('feed.rss'), 'item' );
        if ( $val eq '0' ) {
            is( scalar @t, 3, "feed_items: 0 means all of them" );
        }
        else {
            is( scalar @t, 3,
                "a non-numeric feed_items falls back to the default (50), so a "
                    . "typo cannot silently empty a feed" );
        }
    }
};

done_testing();
