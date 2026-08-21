#!/usr/bin/perl
# The Files page's alias card lists the aliases for the folder being browsed.
#
# It listed every alias on the site regardless of where the operator was
# standing, so a site with a hundred redirects answered "which of these belong
# to the folder I am looking at?" by making them read all hundred. The card
# sits under a directory listing; it should describe that directory.
#
# THE FILTER IS SERVER-SIDE ON PURPOSE. The folder-to-URL translation needs the
# CONTENT ROOT: a page at sites/alpha/blog/post.md answers to /blog/post,
# because the vhost strips the root at request time. That is precisely the
# mapping SM440 got wrong, and a second copy of it in JavaScript could drift
# from this one without anything failing.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(setup_multi_domain_site);
use Lazysite::Aliases         ();
use Lazysite::Manager::Files  ();
use Lazysite::Manager::Common ();

my $s = setup_multi_domain_site();
my $d = $s->{docroot};
$Lazysite::Manager::Files::DOCROOT  = $d;
$Lazysite::Manager::Common::DOCROOT = $d;

sub page { return "---\naliases:\n  - $_[0]\n---\n\nbody\n" }

# Two pages in different folders of the SAME site, plus one at the docroot.
make_path("$d/sites/alpha/blog", "$d/sites/alpha/docs");
Lazysite::Aliases::index_page( $d, 'sites/alpha/blog/post.md',  page('/old-post') );
Lazysite::Aliases::index_page( $d, 'sites/alpha/docs/guide.md', page('/old-guide') );
Lazysite::Aliases::index_page( $d, 'about.md',                  page('/old-about') );

sub aliases_in {
    my ( $host, $path ) = @_;
    my $r = Lazysite::Manager::Files::action_aliases_list( $host, $path );
    return [ sort map { $_->{alias} } @{ $r->{aliases} || [] } ];
}

subtest 'a folder shows only the aliases pointing into it' => sub {
    is_deeply( aliases_in( 'alpha.test', '/sites/alpha/blog' ), ['/old-post'],
        'the blog folder shows the blog alias' )
        or diag( 'An unscoped card makes the operator read every redirect on '
            . 'the site to find the ones under the folder they are in.' );
    is_deeply( aliases_in( 'alpha.test', '/sites/alpha/docs' ), ['/old-guide'],
        'and the docs folder shows the docs alias' );
};

subtest 'a sibling folder whose URL PREFIXES another is not swallowed' => sub {
    # /blog must not claim /blogroll. A bare index($target,$prefix)==0 does,
    # and without this case that sabotage passes cleanly - the fourth time
    # this exact masking has hidden a containment bug in this repo (CF-2,
    # SM441's preview test, SM440's alias test, and here).
    make_path("$d/sites/alpha/blogroll");
    Lazysite::Aliases::index_page( $d, 'sites/alpha/blogroll/list.md',
        page('/old-roll') );
    my $blog = aliases_in( 'alpha.test', '/sites/alpha/blog' );
    ok( !( grep { $_ eq '/old-roll' } @{$blog} ),
        '/blog does not claim /blogroll' )
        or diag( 'Prefix matching without the boundary shows a neighbouring '
            . "folder's redirects as if they belonged to this one." );
    is_deeply( aliases_in( 'alpha.test', '/sites/alpha/blogroll' ),
        ['/old-roll'], 'and the sibling shows its own' );
};

subtest 'the site root shows all of that site\'s aliases' => sub {
    is_deeply( aliases_in( 'alpha.test', '/sites/alpha' ),
        [ '/old-guide', '/old-post', '/old-roll' ],
        'the content root is the whole site, so all of them appear' )
        or diag( 'Scoping must not hide a site\'s own aliases when the '
            . 'operator is standing at its root.' );
};

subtest 'the content root is STRIPPED, not matched literally' => sub {
    # The page lives at sites/alpha/blog/post.md and answers to /blog/post.
    # A filter comparing the docroot path against the target would match
    # nothing at all, and the card would be permanently empty on every
    # content-root site - a silent, plausible-looking emptiness.
    my $r = Lazysite::Manager::Files::action_aliases_list( 'alpha.test',
        '/sites/alpha/blog' );
    my ($row) = @{ $r->{aliases} || [] };
    ok( $row, 'a row is returned at all' )
        or diag( 'Comparing /sites/alpha/blog against a target of /blog/post '
            . 'matches nothing - and an empty card looks like "no aliases".' );
    is( $row->{target}, '/blog/post', 'and its target is site-relative' );
};

subtest 'a neighbouring domain is not shown' => sub {
    Lazysite::Aliases::index_page( $d, 'sites/beta/index.md', page('/beta-only') );
    my $alpha = aliases_in( 'alpha.test', '/sites/alpha' );
    ok( !( grep { $_ eq '/beta-only' } @{$alpha} ),
        "beta's alias does not appear under alpha" )
        or diag( 'SM440: one map per instance is how a neighbour\'s alias '
            . 'showed up - and answered - on another site.' );
};

subtest 'no path given lists everything, as before' => sub {
    my $all = aliases_in( 'alpha.test', undef );
    is( scalar @{$all}, 3, 'unscoped calls are unchanged' )
        or diag( 'Other callers must not silently start getting a subset.' );
};

done_testing();
