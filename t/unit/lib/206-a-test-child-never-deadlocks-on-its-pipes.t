#!/usr/bin/perl
# SM1245: a child a test runs can neither deadlock it nor hang it.
#
# t/unit/dav/33 sat 95 minutes in the 2026-10-20 14:30 suite run on a
# lazysite-dav.pl child. run_dav read the child's stdout to EOF and then its
# stderr, with no limit: a child that writes more than a pipe holds (64 KiB) to
# stderr blocks there, and the test blocks on stdout, for ever.
#
# The noisy child below writes 200 KB to stderr BEFORE its first byte of stdout,
# so the old read order MUST deadlock; the sleeping one never exits, so a helper
# without a limit MUST hang. Both are driven through run_dav itself as well as
# through run_child, because run_dav is where it happened.
use strict;
use warnings;
use Test::More;
use Time::HiRes ();
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(run_child run_dav run_cmd setup_dav_site site_tempdir repo_root child_timeout);

my $root = repo_root();
my $d    = site_tempdir();

sub write_file {
    my ( $path, $text ) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print {$fh} $text;
    close $fh;
    return $path;
}

# Loaded with -M into the real lazysite-dav.pl: the noise comes first.
write_file( "$d/NoisyStart.pm", <<'PERL' );
package NoisyStart;
syswrite STDERR, 'e' x 200_000 if $ENV{LAZYSITE_TEST_NOISE};
sleep 600 if $ENV{LAZYSITE_TEST_NEVER_ENDS};
1;
PERL

# --- stderr past a pipe's worth, before any stdout --------------------------
{
    my $r = run_child( [ $^X, '-e',
        'syswrite STDERR, "e" x 200_000; syswrite STDOUT, "o" x 200_000; exit 3' ] );
    is( length $r->{err}, 200_000, 'all of a 200 KB stderr written before stdout is read' );
    is( length $r->{out}, 200_000, 'and all of the stdout after it' );
    is( $r->{status} >> 8, 3, 'with the exit status' );
    is( $? >> 8, 3, 'which is in $? as well' );
}

{
    my $s = setup_dav_site();
    local $ENV{PERL5OPT}            = "-I$d -MNoisyStart";
    local $ENV{LAZYSITE_TEST_NOISE} = 1;
    my $t0 = Time::HiRes::time();
    my $r  = run_dav( $s->{docroot}, 'PROPFIND', '/content/',
        HTTP_AUTHORIZATION => $s->{auth}, HTTP_DEPTH => 0 );
    is( length $r->{stderr}, 200_000, 'run_dav collects a lazysite-dav.pl stderr larger than a pipe' );
    is( $r->{code}, 207, 'and still answers with the response' );
    cmp_ok( Time::HiRes::time() - $t0, '<', 60, 'without waiting on the pipe' );
}

# --- a body and an answer both larger than a pipe ---------------------------
# Writing all of stdin before reading stdout deadlocks once the child, echoing,
# fills stdout while the test is still writing.
{
    my $body = join '', map { chr( 65 + $_ % 26 ) } 1 .. 1_000_000;
    my $r = run_child( [ $^X, '-e', 'binmode STDIN; binmode STDOUT; print while sysread STDIN, $_, 4096' ],
        stdin => $body );
    is( length $r->{out}, 1_000_000, 'a 1 MB body echoed back arrives whole' );
    ok( $r->{out} eq $body, 'and unchanged' );
}

# --- the stderr modes ---------------------------------------------------------
{
    my @kid = ( $^X, '-e', '$|=1; print STDOUT "o\n"; print STDERR "e\n"' );
    my $m = run_child( \@kid, stderr => 'merge' );
    like( $m->{out}, qr/^o\ne\n\z/, "'merge' puts stderr in out" );
    is( $m->{err}, '', 'and leaves err empty' );
    is( run_child( \@kid, stderr => 'discard' )->{out}, "o\n", "'discard' drops it" );
    like( run_cmd( $^X, '-e', 'print STDERR "said\n"; exit 4' ), qr/said/, 'run_cmd still returns stderr too' );
    is( $? >> 8, 4, 'with the exit status in $?' );
}

# --- a child that never exits fails the test, by name, in bounded time ------
{
    my $t0 = Time::HiRes::time();
    my $ok = eval { run_child( [ $^X, '-e', 'sleep 600' ], timeout => 2, label => 'sleeper' ); 1 };
    my $e  = $@;
    my $took = Time::HiRes::time() - $t0;
    ok( !$ok, 'a child still running at the timeout is an error, not a wait' );
    like( $e, qr/\Q$0\E/, 'which names the test' );
    like( $e, qr/child sleeper \(pid \d+\)/, 'and the child' );
    like( $e, qr/after 2s/, 'and how long it waited' );
    cmp_ok( $took, '<', 15, 'and arrives in bounded time' );
}

{
    my $s = setup_dav_site();
    local $ENV{PERL5OPT}                    = "-I$d -MNoisyStart";
    local $ENV{LAZYSITE_TEST_NEVER_ENDS}    = 1;
    local $ENV{LAZYSITE_TEST_CHILD_TIMEOUT} = 2;
    my $t0 = Time::HiRes::time();
    my $ok = eval { run_dav( $s->{docroot}, 'GET', '/content/', HTTP_AUTHORIZATION => $s->{auth} ); 1 };
    my $e  = $@;
    ok( !$ok, 'run_dav gives up on a lazysite-dav.pl that never ends' );
    like( $e, qr/child lazysite-dav\.pl \(pid \d+\) was still running after 2s/, 'naming it' );
    cmp_ok( Time::HiRes::time() - $t0, '<', 15, 'in bounded time' );
}

# The whole test file fails - not only the call - and says which file it was.
{
    my $t = write_file( "$d/hangs.t", <<"PERL" );
use strict; use warnings; use Test::More;
use lib '$root/t/lib';
use TestHelper qw(run_child);
ok( 1, 'before the child' );
run_child( [ \$^X, '-e', 'sleep 600' ], timeout => 1 );
ok( 1, 'never reached' );
done_testing;
PERL
    my $out = run_cmd( $^X, $t );
    isnt( $? >> 8, 0, 'a test file whose child hangs exits non-zero' );
    like( $out, qr/\Q$t\E: child perl -e \(pid \d+\) was still running after 1s/, 'and its output names it' );
    unlike( $out, qr/never reached/, 'it stopped at the child' );
}

# --- the limit ----------------------------------------------------------------
{
    local $ENV{LAZYSITE_TEST_CHILD_TIMEOUT};
    local $ENV{PERL5OPT}              = '';
    local $ENV{HARNESS_PERL_SWITCHES} = '';
    SKIP: {
        skip 'running under Devel::Cover', 1 if $INC{'Devel/Cover.pm'};
        is( child_timeout(), 300, 'a child gets five minutes' );
    }
    local $ENV{HARNESS_PERL_SWITCHES} = '-MDevel::Cover';
    is( child_timeout(), 1200, 'twenty under Devel::Cover' );
    local $ENV{LAZYSITE_TEST_CHILD_TIMEOUT} = 7;
    is( child_timeout(), 7, 'and LAZYSITE_TEST_CHILD_TIMEOUT overrides both' );
}

done_testing;
