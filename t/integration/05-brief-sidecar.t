#!/usr/bin/perl
# SM073: .brief sidecars are never served publicly and never indexed.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(setup_test_site run_processor repo_root);

my $docroot = tempdir( CLEANUP => 1 );
setup_test_site($docroot);
make_path("$docroot/lazysite/templates/registries");

# A registry template that lists every registered page (one line each).
open my $tf, '>', "$docroot/lazysite/templates/registries/sitemap.tt" or die $!;
print $tf "[%- FOREACH p IN pages -%]\nURL: [% p.url %]\n[% END -%]\n";
close $tf;

# A real page (registered) and its brief sidecar. The brief is given a
# register: line on purpose, to prove it is excluded regardless.
open my $p, '>', "$docroot/about.md" or die $!;
print $p "---\ntitle: About\nregister:\n  - sitemap\n---\nAbout body.\n";
close $p;
open my $b, '>', "$docroot/about.md.brief" or die $!;
print $b "---\ntitle: SHOULD NOT APPEAR\nregister:\n  - sitemap\n---\nintent: the about page\n";
close $b;

# 1. The processor refuses to serve a .brief publicly.
my $out = run_processor( $docroot, '/about.md.brief' );
like(   $out, qr/Status:\s*404/, '.brief request returns 404 from the processor' );
unlike( $out, qr/intent: the about page/, 'brief body never reaches the client' );

# 2. The .brief is excluded from the generated registry (sitemap / llms.txt).
run_processor( $docroot, '/index' );   # triggers update_registries()
ok( -f "$docroot/sitemap", 'registry output produced' );
open my $fh, '<', "$docroot/sitemap" or die $!;
my $reg = do { local $/; <$fh> };
close $fh;
like(   $reg, qr{URL:\s*/about\b},   'the real page is in the registry' );
unlike( $reg, qr/about\.md\.brief/,  '.brief is NOT in the registry' );
unlike( $reg, qr/SHOULD NOT APPEAR/, 'brief front-matter is never indexed' );

# 3. The shipped Apache template denies .brief at the origin (the primary
#    guard: FallbackResource serves existing files raw otherwise).
# Every shipped vhost template must deny .brief - especially lazysite-app.*,
# which is the one the deploy actually applies. (lazysite.* is the basic
# variant.)
for my $t (qw( lazysite.tpl lazysite.stpl lazysite-app.tpl lazysite-app.stpl )) {
    open my $th, '<', repo_root() . "/installers/hestia/$t" or die "$t: $!";
    my $tpl = do { local $/; <$th> };
    close $th;
    like( $tpl, qr/FilesMatch[^>]*brief/, "$t denies .brief at the origin" );
}

done_testing();
