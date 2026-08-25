#!/usr/bin/perl
# SM558: a link to the root page as /index or /index.html was always reported
# broken. canonical() maps index.md to '', but the broken-link check only
# stripped a TRAILING /index from the target, so /docs/index resolved while
# the bare /index never did. The report cried wolf on every site that linked
# home that way.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $PLUGIN = repo_root() . '/plugins/audit.pl';
ok( -f $PLUGIN, 'audit plugin present' );

my $d = tempdir( CLEANUP => 1 );
make_path("$d/lazysite");
make_path("$d/docs");

sub w {
    my ( $p, $c ) = @_;
    open my $fh, '>', $p or die $!;
    print {$fh} $c;
    close $fh;
    return;
}
w( "$d/index.md",      "---\ntitle: Home\n---\n[about](/about) [docs](/docs)\n" );
w( "$d/about.md",      "---\ntitle: About\n---\n[home](/index) [home2](/index.html) "
        . "[docs home](/docs/index) [gone](/missing-page)\n" );
w( "$d/docs/index.md", "---\ntitle: Docs\n---\n[up](/about)\n" );

my $out = qx($^X \Q$PLUGIN\E --docroot \Q$d\E 2>/dev/null);
unlike( $out, qr{about\.md\s+->\s+/index\b},   '/index is not reported broken' );
unlike( $out, qr{about\.md\s+->\s+/index\.html}, '/index.html is not reported broken' );
unlike( $out, qr{->\s+/docs/index}, 'a trailing /index still resolves (unchanged)' );
like( $out, qr{about\.md\s+->\s+/missing-page}, 'a genuinely missing target is still reported' );
like( $out, qr/BROKEN LINKS \(1\)/, 'exactly the one real broken link' );

done_testing();
