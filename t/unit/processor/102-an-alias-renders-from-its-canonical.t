#!/usr/bin/perl
# P14 (WORK-PLAN-0154, ruled 2026-10-12 "Render from the canonical"): for a host
# registered as an alias - one sharing an earlier domain's content root, which
# is how domain-alias-add registers it and how domains_list derives alias_of -
# the canonical link, the sitemap and llms.txt carry the canonical domain's
# address. The alias keeps serving under its own name: its own site_url, its
# own pages, no redirect.
#
# Reported: www.harmony2050.org, registered beside harmony2050.org on the same
# content root, said its canonical was itself - one site, two canonicals.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_minimal_site site_tempdir run_processor);

my $d = site_tempdir();
setup_minimal_site($d);
sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

spit( "$d/lazysite/lazysite.conf", <<'CONF' );
site_name: Main
site_url: https://main.test
alias_hosts: canon.test, www.canon.test, other.test, chrome.test
alias.canon.test.content_root: sites/canon
alias.canon.test.site_url: https://canon.test
alias.www.canon.test.content_root: sites/canon
alias.www.canon.test.site_url: https://www.canon.test
alias.other.test.content_root: sites/other
alias.other.test.site_url: https://other.test
alias.chrome.test.site_url: https://chrome.test
CONF
make_path( "$d/sites/canon", "$d/sites/other", "$d/lazysite/templates/registries" );
my $PAGE = "---\ntitle: About\nregister:\n  - sitemap.xml\n  - llms.txt\n---\nSITE=[% site_url %] CANON=[% canonical_url %]\n";
spit( "$d/sites/canon/about.md", $PAGE );
spit( "$d/sites/other/about.md", $PAGE );
spit( "$d/about.md",             $PAGE );
spit( "$d/lazysite/templates/registries/sitemap.xml.tt", "[% FOREACH p IN pages %]<loc>[% site_url %][% p.url %]</loc>\n[% END %]" );
spit( "$d/lazysite/templates/registries/llms.txt.tt", "[% FOREACH p IN pages %]- [% site_url %][% p.url %]\n[% END %]" );

sub get {
    my ( $host, $uri ) = @_;
    return run_processor( $d, $uri, HTTP_HOST => $host, SERVER_NAME => $host ) // '';
}
sub canonical { my ($o) = @_; return ( $o =~ /<link rel="canonical" href="([^"]+)">/ )[0] // '(none)' }

subtest 'an alias names its canonical domain, and serves under its own name' => sub {
    my $o = get( 'www.canon.test', '/about' );
    is( canonical($o), 'https://canon.test/about', 'the canonical link is the canonical domain\'s' );
    like( $o, qr{SITE=https://www\.canon\.test }, 'site_url is still the alias\'s own' );
    like( $o, qr{CANON=https://canon\.test\b}, 'canonical_url is the canonical domain\'s' );
    unlike( $o, qr/^Status: 30[12]/m, 'served, not redirected' );
};

subtest 'the canonical domain and an unrelated one are their own (the controls)' => sub {
    is( canonical( get( 'canon.test', '/about' ) ), 'https://canon.test/about', 'the canonical domain' );
    is( canonical( get( 'other.test', '/about' ) ), 'https://other.test/about', 'a domain with its own root' );
    is( canonical( get( 'main.test', '/about' ) ), 'https://main.test/about', 'the primary' );
};

# The consequence ruled 2026-10-12, "Keep": a host with no content_root of its
# own (an SM110 chrome-only alias) serves the primary's content, so it is an
# alias of the primary and names the primary as canonical.
subtest 'a rootless domain names the primary as canonical' => sub {
    my $o = get( 'chrome.test', '/about' );
    is( canonical($o), 'https://main.test/about', 'the canonical link is the primary\'s' );
    like( $o, qr{SITE=https://chrome\.test }, 'site_url is still its own' );
};

subtest 'the registries in the shared root carry the canonical address' => sub {
    for my $reg ( 'sitemap.xml', 'llms.txt' ) {
        unlink glob("$d/sites/canon/$reg"), glob("$d/lazysite/cache/registries/*");
        my $o = get( 'www.canon.test', "/$reg" );
        like( $o, qr{https://canon\.test/about}, "$reg asked of the alias names the canonical domain" );
        unlike( $o, qr{www\.canon\.test}, '...and never the alias' );
    }
    my $o = get( 'other.test', '/sitemap.xml' );
    like( $o, qr{https://other\.test/about}, 'a domain with its own root keeps its own address' );
};

done_testing();
