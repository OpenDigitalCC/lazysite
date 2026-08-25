#!/usr/bin/perl
# SM550: the theme-mirror check RUNS.
#
# SM315 added report_theme_assets_mirrored so an operator learns that the
# active theme's stylesheet is not being served before visitors do - a page
# with no stylesheet still returns 200, so nothing else reports it. The sub
# read its layout and theme with conf_value('layout'), one argument to a
# ($file, $key) function: it opened a file named `layout`, got undef, and
# returned before looking. The standing check had never run.
#
# This is the review probe as a test: a site whose active theme carries its
# CSS beside theme.json and has no mirror under lazysite-assets/. The report
# must carry the theme line, and name the misplaced file.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root   = repo_root();
my $script = "$root/tools/lazysite-check.pl";
plan skip_all => 'lazysite-check.pl missing' unless -f $script;

my $base = tempdir( CLEANUP => 1 );
my $doc  = "$base/public_html";
make_path("$doc/lazysite/$_") for qw(auth cache logs manager);
my $tdir = "$doc/lazysite/layouts/foo/themes/bar";
make_path($tdir);

open my $cf, '>', "$doc/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\nlayout: foo\ntheme: bar\n";
close $cf;

# The author's mistake SM315 was written to name: the stylesheet sits beside
# theme.json instead of under assets/, so nothing gets mirrored.
for my $f (qw(theme.json theme.css)) {
    open my $fh, '>', "$tdir/$f" or die $!;
    print {$fh} $f =~ /json/ ? "{}\n" : "body{}\n";
    close $fh;
}

my $out = qx($^X \Q$script\E --docroot \Q$doc\E 2>&1);

like( $out, qr/no mirrored assets/,
    'a theme with nothing mirrored is reported' )
    or diag("The report carried no theme line at all:\n$out");

like( $out, qr/theme\.css sit directly in/,
    'and the misplaced stylesheet is named, so the fix is one sentence away' );

done_testing();
