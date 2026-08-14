#!/usr/bin/perl
# SM294: the two front doors decide identically.
#
# There are now two places that answer "who handles this URL?":
#
#   - Lazysite::FrontDoor::route, used by lazysite-front.pl (the CGI front door);
#   - a module-free copy inside lazysite-processor.pl, used when the FastCGI pool
#     worker IS the front door (ADR 0001 - the render path loads no Lazysite
#     modules, so it cannot simply call the first one).
#
# WHY THIS MATTERS MORE THAN AN ORDINARY DUPLICATE. Every incident this whole
# line of work exists to close - SM248, SM268 H17, SM283 - was the same shape: a
# front end and an engine that disagreed about who owned a URL. Nothing crashed
# in any of them. The site served, and served the wrong thing, for weeks in
# SM283's case. Two copies of the routing table drifting apart would reproduce
# that exactly, and would present as "it behaves differently under the pool" -
# a sentence nobody can act on.
#
# So this drives BOTH implementations over a table of URLs and compares the
# ANSWERS, rather than comparing source text: two implementations that read alike
# can still disagree, and it is the decision that ships.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper          qw(repo_root);
use Lazysite::FrontDoor ();

my $root = repo_root();

my $src = do {
    open my $fh, '<', "$root/lazysite-processor.pl" or die $!;
    local $/;
    <$fh>;
};

my ($route_block) = $src =~ m{\nsub _front_route \{\n(.*?)\n\}\n}s;
my ($dir_block)   = $src =~ m{\nsub _lazysite_dir_for \{\n(.*?)\n\}\n}s;

ok( $route_block, 'the processor carries its routing table in one sub' );
ok( $dir_block,   'and its engine-dir resolver' );
plan skip_all => 'processor structure changed; fix the extraction above'
    unless $route_block && $dir_block;

unlike( $route_block, qr/Lazysite::/,
    'the copy loads no Lazysite module (ADR 0001) - which is WHY it is a copy '
        . 'and therefore why this test exists' );

## no critic (BuiltinFunctions::ProhibitStringyEval)
my $built = eval qq{
    package FrontProbe;
    sub _lazysite_dir_for {$dir_block}
    sub _front_route {$route_block}
    1;
};
ok( $built, 'the processor copy compiles standalone' ) or do {
    diag($@);
    done_testing();
    exit;
};

# Two sites: one that has protected something, one that never has. The ACL store
# flips four of the eight rules, so testing only one of them would leave half the
# table uncompared.
my $base = tempdir( CLEANUP => 1 );
my %site;
for my $kind (qw(plain protected)) {
    my $d = "$base/$kind/public_html";
    make_path("$d/lazysite/auth");
    for my $f (
        "$d/lazysite/lazysite.conf", "$d/index.md",  "$d/logo.png",
        "$d/legacy.html",            "$d/old.shtml", "$d/docs/guide.md",
        )
    {
        make_path( $f =~ s{/[^/]+\z}{}r );
        open my $fh, '>', $f or die "$f: $!";
        print {$fh} "x\n";
        close $fh;
    }
    if ( $kind eq 'protected' ) {
        open my $fh, '>', "$d/lazysite/auth/acls.json" or die $!;
        print {$fh} '{"members":{"read":["alice"]}}';
        close $fh;
    }
    $site{$kind} = $d;
}

# Every rule in the table, plus the cases that decide between them. The comment
# on each names which rule it exercises, so a future edit that deletes a rule
# also has to decide what to do with its case.
my @cases = (
    [ '/lazysite/lazysite.conf',  '', 'GET', 'rule 0: engine-owned' ],
    [ '/lazysite',                '', 'GET', 'rule 0: engine dir itself' ],
    [ '/notes.brief',             '', 'GET', 'rule 0: authoring sidecar' ],
    [ '/cgi-bin/lazysite-mcp.pl', '', 'GET', 'rule 1: self-authenticating surface' ],
    [ '/cgi-bin/lazysite-processor.pl',   '', 'GET',  'rule 1: wrapped surface' ],
    [ '/cgi-bin/lazysite-manager-api.pl', '', 'POST', 'rule 1: wrapped surface' ],
    [ '/cgi-bin/lazysite-oauth.pl',       '', 'GET',  'rule 1: unwrapped surface' ],
    [ '/cgi-bin/nope.pl',                 '', 'GET',  'rule 1: not a lazysite surface' ],
    [ '/dav',                             '', 'GET',  'rule 2: dav root' ],
    [ '/dav/x/y.md',     '', 'PROPFIND', 'rule 2: dav deep' ],
    [ '/logo.png',       '', 'GET',      'rule 3/7: existing static' ],
    [ '/docs/guide.md',  '', 'GET',      'rule 3/7: existing source file' ],
    [ '/legacy',         '', 'GET',      'rule 4: legacy .html stem' ],
    [ '/old',            '', 'GET',      'rule 4: legacy .shtml stem' ],
    [ '/index',          '', 'GET',      'rule 4: stem WITH a .md - not legacy' ],
    [ '/',               '', 'GET',      'rule 5/8: root with index.md' ],
    [ '/members/secret', 'lazysite_auth=abc', 'GET', 'rule 6: signed in, miss' ],
    [ '/logo.png',       'lazysite_auth=abc', 'GET', 'rule 6 vs 3: signed in, hit' ],
    [ '/nothing/here',   '',                  'GET', 'rule 8: page miss' ],
    [ '/nothing/here?x=1&y=2', '',            'GET', 'rule 8: query stripped first' ],
);

for my $kind (qw(plain protected)) {
    my $d = $site{$kind};
    subtest "the two front doors agree on a $kind site" => sub {
        for my $c (@cases) {
            my ( $uri, $cookie, $method, $why ) = @{$c};
            my %req = (
                docroot => $d,      uri    => $uri,
                method  => $method, cookie => $cookie,
            );
            my $module    = Lazysite::FrontDoor::route( {%req} );
            my $processor = FrontProbe::_front_route( {%req} );
            is_deeply( $processor, $module, "$uri - $why" )
                or diag( "module:    " . _show($module) . "\n"
                    . "processor: " . _show($processor) );
        }
    };
}

sub _show {
    my ($h) = @_;
    return join ' ', map { "$_=" . ( $h->{$_} // 'undef' ) } sort keys %{$h};
}

done_testing();
