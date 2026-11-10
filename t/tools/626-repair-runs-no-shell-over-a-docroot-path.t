#!/usr/bin/perl
# n808: THE REPAIR RUNS THE DOCTOR WITHOUT A SHELL.
#
# `lazysite repair` ran the check (before, with --fix, and after) as one string through
# the shell with the docroot and cgi-bin unquoted, so a path holding a shell
# metacharacter was read as a command. The paths come from the root-written registry or
# Hestia's list, but a name is not a command: the three runs are now list-form pipes.
# A docroot whose directory name holds `;touch MARK` and `$(touch MARK2)` is repaired
# and no MARK file appears.
use strict;
use warnings;
use Test::More;
use Cwd qw(getcwd);
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root run_child);

my $root = repo_root();
my $cli  = "$root/tools/lazysite-cli.pl";

sub spit { my ( $p, $t ) = @_; open my $f, '>', $p or die "$p: $!"; print {$f} $t; close $f }

my $p = tempdir( CLEANUP => 1 );
make_path("$p/tools");
spit( "$p/install.pl", "1;\n" );
spit( "$p/VERSION",    "9.9.9\n" );
open my $in, '<', $cli or die $!;
spit( "$p/tools/lazysite-cli.pl", do { local $/; <$in> } );
close $in;
spit( "$p/tools/lazysite-check.pl", <<'PL' );
print "(--fix applied 1 change(s); this report reflects the post-fix state)\n" if grep { $_ eq '--fix' } @ARGV;
print "[ warn ] a decision for the sysop\n";
print "0 ok, 1 warning(s), 0 failure(s)\n";
PL

my $work = tempdir( CLEANUP => 1 );
my $reg  = tempdir( CLEANUP => 1 );
my $base = tempdir( CLEANUP => 1 );
my $d    = "$base/a;touch MARK;b \$(touch MARK2)";
make_path("$d/lazysite/auth");
spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
spit( "$reg/t.example",            "docroot=$d\n" );

my $here = getcwd();
chdir $work or die $!;
local $ENV{LAZYSITE_REGISTRY_DIR} = $reg;
my $r = run_child( [ $^X, "$p/tools/lazysite-cli.pl", 'repair', '--domain', 't.example' ], stderr => 'merge' );
chdir $here;

like( $r->{out}, qr/^\(--fix applied 1 change\(s\)/m, 'the repair ran over the odd path and its report is shown' ) or diag $r->{out};
like( $r->{out}, qr/1 awaiting your decision \(1 change applied\)/, 'and counted' ) or diag $r->{out};
ok( !-e "$work/MARK",  'no MARK file: `;touch MARK` was not run' );
ok( !-e "$work/MARK2", 'no MARK2 file: `$(touch MARK2)` was not run' );

done_testing();
