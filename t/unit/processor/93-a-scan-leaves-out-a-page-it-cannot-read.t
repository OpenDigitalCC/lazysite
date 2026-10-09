#!/usr/bin/perl
# SM976 Q15h (ruled 2026-10-09, "Refuse + walker skips"): the processor's two
# walks over every page's front matter - resolve_scan (a `scan:` source) and
# scan_pages (the registries) - leave out a page whose reading dies, and log
# it, so one such page cannot fail every page whose scan reaches it.
#
# Measured before (tmp/q15h-walkers-probe.before.out): one page under /blog/
# whose bytes are not UTF-8, put there by git or SSH, made both walks die. A
# site whose lazysite.conf names a `scan:` source over /blog/ answered 500 on
# every page, its home page included, and the sitemap answered 500.
use strict;
use warnings;
no warnings 'utf8';    # the page under test is not UTF-8 by design
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site site_tempdir run_processor);

local $ENV{LAZYSITE_FORWARD_DIAGNOSTICS} = 'off';
local $ENV{LAZYSITE_LOG_LEVEL}           = 'INFO';

my $d = site_tempdir();
setup_minimal_site($d);
make_path( "$d/blog", "$d/lazysite/templates/registries" );
sub spit { my ( $p, $t ) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "blog_pages: scan:/blog/*.md\n";
close $cf;
spit( "$d/blog/a.md", "---\ntitle: A\nregister:\n  - sitemap.xml\n---\nA\n" );
spit( "$d/blog/bad.md", "---\ntitle: B\nform:\xFF leads\nregister:\n  - sitemap.xml\n---\nB\n" );
spit( "$d/list.md", "---\ntitle: L\n---\n[% FOREACH p IN blog_pages %]<i>[% p.title %]</i>[% END %]\n" );
spit( "$d/lazysite/templates/registries/sitemap.xml.tt", "[% FOREACH p IN pages %][% p.url %]\n[% END %]" );

sub status { my ($out) = @_; return ( ( $out // '' ) =~ /^Status: (\d+)/ )[0] // '200' }

subtest 'through the processor: one page cannot fail the site' => sub {
    my $home = run_processor( $d, '/' );
    is( status($home), 200, 'the home page renders (the conf\'s scan: source reaches the page)' );
    my $list = run_processor( $d, '/list' );
    is( status($list), 200, 'a page listing the scan renders' );
    like( $list, qr{<i>A</i>}, 'and lists the readable page' );
    unlike( $list, qr{<i>B</i>}, 'and not the one it cannot read' );
    my $map = run_processor( $d, '/sitemap.xml' );
    is( status($map), 200, 'the sitemap is generated' );
    like( $map, qr{^/blog/a$}m, 'listing the readable page' );
    unlike( $map, qr{/blog/bad}, 'and not the other' );
};

# In process, to read what the walks log.
load_processor($d);
sub with_log {
    my ($code) = @_;
    my $log = "$d/stderr.log";
    open my $save, '>&', \*STDERR or die $!;
    open STDERR,   '>',  $log     or die $!;
    my @r   = eval { $code->() };
    my $err = $@;
    open STDERR, '>&', $save or die $!;
    open my $fh, '<',  $log  or die $!;
    return ( $err, do { local $/; <$fh> }, @r );
}

for my $walk (
    [ 'resolve_scan', sub { map { $_->{title} } @{ main::resolve_scan('/blog/*.md') } }, ['A'] ],
    [ 'scan_pages', sub { map { $_->{url} } main::scan_pages($d) }, ['/blog/a'] ],
    )
{
    my ( $name, $code, $want ) = @$walk;
    subtest "$name leaves the page out, and logs it" => sub {
        my ( $err, $log, @got ) = with_log($code);
        is( $err, '', "$name does not die" );
        is_deeply( \@got, $want, 'and returns every readable page' );
        like( $log, qr/\[WARN\] \[processor\] \[scan\] a page whose front matter cannot be read is left out/,
            'the page is logged at WARN' );
        like( $log, qr{page=blog/bad\.md}, '...by its docroot-relative path' );
        like( $log, qr/error=Malformed UTF-8 character/, '...with why its reading died' );
    };
}

# SM976 Q15i (ruled 2026-10-09, "Same rule"): resolve_scan's excerpt reads the
# body, which the front-matter guard never parsed. Measured before
# (tmp/q15i-more-probe.before.out): a page whose front matter is UTF-8 and whose
# body is not made a page listing the scan answer 500.
subtest 'a page whose body cannot be read is left out of a scan, and logged' => sub {
    my $e = site_tempdir();
    setup_minimal_site($e);
    make_path("$e/blog");
    open my $ef, '>>', "$e/lazysite/lazysite.conf" or die $!;
    print {$ef} "blog_pages: scan:/blog/*.md\n";
    close $ef;
    spit( "$e/blog/a.md", "---\ntitle: A\n---\nA body\n" );
    spit( "$e/blog/bodybad.md", "---\ntitle: Bodybad\n---\nSee [home](/) caf\xFF leads <!-- c -->\n" );
    spit( "$e/list.md", "---\ntitle: L\n---\n[% FOREACH p IN blog_pages %]<i>[% p.title %]:[% p.excerpt %]</i>[% END %]\n" );
    my $list = run_processor( $e, '/list' );
    is( status($list), 200, 'a page listing the scan renders' );
    like( $list, qr{<i>A:A body</i>}, 'and lists the readable page with its excerpt' );
    unlike( $list, qr{Bodybad}, 'and not the one whose body it cannot read' );

    load_processor($e);
    my ( $err, $log, @got ) = with_log( sub { map { $_->{title} } @{ main::resolve_scan('/blog/*.md') } } );
    is( $err, '', 'resolve_scan does not die' );
    is_deeply( \@got, ['A'], 'and returns every readable page' );
    like( $log, qr/\[WARN\] \[processor\] \[scan\] a page whose body cannot be read is left out/,
        'the page is logged at WARN, naming the body' );
    like( $log, qr{page=blog/bodybad\.md}, '...by its docroot-relative path' );
};

done_testing();
