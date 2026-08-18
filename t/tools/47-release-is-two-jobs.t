#!/usr/bin/perl
# SM303: build and publish share only a version number.
#
# WHAT THE ONE-COMMAND FORM COST, both ways round. The build host has no remote
# credentials by design, so `git fetch --tags origin` under `set -e` aborted
# before a single gate step ran - which asked the one person who COULD reach the
# remote to supervise a fifty-minute test run needing no credentials at all. The
# repair was --no-fetch, and the run then died at the LAST step on `git push`,
# killing the artefact copy and leaving a fully gated, built and tagged release
# reporting exit 128 with its 2.8MB tarball stranded in staging.
#
# One command doing two jobs, failing at either end for reasons belonging to the
# other. Naming the job removes the flag that had to remember which host it was
# on.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my $REL  = "$root/tools/release.sh";

sub run {
    my (@args) = @_;
    my $cmd    = join ' ', map { quotemeta } 'bash', $REL, @args;
    my $out    = `$cmd 2>&1`;
    return ( $? >> 8, $out );
}

subtest 'the old single-command form refuses and says what to type' => sub {
    # NOT a silent fallback to one of the two. Its failure modes are the reason
    # the split exists, so guessing which half was meant would preserve them.
    my ( $rc, $out ) = run('0.99.0');
    isnt( $rc, 0, 'refused' );
    like( $out, qr/say which job/,               'and says why' );
    like( $out, qr/release\.sh build\s+VERSION/, 'naming build' );
    like( $out, qr/release\.sh publish VERSION/, 'and publish' );
};

subtest 'build never reaches the remote' => sub {
    # The property, asserted against the source rather than by running a
    # fifty-minute gate: no fetch and no push outside the publish block.
    open my $fh, '<', $REL or die $!;
    my @lines = <$fh>;
    close $fh;

    my ($pub_start) = grep { $lines[$_] =~ /^if \[ "\$MODE" = publish \]/ } 0 .. $#lines;
    ok( defined $pub_start, 'the publish block is identifiable' ) or return;
    my ($pub_end) = grep { $_ > $pub_start && $lines[$_] =~ /^fi$/ } 0 .. $#lines;

    my @remote_outside;
    for my $i ( 0 .. $#lines ) {
        next if defined $pub_start && $i >= $pub_start && $i <= ( $pub_end // $pub_start );
        next if $lines[$i] =~ /^\s*#/;
        push @remote_outside, $i + 1
            if $lines[$i] =~ /git .*\b(?:push|fetch|ls-remote)\b/;
    }
    is_deeply( \@remote_outside, [],
        'no fetch, push or ls-remote outside the publish block' )
        or diag( "At line(s): @remote_outside\n"
            . 'A build that reaches for the network fails on the host it was '
            . 'designed to run on - which is what happened, twice, at opposite '
            . 'ends of the same command.' );
};

subtest 'publish refuses a tag that was never built' => sub {
    # It cannot invent one. The local tag is the evidence that a gate ran.
    my ( $rc, $out ) = run( 'publish', '9.99.99' );
    isnt( $rc, 0, 'refused' );
    like( $out, qr/does not exist locally/, 'because there is no such tag' );
    like( $out, qr/release\.sh build 9\.99\.99/,
        'and it says how to make one' );
};

subtest 'publish needs a version' => sub {
    my ( $rc, $out ) = run('publish');
    isnt( $rc, 0, 'refused' );
    like( $out, qr/publish needs a version|does not exist locally/, 'plainly' );
};

subtest 'and --no-fetch is accepted and inert' => sub {
    # The flag existed to tell a build not to reach the network. That is now
    # the only behaviour, so the flag means nothing - but an invocation
    # carrying it must not error, because the scripts and habits that pass it
    # are the ones that were working around the defect.
    open my $fh, '<', $REL or die $!;
    local $/;
    my $src = <$fh>;
    close $fh;
    like( $src, qr/--no-fetch is still accepted and ignored/,
        'documented as inert rather than removed' );
};

done_testing();
