#!/usr/bin/perl
# SM1459 R4: AN EXTENSIONS INDEX BUILT BY AN OLDER ENGINE IS NAMED BY `lazysite check`.
#
# A site's lazysite/extensions.index.json is written by the engine that was running when
# an extension was enabled, saved or upgraded. When the engine tree then moves under the
# site (a dev tree, a shared engine), the index still holds the older hooks, and a
# provider the new engine declares is not in it: the sign-in is refused. The request path
# cannot rebuild (it must not run --describe, and the web user need not own the file), so
# the check says it: the extensions whose indexed hooks differ from what this engine
# declares, and the command that rebuilds.
#
#   * an index built by this engine: no warning, the OK line stands;
#   * the same index with an extension's hooks as an older engine wrote them (here the
#     identity_provider declaration missing): a WARN naming the extension and the command;
#   * rebuilt with that command (rebuild_hook_index_main): no warning again.
#
# Sabotage: take _hook_index_stale out of report_hook_index - the second case fails.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use JSON::PP   qw(decode_json encode_json);
use FindBin;
use lib "$FindBin::Bin/../lib";
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);
use OdooTest   ();

my $root   = repo_root();
my $script = "$root/tools/lazysite-check.pl";

my $doc = site_tempdir();
make_path("$doc/lazysite/$_") for qw(auth cache logs manager);
open my $cf, '>', "$doc/lazysite/lazysite.conf" or die $!;
print {$cf} "site_name: T\n";
close $cf;
OdooTest::enable_odoo($doc);    # through the manager: the index is built by this engine

my $index = "$doc/lazysite/extensions.index.json";
ok( -e $index, 'the site has an index' );

sub check { return scalar qx($^X \Q$script\E --docroot \Q$doc\E 2>&1) }
sub slurp { my ($p) = @_; open my $fh, '<:raw', $p or die "$p: $!"; local $/; my $t = <$fh>; close $fh; return $t }
sub spit  { my ( $p, $t ) = @_; open my $fh, '>:raw', $p or die "$p: $!"; print {$fh} $t; close $fh; return }

my $out = check();
unlike( $out, qr/built by a different engine/, 'an index this engine built: not named' ) or diag $out;
like( $out, qr/the extension index is built/, '...and the OK line stands' );

# the index as an older engine wrote it: no identity_provider declaration
my $idx = decode_json( slurp($index) );
ok( $idx->{extensions}{odoo}{hooks}{identity_provider}, 'the odoo extension declares an identity provider' );
delete $idx->{extensions}{odoo}{hooks}{identity_provider};
spit( $index, encode_json($idx) );

$out = check();
like( $out, qr/\[ warn \] [^\n]*built by a different engine than this one[^\n]*hooks for odoo differ/, 'WARN naming the extension' )
    or diag $out;
like( $out, qr/rebuild_hook_index_main\(\@ARGV\)' \Q$doc\E/, '...and the command, for this docroot' );
unlike( $out, qr/the extension index is built/, '...and no OK line' );

# the command, run
require Lazysite::Manager::Extensions;
is( Lazysite::Manager::Extensions::rebuild_hook_index_main($doc), 0, 'the rebuild command succeeds' );
$out = check();
unlike( $out, qr/built by a different engine/, 'after it: not named again' ) or diag $out;
like( $out, qr/the extension index is built/, '...and the OK line is back' );

done_testing;
