#!/usr/bin/perl
# n814 (SM1437), test plan 0.16.10 O-5: REPAIR'S WORDING WHEN IT REPAIRED NOTHING.
#
# The summary read "-> repaired. Left for you to decide, not a fault:" while the
# tally said "0 repaired". When no change was applied the line now says "-> nothing
# to repair." and the tally is as it was; with changes applied it still says
# "repaired".
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir run_child);

my $cli = repo_root() . '/tools/lazysite-cli.pl';
sub spit { my ( $p, $t ) = @_; open my $f, '>', $p or die "$p: $!"; print {$f} $t; close $f }

# The doctor is a stand-in: one warning, and N changes applied under --fix.
sub payload {
    my ($n) = @_;
    my $p = tempdir( CLEANUP => 1 );
    make_path("$p/tools");
    spit( "$p/install.pl", "1;\n" );
    spit( "$p/VERSION",    "9.9.9\n" );
    open my $in, '<', $cli or die $!;
    spit( "$p/tools/lazysite-cli.pl", do { local $/; <$in> } );
    spit( "$p/tools/lazysite-check.pl", <<"PL" );
print "(--fix applied $n change(s); this report reflects the post-fix state)\\n" if grep { \$_ eq '--fix' } \@ARGV and $n;
print "[ warn ] a decision for the sysop\\n";
print "0 ok, 1 warning(s), 0 failure(s)\\n";
PL
    return $p;
}

sub repair {
    my ($p) = @_;
    my $reg = tempdir( CLEANUP => 1 );
    local $ENV{LAZYSITE_REGISTRY_DIR} = $reg;
    my $d = site_tempdir();
    make_path("$d/lazysite/auth");
    spit( "$d/lazysite/lazysite.conf", "site_name: T\n" );
    spit( "$reg/t.example",            "docroot=$d\n" );
    return run_child( [ $^X, "$p/tools/lazysite-cli.pl", 'repair', '--domain', 't.example' ], stderr => 'merge' )->{out};
}

my $none = repair( payload(0) );
like( $none, qr/^  -> nothing to repair\. Left for you to decide, not a fault:$/m, 'nothing applied: says nothing to repair' )
    or diag $none;
unlike( $none, qr/-> repaired\./, 'and does not say repaired' );
like( $none, qr/^0 clean, 0 repaired, 1 awaiting your decision, 0 need a human\.$/m, 'the tally is as it was' );

my $some = repair( payload(2) );
like( $some, qr/^  -> repaired\. Left for you to decide, not a fault:$/m, 'changes applied: still says repaired' ) or diag $some;

done_testing;
