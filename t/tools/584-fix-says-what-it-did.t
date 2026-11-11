#!/usr/bin/perl
# n814 (SM1437), test plan 0.16.10 O-6: `check --fix` SAYS WHAT IT DID.
#
# With nothing to fix, `check --fix` printed the same report as `check` with only
# the "(re-run with --fix ...)" hint gone, and an operator asked whether --fix is a
# real option. It prints one line when it changed nothing; the line naming the
# count when it applied some is the existing one.
use strict;
use warnings;
use Test::More;
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir run_child);

my $root   = repo_root();
my $script = "$root/tools/lazysite-check.pl";
my $GROUP  = getgrgid( $) + 0 ) // ( $) + 0 );

sub run { run_child( [ $^X, $script, '--docroot', $_[0], @_[ 1 .. $#_ ] ], stderr => 'merge' )->{out} // '' }

my $doc = site_tempdir();
make_path( dirname($doc) . '/cgi-bin' );
my $r = run_child(
    [   $^X, "$root/install.pl", '--mode', 'provision', '--docroot', $doc,
        '--cgibin', dirname($doc) . '/cgi-bin', '--serving-group', $GROUP, '--no-starter'
    ],
    stderr => 'merge',
);
is( $r->{status} >> 8, 0, 'provisioned' ) or diag $r->{out};

# The first --fix may have something to change (the install leaves a mode for it);
# the second is the case under test: nothing left.
run( $doc, '--fix' );
my $out = run( $doc, '--fix' );
like( $out, qr/^--fix: nothing to change$/m, 'with nothing to fix, --fix says so' ) or diag $out;
unlike( $out, qr/--fix applied/, 'and does not claim to have applied anything' );

unlike( run($doc), qr/--fix: nothing to change/, 'without --fix the line is not printed' );

done_testing;
