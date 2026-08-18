#!/usr/bin/perl
# SM302: a review finding carries the command that checks it.
#
# Every eight-dimension review opens by verifying the previous one's findings
# rather than assuming - correct, and entirely manual. Across two reviews that
# was roughly thirty one-line greps, run interactively, written down nowhere. A
# finding whose check is reinvented can be re-checked DIFFERENTLY, or silently
# not at all.
#
# WHAT THIS TEST IS ACTUALLY FOR is the three-state result. "The check could not
# run" must never be counted as either verdict - which is the failure this whole
# release line catalogues, and which a tool that reports fixed/open only would
# reproduce on its first missing command.
use strict;
use warnings;
use Test::More;
use JSON::PP   qw(encode_json);
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $TOOL = "$root/tools/lazysite-review-verify.pl";
ok( -x $TOOL, 'the verifier is present and executable' );

sub review {
    my (@findings) = @_;
    my $d = tempdir( CLEANUP => 1 );
    open my $fh, '>', "$d/findings.json" or die $!;
    print {$fh} encode_json( { review => 'test', findings => \@findings } );
    close $fh;
    return $d;
}

sub run {
    my ($d) = @_;
    my $cmd = join ' ', map { quotemeta } $^X, $TOOL, $d;
    my $out = `$cmd 2>&1`;
    return ( $? >> 8, $out );
}

subtest 'a finding whose check passes is FIXED' => sub {
    my ( $rc, $out ) = run( review( { id => 'A1', title => 'x', verify => 'true' } ) );
    like( $out, qr/FIXED \(1\)/, 'reported fixed' );
    is( $rc, 0, 'and the run succeeds' );
};

subtest 'a finding whose check fails is STILL OPEN' => sub {
    my ( $rc, $out ) = run( review( { id => 'A2', title => 'x', verify => 'false' } ) );
    like( $out, qr/STILL OPEN \(1\)/, 'reported still open' );
    is( $rc, 1, 'and the run reports it' );
};

subtest 'a check that CANNOT RUN is neither, and fails the run' => sub {
    # THE WHOLE POINT. A missing command exits 127, which a naive tool reads as
    # "non-zero, therefore the finding is still open" - a wrong verdict
    # delivered with confidence. Worse would be a tool that read it as fixed.
    my ( $rc, $out )
        = run( review( { id => 'A3', title => 'x', verify => 'definitely-not-a-command-zz' } ) );
    like( $out, qr/COULD NOT BE CHECKED \(1\)/, 'reported as unrunnable' )
        or diag( 'A check that did not happen must not be counted as a verdict '
            . 'in either direction.' );
    unlike( $out, qr/STILL OPEN \(1\)/, 'not counted as still-open' );
    unlike( $out, qr/FIXED \(1\)/,      'and certainly not as fixed' );
    is( $rc, 2, 'and the run FAILS - a review whose checks cannot run has '
            . 'told the next reviewer nothing' );
};

subtest 'a finding with no check is reported, not omitted' => sub {
    # "We did not automate this one" is a fact the next reviewer needs. An
    # absence looks identical to a finding that was quietly dropped.
    my ( $rc, $out ) = run( review( { id => 'A4', title => 'judgement call' } ) );
    like( $out, qr/NOT MECHANICAL/, 'listed as manual' );
    like( $out, qr/A4/,             'by id' );
    is( $rc, 0, 'and does not fail the run' );
};

subtest 'a review with no findings file says so rather than passing' => sub {
    my $empty = tempdir( CLEANUP => 1 );
    my ( $rc, $out ) = run($empty);
    isnt( $rc, 0, 'refused' );
    like( $out, qr/cannot be re-checked/,
        'and names the state SM302 was filed about' );
};

subtest "the project's own review carries a findings file that runs" => sub {
    my $dir = "$root/docs/review/2026-08-14-eight-dimension-0.10.9";
    ok( -f "$dir/findings.json", 'the 0.10.9 review has one' ) or return;
    my ( $rc, $out ) = run($dir);
    unlike( $out, qr/COULD NOT BE CHECKED \([1-9]/,
        'and every mechanical check in it can actually run' )
        or diag("$out\nA seeded check that cannot run is worse than no seed.");
};

done_testing();
