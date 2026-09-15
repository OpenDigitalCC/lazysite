#!/usr/bin/perl
# SM886: a cached render also depends on the ENGINE that produced it.
#
# A render is served while it post-dates its source, the conf, the nav and its
# section indexes. An upgrade changes none of those - so a page nobody edits
# keeps its pre-upgrade render for ever, including any head-contract or
# security header the new build introduced.
#
# THE FIELD MEASURED IT TWICE. SM413 in August (a homepage serving a 0.10.13
# render through four deployments) and again on 2026-09-14, when ten sites
# provably running 0.14.1 - a fresh, uncacheable 404 reported 0.14.1 on each -
# still served home pages rendered by 0.14.0 or 0.13.15. Five were two releases
# behind on the page a visitor lands on.
#
# SM413's fix drops rendered .html on upgrade, but it walks `lazysite/cache/`
# only. That holds the ALIAS hosts' renders; the primary host's render is the
# sibling `<content-root>/<base>.html` beside the .md, which no upgrade has
# ever touched. So the fix was real and covered the slot the homepage is not
# in.
#
# This test drives the shape the field reported: render, then upgrade the
# engine and NOTHING else, then ask again.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor site_tempdir);

# SM754: via the helper, so the docroot sits a level down and every sibling the
# engine writes lands inside what CLEANUP removes.
my $d = site_tempdir();
make_path("$d/lazysite");

open my $c, '>', "$d/lazysite/lazysite.conf" or die $!;
print $c "site_name: T\nlang: en\n";
close $c;

open my $i, '>', "$d/index.md" or die $!;
print $i "---\ntitle: Home\n---\n\nhi\n";
close $i;

# The engine version the render pipeline reports comes from the install state,
# which is what the installer rewrites on every upgrade - not from the repo
# VERSION file. So this is the fact an upgrade actually moves.
sub set_installed_version {
    my ($v) = @_;
    open my $s, '>', "$d/lazysite/.install-state.json" or die $!;
    print {$s} qq({"version":"$v"}\n);
    close $s;
    return;
}

set_installed_version('0.14.0');

my $out = run_processor( $d, '/' );
like( $out, qr/generator" content="lazysite 0\.14\.0/,
    'the first render reports the engine that made it' );
ok( -f "$d/index.html", 'and it cached as a sibling beside the .md' );

# THE UPGRADE. The engine is now a different version and nothing else has
# changed: the source, the conf and the nav are all untouched and OLDER than
# the cached render, exactly as they are on a site nobody has edited.
my $html_mtime = ( stat "$d/index.html" )[9];
set_installed_version('0.14.1');
utime $html_mtime + 5, $html_mtime + 5, "$d/lazysite/.install-state.json";
utime $html_mtime - 5, $html_mtime - 5, "$d/index.md";
utime $html_mtime - 5, $html_mtime - 5, "$d/lazysite/lazysite.conf";

$out = run_processor( $d, '/' );

like( $out, qr/generator" content="lazysite 0\.14\.1/,
    'after an upgrade the visitor gets a render from the NEW engine' )
    or diag( 'served a render produced by an engine that is no longer '
        . 'installed - this is the defect the field measured on ten sites' );

unlike( $out, qr/generator" content="lazysite 0\.14\.0/,
    'and no trace of the old build is served' );

done_testing;
