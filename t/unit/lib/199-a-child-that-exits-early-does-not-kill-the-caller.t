#!/usr/bin/perl
# SM959: a child that exits before reading does not kill the process writing to it.
#
# Driven through the real Handlers::_run_smtp_script - the path that delivers a
# form's mail and acknowledgements - with a stand-in script that exits at once and
# a payload larger than a pipe buffer, so the write MUST meet a closed pipe. Run
# in a subprocess, because SIGPIPE's default is to kill: what is measured is how
# the caller ended, not what it returned.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root site_tempdir);

my $root = repo_root();
my $d    = site_tempdir();
my $quit = "$d/../quits-at-once.pl";
open my $q, '>', $quit or die $!;
print {$q} "exit 3;\n";
close $q;

my $prog = <<"PERL";
use lib '$root/lib';
use Lazysite::Handlers;
\$Lazysite::Handlers::DOCROOT = '$d';
my \$r = Lazysite::Handlers::_run_smtp_script( '$quit', { blob => 'x' x 300_000 } );
print ref \$r eq 'HASH' && !\$r->{ok} ? "returned not-ok\\n" : "returned something else\\n";
PERL
# A list-form pipe, not qx: through /bin/sh a signal death reads as exit 141,
# and the signal check below would never see it.
open my $ph, '-|', $^X, '-e', $prog or die "cannot run perl: $!";
my $out = do { local $/; <$ph> } // '';
close $ph;
my $status = $?;

is( $status & 127, 0, 'the caller was not killed by a signal' )
    or diag( 'signal ' . ( $status & 127 ) . ' - 13 is SIGPIPE: a child that exits early killed the caller' );
like( $out, qr/returned not-ok/, 'and it returned a failure the caller can report' ) or diag($out);

done_testing();
