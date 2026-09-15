#!/usr/bin/perl
# SM887 D1/D2: the claude.ai skill is complete, and the release wires it up to
# carry the engine.
#
# THE DESIGN IS THE TEST. The skill works on any editor's container precisely
# because it fetches NOTHING from a host this project owns - the .deb is inside
# the zip, so the version matches by construction and the only network needed
# is the Ubuntu archive the base image already depends on. A skill that reached
# lazysite.io would work for the person who specified it and fail for everyone
# else, and the failure would arrive as a support question rather than a test
# result. That is the property worth a gate.
#
# WHAT THIS FILE CANNOT DO, said plainly: it does not run the skill. The cold
# install was run in a real ubuntu:24.04 container and the result is recorded
# in SM887; three of its constraints (the per-editor allowlist, the
# conversation lifecycle, the read-only mount) cannot be reproduced here at all
# and belong to claude.ai.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root  = repo_root();
my $skill = "$root/skills/claude-ai/lazysite";
plan skip_all => "no skill folder at $skill" unless -d $skill;

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or return '';
    local $/;
    return <$fh>;
}

subtest 'the deliverable is complete' => sub {
    # D1's list. A skill missing its setup script is not a smaller skill; it is
    # one that fails on its first call in the editor's conversation.
    for my $f ( qw(SKILL.md README.md setup.sh serve.sh fetch.pl
        reference/site-context.md reference/validating.md) )
    {
        ok( -f "$skill/$f", "$f ships" );
    }
};

subtest 'nothing is fetched from a host this project owns' => sub {
    my @bad;
    for my $f ( qw(SKILL.md README.md setup.sh serve.sh fetch.pl
        reference/site-context.md reference/validating.md) )
    {
        my $src = slurp("$skill/$f");
        push @bad, "$f names lazysite.io as something to download from"
            if $src =~ m{https?://[^\s'"]*lazysite\.io[^\s'"]*}
            && $src =~ /wget|curl -[^\s]*O|apt-get install http|download/i;
        push @bad, "$f fetches a release from github"
            if $src =~ m{api\.github\.com|github\.com/[^\s]+/releases};
    }
    is_deeply( \@bad, [], 'no release is fetched from anywhere' )
        or diag( join( "\n  ", @bad )
            . "\n\nAn allowlist is PER EDITOR. The container the briefing was "
            . "written in happened to permit *.lazysite.io; no other editor's "
            . "can be assumed to." );
};

subtest 'setup.sh installs the bundled deb, and says what it installed' => sub {
    my $src = slurp("$skill/setup.sh");
    like( $src, qr/lazysite-common_\*\.deb/, 'it looks for the bundled deb' );
    like( $src, qr/apt-get install/,
        'installed with apt-get, which resolves the Perl dependencies dpkg cannot' );
    like( $src, qr/dpkg-query/,
        'and idempotence is asked of dpkg rather than left to a marker file' );
    like( $src, qr/engine \$VERSION|\$VERSION/,
        'the version is printed - an editor on an old skill can see it' );
};

subtest 'no shipped script depends on curl' => sub {
    # FOUND BY RUNNING IT: ubuntu:24.04 has no curl. Every probe that reached
    # for it failed in a container the editor cannot inspect, reporting
    # something that looked like a broken page rather than a missing tool.
    my @bad;
    for my $f (qw(setup.sh serve.sh SKILL.md reference/site-context.md)) {
        my $src = slurp("$skill/$f");
        push @bad, $f if $src =~ /^[^#]*\bcurl\b/m;
    }
    is_deeply( \@bad, [], 'the skill uses its own fetch.pl, not curl' )
        or diag( 'curl in: ' . join( ', ', @bad ) );
};

subtest 'fetch.pl needs nothing that is not core Perl' => sub {
    my $src = slurp("$skill/fetch.pl");
    like( $src, qr/use IO::Socket::INET/, 'core sockets' );
    unlike( $src, qr/use (?:LWP|HTTP::Tiny|JSON::(?!PP))/,
        'and no module the container might not have' );
};

subtest 'the release builds the zip, with the deb inside it' => sub {
    my $rel = slurp("$root/tools/release.sh");
    like( $rel, qr/lazysite-skill-\$VERSION\.zip/, 'the zip is built' );
    like( $rel, qr/cp "\$DIST_DIR\/lazysite-common_\$\{VERSION\}-1_all\.deb" "\$SKILL_STAGE\//,
        'and the release .deb is copied INTO it - the whole design' );
    like( $rel, qr/lazysite-skill-\$VERSION\.zip" "\$FINAL_DIST\//,
        'and it survives the staging cleanup' );
    like( $rel, qr/zip\(1\) is not installed/,
        'a missing zip(1) is NAMED, not skipped silently' )
        or diag( 'An editor whose release has no skill zip cannot tell that '
            . 'from a release that never had one.' );
};

subtest 'the skill is not engine payload' => sub {
    # It carries the engine; it is not carried BY one. Shipping it into a site
    # would put the distribution the wrong way round - and the deb build is
    # what noticed, by refusing the manifest.
    my $cls = slurp("$root/dist/config/classification.json");
    like( $cls, qr/\^skills\//, 'skills/ is excluded from the payload manifest' );
};

done_testing();
