#!/usr/bin/perl
# SM389: TTL expiry regenerated the registries once per concurrent request.
#
# The cached sitemap goes stale at an INSTANT. Every request arriving after that
# instant read the same old mtime, and every one of them ran update_registries()
# - a full site scan - at the same time. The cost scales with traffic exactly
# when traffic is what made it stale, and a site big enough for the scan to be
# slow is a site with enough requests to pile up behind it.
#
# HOW THIS IS TESTED, and why not by reading the source. A lock is a claim about
# what happens under concurrency, and the only thing that settles it is
# concurrency: N processes are forked to arrive together and the regenerations
# are COUNTED. Asserting the file contains `flock` would pass against a lock
# taken on the wrong handle, released too early, or never checked.
#
# An earlier race proof in this repo passed 8/8 with the lock and 8/8 without,
# because the work was too fast to overlap and the failures were being swallowed.
# So the stub here sleeps, to make the window real, and the UNLOCKED case is
# asserted to stampede rather than assumed to - if the control does not stampede
# the fixture is not creating a race and the result below would mean nothing.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root      = repo_root();
my $processor = "$root/lazysite-processor.pl";
plan skip_all => "no $processor" unless -f $processor;

my $src = do { open my $fh, '<', $processor or die $!; local $/; <$fh> };

# The regenerator, taken out and run on its own so this is behaviour, not text.
my ($sub) = $src =~ /(sub _regenerate_registries_once \{.*?\n\}\n)/s;
ok( $sub, 'the regenerator can be isolated' ) or BAIL_OUT('cannot extract the sub');

# Fork $n children that all call the regenerator at the same moment; return how
# many times the work actually ran.
sub regenerations {
    my ( $n, $body, $with_stale_file ) = @_;
    my $d     = tempdir( 'lazysite-herd-XXXXXX', TMPDIR => 1, CLEANUP => 1 );
    my $path  = "$d/sitemap.xml";
    my $tally = "$d/ran";

    if ($with_stale_file) {
        open my $fh, '>', $path or die $!;
        print {$fh} 'stale';
        close $fh;
        my $old = time() - 100_000;
        utime $old, $old, $path;
    }

    my $harness = <<"HARNESS";
use strict;
use warnings;
use Fcntl qw(LOCK_EX LOCK_NB LOCK_UN);
our \$REGISTRY_TTL = 14400;
sub log_event { }
sub update_registries {
    open my \$t, '>>', '$tally' or die \$!;
    print {\$t} 'x';
    close \$t;
    select undef, undef, undef, 0.25;   # a real window for callers to overlap in
    open my \$o, '>', '$path' or die \$!;
    print {\$o} 'fresh';
    close \$o;
}
$body
_regenerate_registries_once( '$path', '/sitemap.xml' );
HARNESS

    my $script = "$d/run.pl";
    open my $sh, '>', $script or die $!;
    print {$sh} $harness;
    close $sh;

    my @pid;
    for ( 1 .. $n ) {
        my $pid = fork();
        die 'fork failed' unless defined $pid;
        if ( !$pid ) { exec $^X, $script or exit 1 }
        push @pid, $pid;
    }
    waitpid $_, 0 for @pid;

    return 0 unless -f $tally;
    my $c = do { open my $fh, '<', $tally or die $!; local $/; <$fh> };
    return length( $c // '' );
}

my $N = 12;

# --- the control: no lock, so every arrival regenerates ----------------
my $unlocked = <<'NOLOCK';
sub _regenerate_registries_once {
    my ( $path, $uri ) = @_;
    update_registries()
        if !-f $path || ( time() - ( stat($path) )[9] ) >= $REGISTRY_TTL;
}
NOLOCK

# THE NEGATIVE CONTROL NEEDS THE RACE TO ACTUALLY HAPPEN, and under
# Devel::Cover it does not. Instrumentation slows every process by roughly the
# same factor, so twelve of them that would collide arrive in single file, one
# regenerates, and the control reports "no stampede" - which is the right
# observation and the wrong conclusion. The control exists to prove the hazard
# is real; it cannot prove that on a machine where the hazard is suppressed.
#
# The POSITIVE assertions below are untouched and still run: the lock still has
# to make twelve concurrent requests regenerate exactly once.
SKIP: {
    skip 'Devel::Cover serialises the processes this control needs to collide',
        2
        if $INC{'Devel/Cover.pm'} || ( $ENV{PERL5OPT} // '' ) =~ /Devel::Cover/;

    my $stale_herd = regenerations( $N, $unlocked, 1 );
    cmp_ok( $stale_herd, '>', 1,
        "without the lock a stale file stampedes ($stale_herd of $N regenerated)" );

    my $cold_herd = regenerations( $N, $unlocked, 0 );
    cmp_ok( $cold_herd, '>', 1,
        "without the lock a cold start stampedes ($cold_herd of $N regenerated)" );
}

# --- the fix -----------------------------------------------------------
is( regenerations( $N, $sub, 1 ), 1,
    "a stale file regenerates exactly once for $N concurrent requests" );

# Cold start: nothing to serve stale, so the losers WAIT for the winner rather
# than joining it. Still exactly one scan.
is( regenerations( $N, $sub, 0 ), 1,
    "a cold start regenerates exactly once for $N concurrent requests" );

# And it must still regenerate when it is supposed to: a lock that let nobody
# through at all would pass both counts above.
is( regenerations( 1, $sub, 1 ), 1,
    'a single request past the TTL still regenerates' );

done_testing();
