#!/usr/bin/perl
# The multi-domain fixture, and the guarantee it exists to provide.
#
# Ten defects surfaced in one week of real multi-site use with every suite
# green throughout, and each needed TWO SITES ON ONE INSTANCE to appear. On a
# single site the docroot IS the content root, the Host always matches, and
# "the primary" and "this domain" are the same thing - so the faults are
# unreachable and the tests pass truthfully while describing a shape the estate
# no longer has.
#
# SM440's filing states the requirement: the regression test must be one a
# single-site instance CANNOT pass. This asserts the fixture builds that
# instance, and - more usefully - that the four real defects are DETECTABLE in
# it. A fixture nobody can fail is scenery.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use lib "$FindBin::Bin/../../../lib";
use TestHelper qw(setup_multi_domain_site);
use Lazysite::Manager::Domains ();
use Lazysite::Aliases          ();

my $s = setup_multi_domain_site();
my $d = $s->{docroot};
$Lazysite::Manager::Domains::DOCROOT = $d;

subtest 'it really is multi-domain' => sub {
    my $r = Lazysite::Manager::Domains::domains_list();
    ok( $r->{ok}, 'domains list' );
    my @hosts = map { $_->{host} } grep { !$_->{is_primary} } @{ $r->{domains} };
    is( scalar @hosts, 3, 'three domains beside the primary' );
    my ($alpha) = grep { $_->{host} eq 'alpha.test' } @{ $r->{domains} };
    is( $alpha->{content_root}, 'sites/alpha', 'with real content roots' );
    isnt( $alpha->{theme}, 'base', 'and a presentation of its own' )
        or diag( 'If every domain inherits the primary, SM441 is unreachable: '
            . 'a preview under the wrong Host looks identical to a right one.' );
};

subtest 'SM436 is reachable: a domain that is NOT the default' => sub {
    my ($h) = Lazysite::Manager::Domains::host_for_path('sites/alpha/index.md');
    is( $h, 'alpha.test', 'a path belongs to a domain other than the primary' )
        or diag( 'On one site every path belongs to the primary, so serving '
            . 'the primary by mistake is indistinguishable from correct.' );
};

subtest 'SM440 is reachable: a NEIGHBOUR to leak into' => sub {
    my $page = "---\naliases:\n  - /thesis\n---\n\nbody\n";
    Lazysite::Aliases::index_page( $d, 'sites/alpha/index.md', $page );
    my $own = Lazysite::Aliases::list_aliases( $d, 'sites_alpha' );
    ok( ( grep { $_->{alias} eq '/thesis' } @{$own} ), "alpha has the alias" );
    my $neighbour = Lazysite::Aliases::list_aliases( $d, 'sites_beta' );
    is_deeply( $neighbour, [], 'and beta - the neighbour - does not' )
        or diag( 'Without a second site there is nobody to leak onto, and the '
            . 'shared-map defect cannot be observed at all.' );
    my $primary = Lazysite::Aliases::list_aliases($d);
    is_deeply( $primary, [], 'nor the primary' );
};

subtest 'SM443 is reachable: one domain INHERITS, another does not' => sub {
    my $r = Lazysite::Manager::Domains::domains_list();
    my ($alpha) = grep { $_->{host} eq 'alpha.test' } @{ $r->{domains} };
    my ($beta)  = grep { $_->{host} eq 'beta.test' } @{ $r->{domains} };
    is( $alpha->{nav_file_inherited}, 0, 'alpha has its own nav' );
    is( $beta->{nav_file_inherited},  1, 'beta inherits it' )
        or diag( 'The destructive default - saving a domain that inherits and '
            . 'rewriting the shared file - needs both kinds present.' );
};

subtest 'containment is testable: nesting AND an unclaimed prefix sibling'
    => sub {
    my ($nested) = Lazysite::Manager::Domains::host_for_path('sites/alpha/inner/x.md');
    is( $nested, 'sub.alpha.test', 'the nested root wins on longest match' );

    # THE ONE THAT ACTUALLY CATCHES BARE-PREFIX CONTAINMENT. A registered
    # prefix sibling proves nothing - longest-match picks it whether the test
    # is boundary-safe or not, which let the same sabotage pass three times in
    # this repo before the fixtures were corrected. sites/alpha-near is
    # deliberately NOT a domain.
    my ($near) = Lazysite::Manager::Domains::host_for_path('sites/alpha-near/x.md');
    is( $near, '', 'an UNREGISTERED prefix sibling belongs to nobody' )
        or diag( 'sites/alpha swallowed sites/alpha-near: bare prefix '
            . 'containment, the defect this fixture exists to keep catching.' );
    ok( -f "$d/sites/alpha-near/index.md",
        'and it is a real directory, so the walk has something to mis-claim' );
};

done_testing();
