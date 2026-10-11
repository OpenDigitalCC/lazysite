#!/usr/bin/perl
# P10 (WORK-PLAN-0154): a dry-run plan prints no uninitialised-value warnings.
#
# Reported from `lazysite provision` on a fresh folder: "Use of uninitialized
# value in concatenation" three times at install.pl ~1223. The cause is not the
# missing registry the report suspected: print_plan prints each runtime path's
# `purpose`, and three entries in classification.json (stats/form-events, forms,
# git) carry `why` instead. print_plan now prints `purpose`, else `why`, else
# nothing in the brackets.
use strict;
use warnings;
use Test::More;
use File::Path     qw(make_path);
use File::Basename qw(dirname);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_manifest_guard site_tempdir);

my $ROOT    = "$FindBin::Bin/../..";
my $INSTALL = "$ROOT/install.pl";
plan skip_all => 'install.pl not found' unless -f $INSTALL;

my $MF_GUARD = repo_manifest_guard();
my $GROUP    = getgrgid( $) + 0 ) // ( $) + 0 );

my $docroot = site_tempdir();
my $cgibin  = dirname($docroot) . '/cgi-bin';
make_path($cgibin);
my $out = `$^X \Q$INSTALL\E --mode provision --docroot \Q$docroot\E --cgibin \Q$cgibin\E --serving-group \Q$GROUP\E --dry-run 2>&1`;

like( $out, qr/--dry-run: no changes made/, 'the dry run completed' ) or diag($out);
unlike( $out, qr/uninitiali[sz]ed value/i, 'without an uninitialised-value warning' )
    or diag( join "\n", grep { /uninitiali/i } split /\n/, $out );
like( $out, qr{\Q/lazysite/forms\E\s+\(form config \+ submission store}, 'an entry with only `why` prints it' );
like( $out, qr{\Q/lazysite/auth\E\s+\(credentials,}, 'an entry with `purpose` prints that, as before' );

done_testing;
