#!/usr/bin/perl
# D035 content components, Phase 1: the layout TT engine resolves
# [% INCLUDE 'components/NAME.tt' %] against the active layout's own directory,
# and a `markdown` filter renders Markdown fields (inline single-paragraph
# values are unwrapped; usable inside a component too).
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(run_processor);

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/layouts/nova/components");

open my $lf, '>', "$docroot/lazysite/layouts/nova/layout.tt" or die $!;
print $lf <<'TT';
<!DOCTYPE html><html><head><title>[% page_title %]</title></head><body>
[% INCLUDE 'components/card.tt' heading = 'Hello' %]
<p class="inline">[% "loud and *clear*" | markdown %]</p>
[% INCLUDE 'components/lead.tt' text = 'via *component*' %]
<main>[% content %]</main>
</body></html>
TT
close $lf;

open my $cf, '>', "$docroot/lazysite/layouts/nova/components/card.tt" or die $!;
print $cf qq{<section class="card"><h2>[% heading %]</h2></section>\n};
close $cf;

open my $lcf, '>', "$docroot/lazysite/layouts/nova/components/lead.tt" or die $!;
print $lcf qq{<p class="lead">[% text | markdown %]</p>\n};
close $lcf;

open my $conf, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print $conf "site_name: Test\nlayout: nova\n";
close $conf;

open my $idx, '>', "$docroot/index.md" or die $!;
print $idx "---\ntitle: Home\n---\nBody copy.\n";
close $idx;
open my $nf, '>', "$docroot/404.md" or die $!;
print $nf "---\ntitle: NF\n---\nNot found.\n";
close $nf;

my $out = run_processor( $docroot, '/' );

like( $out, qr{<section class="card"><h2>Hello</h2></section>},
    'component INCLUDE resolves against the layout directory' );

like( $out, qr{loud and <em>clear</em>},
    'markdown filter renders inline (single paragraph unwrapped)' );
unlike( $out, qr{<p class="inline"><p>}, 'inline markdown not double-wrapped in <p>' );

like( $out, qr{<p class="lead">via <em>component</em></p>},
    'markdown filter is available inside a component' );

like( $out, qr{Body copy\.}, 'page content still renders' );

done_testing;
