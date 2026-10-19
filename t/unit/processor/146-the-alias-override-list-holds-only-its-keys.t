#!/usr/bin/perl
# SM1200: a `# ...` comment INSIDE the qw() list of %ALIAS_OVERRIDE_KEYS (three
# of them: SM179 in July, P16/SM1002 in October, SM1155 on 2026-10-17) made every
# word of the comment a member of the list, and perl said so on every compile:
# "Possible attempt to put comments in qw() list".
#
# The list is the whitelist of lazysite.conf keys an `alias.<host>.<key>` line may
# override per host. The conf reader takes `(\w+)` as the key and asks this hash,
# so a stray word that is all word characters ("language", "membership", "CSP",
# "domain", "may", "own", "app" ...) WAS an accepted key. This holds the list to
# its intended keys, and the processor to compiling without that warning.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(load_processor setup_minimal_site site_tempdir processor_path run_cmd);

my $docroot = site_tempdir();
setup_minimal_site($docroot);
load_processor($docroot);

my @intended = qw(
    site_name theme layout nav_file search_default content_root site_url
    lang lang_group
    csp_script_src csp_connect_src csp_img_src csp_frame_src
    app_name app_short_name app_scope app_start_url app_theme_colour
    app_background_colour app_icon_64 app_icon_192 app_icon_512 app_icon_maskable
    app_shell
);
my @have = sort keys %main::ALIAS_OVERRIDE_KEYS;
is_deeply( \@have, [ sort @intended ], 'the alias override list holds exactly its intended keys' )
    or diag( 'unexpected: ' . join( ' ', grep { my $k = $_; !grep { $_ eq $k } @intended } @have ) );

my $out = run_cmd( $^X, '-c', processor_path() );
unlike( $out, qr/Possible attempt to put comments in qw\(\) list/, 'the processor compiles without the qw() comment warning' );
unlike( $out, qr/Possible attempt to separate words with commas/, '...or the comma one' );
like( $out, qr/syntax OK/, '...and compiles' );

done_testing;
