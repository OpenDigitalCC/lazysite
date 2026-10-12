#!/usr/bin/perl
# P14 (WORK-PLAN-0154): which domain a host is an alias of has one answer.
#
# Lazysite::Manager::Domains::domains_list derives alias_of - the first row
# carrying a content root, the primary first, then alias_hosts in order - and
# the manager shows it. The render path cannot load that module (ADR 0001), so
# the processor carries a marked copy, _canonical_of, and renders an alias's
# canonical link, sitemap and llms.txt from its answer. Two derivations of one
# relationship drift; this runs both over the same confs and requires that the
# processor's canonical for every host is the row domains_list names, with that
# row's site_url.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper                 qw(load_processor setup_minimal_site site_tempdir);
use Lazysite::Manager::Domains ();

my $d = site_tempdir();
setup_minimal_site($d);
load_processor($d);

my @CONFS = (
    "site_url: https://p.test\n",
    "site_url: https://p.test\nalias_hosts: a.test, b.test\n"
        . "alias.a.test.content_root: s/a\nalias.a.test.site_url: https://a.test\n"
        . "alias.b.test.content_root: s/a\nalias.b.test.site_url: https://b.test\n",
    "site_url: https://p.test\nalias_hosts: a.test, b.test\n"
        . "alias.a.test.site_url: https://a.test\nalias.b.test.content_root: s/b\n",
    "site_url: https://p.test\ncontent_root: home\nalias_hosts: x.test, y.test, z.test\n"
        . "alias.x.test.content_root: s/x\nalias.y.test.content_root: home\n"
        . "alias.z.test.content_root: s/x\nalias.z.test.site_url: https://z.test\n"
        . "alias.x.test.site_url: https://x.test\n",
    "site_url: https://p.test\nalias_hosts: b.test, a.test\n"
        . "alias.a.test.content_root: s/same\nalias.b.test.content_root: s/same\n"
        . "alias.a.test.site_url: https://a.test\nalias.b.test.site_url: https://b.test\n",
);

my $n = 0;
for my $conf (@CONFS) {
    $n++;
    open my $fh, '>', "$d/lazysite/lazysite.conf" or die $!;
    print {$fh} $conf;
    close $fh;
    local $Lazysite::Manager::Domains::DOCROOT = $d;
    my $list = Lazysite::Manager::Domains::domains_list();
    ok( $list->{ok}, "conf $n: domains_list answers" ) or next;
    my %row = map { ( $_->{is_primary} ? '' : lc $_->{host} ) => $_ } @{ $list->{domains} };
    for my $host ( sort keys %row ) {
        my $of   = $row{$host}{alias_of} // '';
        my $want = length $of ? ( $of eq '(default)' ? '' : lc $of ) : $host;
        my ( $got, $url ) = main::_canonical_of( $conf, $host );
        is( $got, $want, "conf $n: '" . ( length $host ? $host : '(default)' ) . "' is canonical to '$want'" );
        is( $url, $row{$want}{site_url} // '', "conf $n: ...with that row's site_url" );
    }
}
cmp_ok( $n, '>=', 5, 'every conf was compared' );

done_testing();
