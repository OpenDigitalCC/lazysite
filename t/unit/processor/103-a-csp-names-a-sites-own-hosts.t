#!/usr/bin/perl
# P16 (WORK-PLAN-0154, ruled 2026-10-12 "Add allow-lists"): a site that embeds a
# script from another host (a banner whose script then fetches from its own
# host) had no setting to permit it under `csp: enforce`. csp_script_src,
# csp_connect_src, csp_img_src and csp_frame_src in lazysite.conf - each a list
# of https origins - are appended to the default, per domain on a multi-domain
# instance; an entry that is not an origin is left out and logged, and
# `lazysite check` names it.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(setup_minimal_site site_tempdir run_processor repo_root);

my $d = site_tempdir();
setup_minimal_site($d);
sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

spit( "$d/lazysite/lazysite.conf", <<'CONF' );
site_name: Main
site_url: https://main.test
csp: enforce
csp_script_src: https://perl-ads.perlhacks.com, 'unsafe-inline' *
csp_connect_src: https://perl-ads.perlhacks.com
alias_hosts: other.test
alias.other.test.content_root: sites/other
alias.other.test.csp_script_src: https://*.other-cdn.example
CONF
make_path("$d/sites/other");
spit( "$d/page.md",             "---\ntitle: P\n---\nHello\n" );
spit( "$d/sites/other/page.md", "---\ntitle: O\n---\nHello\n" );

sub csp {
    my ($host) = @_;
    my $o      = run_processor( $d, '/page', HTTP_HOST => $host ) // '';
    return ( $o =~ /^Content-Security-Policy: ([^\r\n]+)/m )[0] // '(none)';
}
sub directive { my ( $csp, $name ) = @_; return ( $csp =~ /(?:^|; )(\Q$name\E[^;]*)/ )[0] // '' }

subtest 'the site\'s lists are appended to the default, enforced' => sub {
    my $c = csp('main.test');
    like( directive( $c, 'script-src' ), qr{\Ascript-src 'self' https://perl-ads\.perlhacks\.com\b},
        'script-src names the host after \'self\'' );
    is( directive( $c, 'connect-src' ), q{connect-src 'self' https://perl-ads.perlhacks.com},
        'connect-src too' );
    unlike( $c, qr/'unsafe-inline' \*|script-src[^;]*'unsafe-inline'|script-src[^;]* \*(?:;|$| )/,
        'the entries that are not origins are left out' );
    is( directive( $c, 'img-src' ), q{img-src 'self' data: https:}, 'a directive with no list is the default' );
};

subtest 'a domain\'s own list replaces the site\'s for that domain' => sub {
    my $c = csp('other.test');
    like( directive( $c, 'script-src' ), qr{\Ascript-src 'self' https://\*\.other-cdn\.example\b},
        'other.test names its own host' );
    unlike( directive( $c, 'script-src' ), qr/perl-ads/, 'and not the primary\'s' );
    is( directive( $c, 'connect-src' ), q{connect-src 'self' https://perl-ads.perlhacks.com},
        'inheriting the lists it does not override' );
};

subtest 'lazysite check names the entries that are not origins' => sub {
    my $root = repo_root();
    my $out  = qx(\Q$^X\E \Q$root/tools/lazysite-check.pl\E --docroot \Q$d\E 2>&1);
    like( $out, qr/2 CSP allow-list entries are not an https origin/, 'two, counted' );
    like( $out, qr/lazysite\.conf:4 csp_script_src ''unsafe-inline''/, 'each named with its line' );
};

done_testing();
