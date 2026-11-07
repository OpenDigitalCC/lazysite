#!/usr/bin/perl
# SM1369 X1 (ruling 55): THE UPGRADE REBUILDS THE EXTENSION HOOK INDEX.
#
# A release's descriptors may declare hooks, or stop declaring them, so every
# upgrade rebuilds lazysite/extensions.index.json from the enabled extensions,
# with the installed code, as the site user (install.pl, run_hook_index_build).
# A site provisioned and then reinstalled in place by the real install.pl (a
# reinstall is the way to run the upgrade's step at the version under test; a
# fresh install runs it too since ruling 166, t/tools/338):
#
#   - with no hooks declared, has no index after the upgrade and the summary
#     says nothing about hooks;
#   - with an enabled extension that declares a hook this engine does not build
#     yet, the summary names it as refused, with its slice, and an index left
#     from before - which named an extension that is not there - is removed,
#     because nothing is indexed now.
#
# Sabotage: with the run_hook_index_build call taken out of cmd_install, the old
# index stays and nothing is named - this fails.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper    qw(repo_manifest_guard);
use PreRenameSite qw(new_site install slurp spit);

my $MF_GUARD = repo_manifest_guard();

my ( $docroot, $cgibin, $root ) = new_site();
my ( $rc, $out ) = install( $docroot, $cgibin, 'provision' );
is( $rc, 0, 'the site is provisioned' ) or diag $out;
my $index = "$docroot/lazysite/extensions.index.json";

( $rc, $out ) = install( $docroot, $cgibin, 'reinstall' );
is( $rc, 0, 'a site with no hooks is reinstalled' ) or diag $out;
# SM1369 X2: a site with no hooks still has an index when an installed
# extension DECLARES (Odoo ships with the engine): the `declared` view, and
# nothing in `extensions`, so no hook runs.
ok( -e $index, 'and has an index for what is installed' );
my $built = decode_json( slurp($index) );
is_deeply( $built->{extensions}, {}, 'with no hooks indexed' );
ok( $built->{declared}{odoo}, 'and the installed extension\'s declaration' );
unlike( $out, qr/hooks (?:indexed|refused)/, 'and the summary says nothing about hooks' );
like( $out, qr/declarations indexed: odoo/, 'but names the declaration' );

# An extension of the site's own that declares a hook X1 does not build.
make_path("$root/extensions/hookdemo/lib/Hookdemo");
spit( "$root/extensions/hookdemo/lib/Hookdemo/Checks.pm", "package Hookdemo::Checks;\nsub run { return [] }\n1;\n" );
spit( "$root/extensions/hookdemo.pl", "#!/usr/bin/perl\n"
        . "print '{\"id\":\"hookdemo\",\"name\":\"Hook demo\",\"owns\":{\"hooks\":{\"checks\":[\"Hookdemo::Checks::run\"]}}}'\n"
        . "    if \@ARGV && \$ARGV[0] eq '--describe';\n" );
my $conf = slurp("$docroot/lazysite/lazysite.conf");
$conf =~ s/^extensions:\s*\n/extensions:\n  - extensions\/hookdemo.pl\n/m or $conf .= "extensions:\n  - extensions/hookdemo.pl\n";
spit( "$docroot/lazysite/lazysite.conf", $conf );
spit( $index, '{"format":1,"extensions":{"ghost":{"key":"extensions/ghost.pl","functions":[]}}}' );

( $rc, $out ) = install( $docroot, $cgibin, 'reinstall' );
is( $rc, 0, 'the reinstall succeeds' ) or diag $out;
like( $out, qr/hooks refused: hookdemo \(hook 'checks' \(H-6\) is not built in this engine yet - it lands in slice X6/,
    'the summary names the hook it refused, and its slice' );
$built = decode_json( slurp($index) );
ok( !exists $built->{extensions}{ghost}, 'the old index is gone: the ghost is not indexed' );
is_deeply( $built->{extensions}, {}, 'and nothing else runs' );
ok( !exists $built->{declared}{hookdemo}, 'the refused extension declares nothing either' );

done_testing();
