#!/usr/bin/perl
# n814 (SM1437), test plan 0.16.10 Y5: THE /docs SHADOW CHECK COVERS EVERY
# DOMAIN'S CONTENT ROOT.
#
# edge2 (sites/edge2/) held its own copies of /docs pages with the old titles, and
# the check printed no "site page(s) shadow a newer version of the engine's /docs
# manual" line: it looked at the primary's docs/ only. It now looks at the primary
# and at each declared content root, and names the domain on its line (ruling 199:
# a site with one domain is not told which).
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Basename qw(dirname);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir run_child);

my $script = repo_root() . '/tools/lazysite-check.pl';
sub spit { my ( $p, $t ) = @_; make_path( dirname($p) ); open my $fh, '>', $p or die "$p: $!"; print {$fh} $t; close $fh; return }
sub check_out { run_child( [ $^X, $script, '--docroot', $_[0] ], stderr => 'merge' )->{out} // '' }

my $doc = site_tempdir();
make_path("$doc/lazysite/$_") for qw(auth cache logs manager);
spit( "$doc/lazysite/templates/docs/guide.md", "---\ntitle: Guide\nsubtitle: S\n---\nEngine\n" );
spit( "$doc/lazysite/templates/docs/other.md", "---\ntitle: Other\nsubtitle: S\n---\nEngine\n" );
spit( "$doc/lazysite/lazysite.conf",
    "site_name: T\nsite_url: https://main.example\nalias_hosts: two.example\nalias.two.example.content_root: sites/two\n" );
spit( "$doc/index.md",           "---\ntitle: Home\nsubtitle: Welcome\n---\nH\n" );
spit( "$doc/sites/two/index.md", "---\ntitle: Two\nsubtitle: Welcome\n---\nH\n" );

my $out = check_out($doc);
unlike( $out, qr/shadow a newer version/, 'no site copy anywhere: nothing to warn' ) or diag $out;

spit( "$doc/sites/two/docs/guide.md", "---\ntitle: Old guide\nsubtitle: S\n---\nOld\n" );
$out = check_out($doc);
like( $out, qr/two\.example: 1 site page\(s\) shadow a newer version of the engine's \/docs manual - [^\n]*docs\/guide\.md/,
    'the domain\'s own copy is named, on a line that names the domain' )
    or diag $out;

spit( "$doc/docs/other.md", "---\ntitle: Old other\nsubtitle: S\n---\nOld\n" );
$out = check_out($doc);
like( $out, qr/main\.example: 1 site page\(s\) shadow[^\n]*docs\/other\.md/, 'and the primary\'s, on its own line' ) or diag $out;
like( $out, qr/two\.example: 1 site page\(s\) shadow[^\n]*docs\/guide\.md/, 'beside the other domain\'s' );

done_testing;
