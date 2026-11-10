#!/usr/bin/perl
# n800: THE REPAIR'S TALLY SAYS WHEN IT APPLIED CHANGES TO A SITE IT LEFT AWAITING.
#
# After "--fix applied 2 change(s)" with only a warning left, the fleet line read
# "0 clean, 0 repaired, 1 awaiting your decision" and a reader took the repair
# for a no-op. By design (SM626) a site with a warning left counts as awaiting a
# decision: a warning is the doctor's own contract that repair never settles it.
# That stays; the line now says the changes were applied. A site the repair
# changed nothing on keeps the plain line.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root site_tempdir run_child);

my $root = repo_root();
my $cli  = "$root/tools/lazysite-cli.pl";

sub spit { my ( $p, $t ) = @_; open my $f, '>', $p or die "$p: $!"; print {$f} $t; close $f }

# A payload whose doctor is a stand-in: it reports one warning, and says it
# applied N changes when run with --fix (N from the file "applied" beside it).
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
    my $r = run_child( [ $^X, "$p/tools/lazysite-cli.pl", 'repair', '--domain', 't.example' ], stderr => 'merge' );
    return ( $r->{status} >> 8, $r->{out} );
}

subtest 'changes applied, a warning left: awaiting, and the line says changes were applied' => sub {
    my ( $rc, $out ) = repair( payload(2) );
    like( $out, qr/^\(--fix applied 2 change\(s\)/m, 'the repair\'s own report is still shown' ) or diag $out;
    like( $out, qr/^0 clean, 0 repaired, 1 awaiting your decision \(2 changes applied\), 0 need a human\.$/m,
        'awaiting your decision (2 changes applied)' )
        or diag $out;
    is( $rc, 0, 'and a decision left is not a failure' );
};

subtest 'one change is singular' => sub {
    my ( undef, $out ) = repair( payload(1) );
    like( $out, qr/1 awaiting your decision \(1 change applied\), 0 need a human\.$/m, 'one change applied' )
        or diag $out;
};

subtest 'nothing applied: the plain line' => sub {
    my ( undef, $out ) = repair( payload(0) );
    like( $out, qr/^0 clean, 0 repaired, 1 awaiting your decision, 0 need a human\.$/m, 'no suffix' )
        or diag $out;
};

done_testing();
