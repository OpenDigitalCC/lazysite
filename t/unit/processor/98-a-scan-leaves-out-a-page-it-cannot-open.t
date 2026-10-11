#!/usr/bin/perl
# P25 (WORK-PLAN-0154): a page the scan cannot OPEN is left out and named, as
# Q15h/Q15i did for a page whose bytes are not UTF-8 (t/unit/processor/93).
#
# Both walks - resolve_scan (a `scan:` source) and scan_pages (the registries) -
# called read_file outside the guard Q15h put around the parse, and read_file
# dies when open fails. So one page the server's user may not read (a file
# copied in by root with mode 0600, say) failed every page whose scan reached
# it, the home page among them when lazysite.conf names the scan, and the
# sitemap. The open is now inside the guard: the page is left out and logged by
# its docroot-relative path, with the reason.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site site_tempdir run_processor);

plan skip_all => 'running as root: a mode-0 file can still be opened' if $> == 0;

local $ENV{LAZYSITE_FORWARD_DIAGNOSTICS} = 'off';
local $ENV{LAZYSITE_LOG_LEVEL}           = 'INFO';

my $d = site_tempdir();
setup_minimal_site($d);
make_path( "$d/blog", "$d/lazysite/templates/registries" );
sub spit { my ( $p, $t ) = @_; open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
open my $cf, '>>', "$d/lazysite/lazysite.conf" or die $!;
print {$cf} "blog_pages: scan:/blog/*.md\n";
close $cf;
spit( "$d/blog/a.md",      "---\ntitle: A\nregister:\n  - sitemap.xml\n---\nA\n" );
spit( "$d/blog/locked.md", "---\ntitle: LOCKED\nregister:\n  - sitemap.xml\n---\nL\n" );
chmod 0000, "$d/blog/locked.md" or die $!;
END { chmod 0644, "$d/blog/locked.md" if defined $d }
plan skip_all => 'a mode-0 file could still be opened here' if open my $probe, '<', "$d/blog/locked.md";
spit( "$d/list.md", "---\ntitle: L\n---\n[% FOREACH p IN blog_pages %]<i>[% p.title %]</i>[% END %]\n" );
spit( "$d/lazysite/templates/registries/sitemap.xml.tt", "[% FOREACH p IN pages %][% p.url %]\n[% END %]" );

sub status { my ($out) = @_; return ( ( $out // '' ) =~ /^Status: (\d+)/ )[0] // '200' }

subtest 'through the processor: one page cannot fail the site' => sub {
    is( status( run_processor( $d, '/' ) ), 200, 'the home page renders' );
    my $list = run_processor( $d, '/list' );
    is( status($list), 200, 'a page listing the scan renders' );
    like( $list, qr{<i>A</i>}, 'and lists the readable page' );
    unlike( $list, qr{LOCKED}, 'and not the one it cannot open' );
    my $map = run_processor( $d, '/sitemap.xml' );
    is( status($map), 200, 'the sitemap is generated' );
    like( $map, qr{^/blog/a$}m, 'listing the readable page' );
    unlike( $map, qr{/blog/locked}, 'and not the other' );
};

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
    subtest "$name leaves the page out, and names it" => sub {
        my ( $err, $log, @got ) = with_log($code);
        is( $err, '', "$name does not die" );
        is_deeply( \@got, $want, 'and returns every readable page' );
        like( $log, qr/\[WARN\] \[processor\] \[scan\] a page whose file cannot be opened is left out/,
            'the page is logged at WARN' );
        like( $log, qr{page=blog/locked\.md}, '...by its docroot-relative path' );
        like( $log, qr/error=Cannot read \S+: Permission denied/, '...with why' );
        unlike( $log, qr{\Q$d\E}, '...and not the server path' );
    };
}

done_testing();
