#!/usr/bin/env perl
# SM1083: tools/overnight.sh does no work when main is the commit the last green
# night tested and the queue is empty (one log line). Coverage is on demand and
# never part of the night. Stub suite and compat tools.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Copy qw(copy);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_cmd);

my $root = repo_root();
my $d    = tempdir( CLEANUP => 1 );
sub git { my $o = run_cmd( 'git', '-C', $d, @_ ); $o =~ s/\s+$//; $o }
git( 'init',   '-q',         '-b', 'main' );
git( 'config', 'user.email', 't@example.invalid' );
git( 'config', 'user.name',  't' );
make_path("$d/tools");
copy( "$root/tools/overnight.sh", "$d/tools/overnight.sh" ) or die;
for my $s (qw(suite.sh ext-compat.sh)) {
    open my $f, '>', "$d/tools/$s" or die;
    print {$f} "#!/bin/sh\necho ran >> $d/ran-$s\nexit 0\n";
    close $f;
}
git( 'add', '-A' );
git( 'commit', '-q', '-m', 'x' );
my $sha = git( 'rev-parse', 'main' );
delete $ENV{LAZYSITE_HEAVY_HELD};
sub night { run_cmd( 'bash', "$d/tools/overnight.sh" ); $? >> 8 }
sub results { my ($r) = glob("$d/tmp/overnight/results-*.txt"); open my $f, '<', $r or return ''; local $/; <$f> }

is( night(), 0, 'a first night runs' );
ok( -e "$d/ran-suite.sh", 'it ran the nightly suite' );
unlink "$d/ran-suite.sh";
open my $f, '>', "$d/tmp/overnight/last-tested-sha" or die;
print {$f} "$sha\n";
close $f;
is( night(), 0, 'an unchanged night exits 0' );
ok( !-e "$d/ran-suite.sh", 'and ran nothing' );
like( results(), qr/main unchanged since the last green night/, 'saying so in one line' );
unlike( results(), qr/coverage/i, 'coverage is not part of the night' );
open $f, '>', "$d/tmp/overnight/queue.txt" or die;
print {$f} "$d $sha\n";
close $f;
open $f, '>', "$d/tmp/overnight/last-tested-sha" or die;
print {$f} "$sha\n";
close $f;
my $o = results();
night();
unlike( results() =~ s/.*main unchanged[^\n]*\n//sr, qr/^$/, 'a queued stack is never skipped (it reaches integration)' );
like( results(), qr/integration:/, 'integration was attempted' );
done_testing;
