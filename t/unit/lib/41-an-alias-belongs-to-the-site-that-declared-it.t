#!/usr/bin/perl
# SM440: an alias must point at a URL its own site serves, and must not answer
# on anybody else's.
#
# TWO DEFECTS THAT COMPOUNDED. index_page took a DOCROOT-relative path and
# handed it to canonical_url_for, so a page under sites/dhcf/ produced the
# target /sites/dhcf/... - the prefix the vhost strips at request time. And
# the map was one file per INSTANCE, so whatever it produced answered on every
# domain.
#
# Field-confirmed, and the combination is worse than either half: on its own
# host /thesis 301'd to /sites/dhcf/publications/thesis and 404'd, so declaring
# the alias was WORSE than leaving it off. On the DEFAULT host - a different
# site, no relationship - the same 301 returned 200, because the default's
# content root IS the docroot, so the leaked path resolved. One site's alias
# silently served that site's page under a neighbour's domain.
#
# Fixing the derivation alone would leave one site able to claim a path on
# every other; fixing the map alone would leave every content-root site
# redirecting into its own 404. Both are asserted.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Aliases ();

my $CONF = <<'CONF';
site_name: Primary
alias_hosts: one.example, arch.example
alias.one.example.content_root: sites/one
alias.arch.example.content_root: sites/one-archive
CONF

sub fixture {
    my $d = tempdir( CLEANUP => 1 );
    make_path( "$d/lazysite", "$d/sites/one", "$d/sites/one-archive" );
    open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$c} $CONF;
    close $c;
    return $d;
}

sub map_at {
    my ($f) = @_;
    return {} unless -f $f;
    open my $fh, '<', $f or die $!;
    my $raw = do { local $/; <$fh> };
    close $fh;
    return decode_json( $raw || '{}' );
}

# The parser takes a LIST - `aliases:` then `- /path`, or `[/path]`. A scalar
# `aliases: /thesis` is silently ignored, which is worth knowing: the first
# version of this fixture used it and every assertion came back undef.
my $PAGE = "---\naliases:\n  - /thesis\n---\n\nbody\n";

subtest 'the target is relative to the site that serves it' => sub {
    my $d = fixture();
    Lazysite::Aliases::index_page( $d, 'sites/one/publications/thesis.md', $PAGE );
    my $m = map_at("$d/lazysite/aliases/sites_one.json");
    is( $m->{'/thesis'}, '/publications/thesis',
        'no content root in the target' )
        or diag( 'A target carrying the content root 301s to a path the vhost '
            . 'has already stripped - so the alias redirects into a 404, and '
            . 'declaring it is worse than leaving it off.' );
};

subtest 'and it lands in the DOMAIN\'s map, not the instance\'s' => sub {
    my $d = fixture();
    Lazysite::Aliases::index_page( $d, 'sites/one/publications/thesis.md', $PAGE );
    ok( -f "$d/lazysite/aliases/sites_one.json", 'the domain has its own map' );
    my $shared = map_at("$d/lazysite/aliases.json");
    is_deeply( $shared, {}, 'and the instance map is untouched' )
        or diag( 'One shared map is how a neighbouring site answered /thesis '
            . 'with 200 and served another organisation\'s page.' );
};

subtest 'a docroot page still uses the ORIGINAL file' => sub {
    # Single-site instances must see no change at all: same path, same file,
    # nothing to migrate. That is what makes this safe to ship.
    my $d = fixture();
    Lazysite::Aliases::index_page( $d, 'about.md', $PAGE );
    my $m = map_at("$d/lazysite/aliases.json");
    is( $m->{'/thesis'}, '/about', 'written to lazysite/aliases.json as before' );
    ok( !-d "$d/lazysite/aliases", 'and no per-domain directory is created' );
};

subtest 'a sibling whose name PREFIXES a content root is not swallowed' => sub {
    # sites/one must not claim sites/one-archive. Both are registered here, so
    # a containment bug shows as the alias landing in the WRONG map rather
    # than merely being mis-derived.
    my $d = fixture();
    Lazysite::Aliases::index_page( $d, 'sites/one-archive/old/thesis.md', $PAGE );
    my $arch = map_at("$d/lazysite/aliases/sites_one-archive.json");
    is( $arch->{'/thesis'}, '/old/thesis', 'the archive gets its own alias' );
    is_deeply( map_at("$d/lazysite/aliases/sites_one.json"), {},
        'and the registered prefix sibling claims nothing' );

    # THE CASE THAT ACTUALLY TESTS CONTAINMENT. Above, BOTH names are
    # registered, so longest-match picks the archive whether containment is
    # boundary-safe or not - a bare index($rel,$cr)==0 sabotage passes it
    # cleanly. The sibling has to be UNREGISTERED for only correct containment
    # to give the right answer. (Third time this masking has hidden the bug in
    # this repo; see SM441's preview test and CF-2.)
    my $d2 = fixture();
    Lazysite::Aliases::index_page( $d2, 'sites/one-drafts/x.md', $PAGE );
    is_deeply( map_at("$d2/lazysite/aliases/sites_one.json"), {},
        'an UNCLAIMED prefix sibling is not swallowed by sites/one' )
        or diag( 'Bare prefix containment: sites/one claims sites/one-drafts, '
            . 'so the draft is filed under - and derived relative to - a site '
            . 'it does not belong to.' );
    is( map_at("$d2/lazysite/aliases.json")->{'/thesis'},
        '/sites/one-drafts/x', 'it belongs to the docroot instead' );
};

subtest 'deindex removes it from the same map' => sub {
    my $d = fixture();
    Lazysite::Aliases::index_page( $d, 'sites/one/publications/thesis.md', $PAGE );
    Lazysite::Aliases::deindex_page( $d, 'sites/one/publications/thesis.md' );
    is_deeply( map_at("$d/lazysite/aliases/sites_one.json"), {},
        'gone' )
        or diag( 'deindex_page shared the broken derivation, so a stale entry '
            . 'could not be cleared by the operation meant to clear it.' );
};

subtest 'a PRE-FIX entry in the shared map is cleared by a re-save' => sub {
    # Before the fix, a page under a content root wrote into the SHARED map
    # with a DOCROOT-relative target. After it, the same page writes into its
    # own domain's map with a site-relative one - different file AND different
    # key - so nothing the page does touches the old entry.
    #
    # Measured before this was written: re-saving left it, and deleting left
    # it. That matters because the shared map is still read for the docroot,
    # which is the DEFAULT host, so a stale entry keeps answering there and
    # serving another site's page under the default domain. An upgrade would
    # have frozen every pre-existing leak in exactly that state, unreachable
    # by any content operation.
    my $d = fixture();
    open my $m, '>', "$d/lazysite/aliases.json" or die $!;
    print {$m} '{"/thesis":"/sites/one/publications/thesis"}';
    close $m;

    Lazysite::Aliases::index_page( $d, 'sites/one/publications/thesis.md', $PAGE );
    is_deeply( map_at("$d/lazysite/aliases.json"), {},
        'the legacy entry is gone after a re-save' )
        or diag( 'It answers on the default host and no content operation '
            . 'can reach it, so it would outlive the page that declared it.' );
    is( map_at("$d/lazysite/aliases/sites_one.json")->{'/thesis'},
        '/publications/thesis', 'and the correct entry replaced it' );
};

subtest 'and a delete clears it too' => sub {
    my $d = fixture();
    open my $m, '>', "$d/lazysite/aliases.json" or die $!;
    print {$m} '{"/thesis":"/sites/one/publications/thesis"}';
    close $m;
    Lazysite::Aliases::deindex_page( $d, 'sites/one/publications/thesis.md' );
    is_deeply( map_at("$d/lazysite/aliases.json"), {},
        'removing the page removes its legacy entry' );
};

subtest 'the purge is PRECISE, not a sweep of the shared map' => sub {
    # The docroot's own aliases live in that file legitimately. Clearing more
    # than the one page's legacy entry would delete the primary's redirects as
    # a side effect of editing an unrelated domain's page.
    my $d = fixture();
    open my $m, '>', "$d/lazysite/aliases.json" or die $!;
    print {$m} '{"/thesis":"/sites/one/publications/thesis",'
        . '"/keep-me":"/about","/also":"/sites/one-drafts/x"}';
    close $m;

    Lazysite::Aliases::index_page( $d, 'sites/one/publications/thesis.md', $PAGE );
    my $shared = map_at("$d/lazysite/aliases.json");
    is( $shared->{'/keep-me'}, '/about',
        "the primary's own alias survives" )
        or diag( 'A sweep would delete the default site\'s redirects whenever '
            . 'anyone edited a page on another domain.' );
    is( $shared->{'/also'}, '/sites/one-drafts/x',
        'and so does an entry for a different page' );
    ok( !exists $shared->{'/thesis'}, 'only this page\'s legacy entry goes' );
};

done_testing();
