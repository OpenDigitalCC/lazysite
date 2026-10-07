#!/usr/bin/perl
# THE RELEASE GATE CANNOT PROMPT FOR A PASSWORD, AND HIDES NO PRIVILEGE.
#
# 2026-10-04, the 0.15.2 build: the release manager ran tools/release.sh, the
# suite reached t/tools/81, and polkit asked them to authenticate to reload
# systemd. The test ran the package's postrm against a fake root it had only
# half built, so the host's own `systemctl daemon-reload` ran. From a terminal
# that is a password prompt holding a release; from a session without one it
# failed quietly and nobody saw it for releases.
#
# Two properties, both structural, so the next test with the same mistake cannot
# reach a person:
#
#   1. Every gate step - the suite, the bench, the coverage run - runs through
#      `detached`, which is `setsid -w ... </dev/null`: no controlling terminal,
#      so sudo and polkit cannot ask, and fail in the log instead.
#   2. The release script and the gate's own tools never call sudo, systemctl or
#      pkexec. A step that needs privilege is a step a person runs knowingly,
#      not one buried in a script they started for something else.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
sub slurp { open my $f, '<', $_[0] or die "$_[0]: $!"; local $/; my $t = <$f>; close $f; return $t }
sub code_lines {    # the executable lines, comments and echo/printf text removed
    my ($t) = @_;
    return grep { !/^\s*#/ && !/^\s*(?:echo|printf)\b/ } split /\n/, $t;
}

my $rel = slurp("$root/tools/release.sh");

subtest 'every gate step runs without a terminal' => sub {
    like( $rel, qr/^detached\(\) \{ setsid -w "\$\@" <\/dev\/null; \}$/m,
        '`detached` is setsid -w with stdin from /dev/null' );
    my @code = code_lines($rel);
    for my $step ( [ 'the suite', qr/\bprove -lr (?:-j\d+ )?t\// ], [ 'the bench', qr/tools\/bench\.pl" --check/ ],
        [ 'the coverage run', qr/tools\/coverage\.sh" --check/ ] )
    {
        my @uses = grep { $_ =~ $step->[1] } @code;
        ok( scalar @uses, "$step->[0] is in the gate" ) or next;
        is( scalar( grep { !/\bdetached\b/ } @uses ), 0, "and every call to it is detached" )
            or diag( "A gate step with a terminal can stop a release on a password prompt." );
    }
};

subtest 'no privilege is hidden in the release script or the gate tools' => sub {
    for my $f (qw(tools/release.sh tools/coverage.sh tools/bench.pl tools/handoff.sh tools/build-deb.sh)) {
        next unless -f "$root/$f";
        my @hits = grep { /\b(?:sudo|systemctl|pkexec)\b/ } code_lines( slurp("$root/$f") );
        is_deeply( \@hits, [], "$f calls no sudo, systemctl or pkexec" );
    }
};

done_testing();
