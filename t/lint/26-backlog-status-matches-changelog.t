#!/usr/bin/perl
# SM258: an item named as SHIPPED in a released CHANGELOG entry must not still
# call itself open work.
#
# WHY THIS EXISTS. Marking the doc is a manual step at the end of a release,
# competing for attention with the gate, the tag and the build. Nothing failed
# when it was skipped, so it was skipped: 25 items were corrected at the 0.10.2
# cut and 10 more at 0.10.3 - and four of the ten were among the original 25,
# drifted straight back, because the first correction fixed the data and left the
# mechanism alone.
#
# t/lint/09 cannot catch this by construction. It reads each doc in isolation and
# checks a status against its OWN status-note, so an item that shipped, whose
# note describes the problem and never mentions a release, is internally
# consistent while being wrong. Internal consistency is the wrong axis. The
# CHANGELOG is the external fact: it is the file the release process already
# maintains carefully, and it names exactly which SM numbers each release
# carried.
#
# SHIPPED VERSUS MERELY MENTIONED. A release section names SM numbers in two
# quite different senses, and conflating them would make this lint demand that
# newly-FILED items be marked shipped:
#
#   - SM238 (37e7c37) per-domain tools over MCP: ...      <- shipped here
#   - Docs: SM231, SM245 and SM248-SM254 recorded ...     <- filed, still open
#
# The distinguishing convention is that a shipped item begins its own bullet and
# carries the commit that implemented it. That convention is now stated in the
# CHANGELOG's own preamble rather than left to be inferred, and this test asserts
# the statement is still there - a convention no one has written down is one the
# next person will break.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

open my $cfh, '<:utf8', "$root/CHANGELOG.md" or die "CHANGELOG.md: $!";
my @lines = <$cfh>;
close $cfh;

# --- the convention is written down -----------------------------------------
{
    my $text = join '', @lines;
    like( $text, qr/begins its own bullet/i,
        'the CHANGELOG states how a shipped item is distinguished from a mention' );
}

# --- collect what each RELEASED entry claims to have shipped ----------------
# Only versioned headings count. Prose about future work, and any unreleased
# section, must never flip a status.
my %claimed;    # SM number => { release => ..., refs => ... }
my @buried;     # SM+ref pairs sharing a bullet with an earlier claim
my $release;
for my $l (@lines) {
    if ( $l =~ /^##\s+(\d+\.\d+\.\d+)\b/ ) { $release = $1; next }
    if ( $l =~ /^##\s/ ) { $release = undef; next }    # About-this-changelog etc
    next unless defined $release;

    # A shipped bullet: one or more SM numbers opening the bullet, then the
    # COMMIT REF(S) that implemented them.
    #
    # The parenthetical must be commit-shaped, not merely present. 0.9.7 carries
    #   - SM184 (publish pages by email) recorded as a candidate proposal (doc only).
    # which opens a bullet with an SM number and a parenthetical, and is a filing
    # rather than a ship - the commit ref is exactly what distinguishes an item
    # that was BUILT from one that was written down.
    next
        unless $l
        =~ /^-\s+((?:SM\d+)(?:\s*[\/,+]\s*SM\d+)*)\s*\(([0-9a-f]{7,40}(?:\s*,\s*[0-9a-f]{7,40})*)\)/;
    my ( $sms, $refs, $matched ) = ( $1, $2, $& );
    for my $sm ( $sms =~ /SM(\d+)/g ) {
        $claimed{$sm} //= { release => $release, refs => $refs };
    }

    # A SECOND SM+ref pair later in the same bullet is a claim this guard cannot
    # see. 0.10.4 shipped SM258 inside SM254's bullet - "SM254 (4412cdc) ...;
    # SM258 (6f0e629) ..." - so SM258 read as a MENTION, stayed `candidate`
    # through its own release, and the lint it introduced could not catch it.
    #
    # Buried pairs are not silently adopted: an SM cited mid-bullet is genuinely
    # ambiguous (a Docs: bullet lists filings exactly that way), so the fix is to
    # split the bullet, not to guess. Collected and reported below.
    my $rest = $l;
    substr( $rest, 0, length $matched ) = '';
    while ( $rest =~ /(SM\d+)\s*\(([0-9a-f]{7,40})\)/g ) {
        push @buried, "$release: $1 ($2) is buried in another bullet";
    }
}

ok( scalar keys %claimed, 'found shipped items in the CHANGELOG' )
    or diag 'no release bullet matched - has the format changed?';

# --- every claimed item is in a terminal state ------------------------------
# `partial` is legitimate: an item can ship in stages, and t/lint/09 already
# makes a partial explain what remains. `candidate` never is.
my %TERMINAL = map { $_ => 1 } qw(shipped partial superseded);

my @wrong;
my @missing;
for my $sm ( sort { $a <=> $b } keys %claimed ) {
    my ($file) = glob "$root/docs/feature-requests/SM$sm-*.md";
    unless ( defined $file && -f $file ) {
        push @missing, "SM$sm (released in $claimed{$sm}{release})";
        next;
    }
    open my $fh, '<:utf8', $file or die "$file: $!";
    my $doc = do { local $/; <$fh> };
    close $fh;

    my ($status) = $doc =~ /^status:\s*(\S+)\s*$/m;
    $status //= '(none)';
    next if $TERMINAL{$status};

    my $rel = $claimed{$sm}{release};
    my $ref = $claimed{$sm}{refs};
    push @wrong,
        "SM$sm is '$status' but shipped in $rel (commit $ref)"
        . " - mark it shipped and record the release in its status-note";
}

is_deeply( \@wrong, [],
    'no released item still calls itself open work' )
    or diag( join "\n  ", '', @wrong );

is_deeply( \@missing, [],
    'every released item has a feature-request doc' )
    or diag( join "\n  ", '', @missing );

is_deeply( \@buried, [],
    'no shipped item is buried mid-bullet, where this guard cannot see it' )
    or diag( join "\n  ",
    '', @buried,
    'Give each shipped item its OWN bullet: the convention is "- SM<n> (<ref>) ..."',
    'and an SM cited mid-bullet is read as a reference, not a claim.' );

# NB: the reverse check - a doc marked shipped that no released entry mentions -
# is deliberately NOT made. An item can genuinely ship inside another SM's work
# and never earn its own bullet, so that direction produces false failures. If it
# is ever wanted it belongs as a warning, not a failure.

done_testing();
