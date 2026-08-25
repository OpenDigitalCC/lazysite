#!/usr/bin/perl
# SM531: a .url page is a cache source.
#
# The processor renders <page>.url exactly as it renders <page>.md, so a
# <page>.html beside a .url is a generated cache. Manager/Themes.pm held four
# opinions about that: the activation sweep dropped the render; the wildcard
# invalidate kept it; the cache listing reported it has_source: 0; and the
# single-path branch refused a marker-less .url render as not-a-cache
# (tmp/tl-probe-url-cache.pl). An operator who cleared everything was served
# the stale .url page, and the listing told them it had no source at all.
#
# One _cache_source_exists($base) now answers for every walk. The SM133
# caution is unchanged: an .html with NEITHER sibling is legacy content and is
# never touched.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use lib "$FindBin::Bin/../../lib";
use Lazysite::Manager::Themes ();

my $root = tempdir( CLEANUP => 1 );
my $doc  = "$root/site";
make_path("$doc/lazysite");
$Lazysite::Manager::Themes::DOCROOT      = $doc;
$Lazysite::Manager::Themes::LAZYSITE_DIR = "$doc/lazysite";

sub _w {
    my ( $p, $c ) = @_;
    open my $f, '>', $p or die "$p: $!";
    print {$f} $c;
    close $f;
    return;
}

sub _fixture {
    _w( "$doc/a.md",   "# a\n" );
    _w( "$doc/a.html", "<html>a</html>" );
    _w( "$doc/b.url",  "https://example.org/\n" );
    _w( "$doc/b.html", "<html>b</html>" );
    _w( "$doc/c.html", "<html>orphan static</html>" );
    return;
}

sub _states {
    return join ' ',
        map { "$_=" . ( -e "$doc/$_.html" ? 'kept' : 'gone' ) } qw(a b c);
}

_fixture();

subtest 'the listing says a .url render has a source' => sub {
    my %has = map { $_->{path} => $_->{has_source} }
        @{ Lazysite::Manager::Themes::action_cache_list()->{cached} };
    is( $has{'/a.html'}, 1, 'the .md render has a source' );
    is( $has{'/b.html'}, 1, 'so does the .url render' )
        or diag('The listing told the operator this page had no source at all.');
    is( $has{'/c.html'}, 0, 'the orphan .html has none' );
};

subtest 'the per-host listing agrees' => sub {
    _w( "$doc/lazysite/lazysite.conf", "alias_hosts: h.example\n" );
    make_path("$doc/lazysite/cache/hosts/h.example");
    _w( "$doc/lazysite/cache/hosts/h.example/b.html", "<html>b</html>" );
    _w( "$doc/lazysite/cache/hosts/h.example/c.html", "<html>c</html>" );
    my %has = map { ( $_->{host} // '' ) . $_->{path} => $_->{has_source} }
        @{ Lazysite::Manager::Themes::action_cache_list()->{cached} };
    is( $has{'h.example/b.html'}, 1, 'a host slot of the .url page has a source' );
    is( $has{'h.example/c.html'}, 0, 'a host slot with no source has none' );
};

subtest 'invalidate everything drops the .url render' => sub {
    my $r = Lazysite::Manager::Themes::action_cache_invalidate('*');
    ok( $r->{ok}, 'the sweep runs' );
    is( $r->{count}, 2, 'two renders counted' );
    is( _states(), 'a=gone b=gone c=kept',
        'the .md and .url renders go; the orphan stays (SM133)' )
        or diag('invalidate(*) kept the .url render: the page is served stale.');
};

subtest 'invalidate one path clears the .url render' => sub {
    _fixture();
    my $r = Lazysite::Manager::Themes::action_cache_invalidate('/b');
    is( $r->{ok},      1, 'the .url render is a cache, so it can be cleared' )
        or diag explain $r;
    is( $r->{cleared}, 1, 'and one file was cleared' );
    ok( !-e "$doc/b.html", 'it is gone' );
    my $c = Lazysite::Manager::Themes::action_cache_invalidate('/c');
    is( $c->{kind}, 'not-a-cache', 'the orphan .html is still refused' );
    ok( -e "$doc/c.html", 'and still there' );
};

subtest 'the activation sweep agrees' => sub {
    _fixture();
    Lazysite::Manager::Themes::_invalidate_html_cache();
    is( _states(), 'a=gone b=gone c=kept', 'same three answers' );
};

subtest 'the four walks share one definition of a source' => sub {
    my $src = do {
        open my $fh, '<', "$FindBin::Bin/../../../lib/Lazysite/Manager/Themes.pm"
            or die $!;
        local $/;
        <$fh>;
    };
    my @calls = $src =~ /\b_cache_source_exists\(/g;
    is( scalar @calls, 5, 'five call sites, one definition' )
        or diag( 'Four hand-written source tests drifted once (SM531). '
            . 'One helper is how they stop drifting.' );
};

done_testing();
