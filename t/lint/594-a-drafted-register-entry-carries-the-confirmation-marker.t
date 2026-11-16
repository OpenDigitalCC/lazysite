#!/usr/bin/perl
# SM1454 R6 (e): A REGISTER ENTRY THE AGENT DREW UP SAYS WHERE ITS CONFIRMATION STANDS.
#
# tools/confirm-register.pl finds a drafted entry by one phrase, "awaiting the release
# manager's confirmation", and the compliance check names an entry by the same phrase.
# n837 drafted SM1455's entry as "for the release manager's confirmation", the wording
# of its brief: both tools passed it over, the confirmation found nothing to confirm,
# and a branch of its own (a961517e7) rewrote two lines. Nothing read the wording.
#
# This lint does. In docs/SECURITY.md, every register entry whose heading is
# `(PENDING)` and whose Assessment says it was "drafted by the developer agent" carries,
# in the Assessment AND in the verdict, either
#
#   awaiting the release manager's confirmation
#   confirmed by the release manager on D Mon YYYY (ruling N)
#
# Entries dated before 2026-11-16 are grandfathered: older ones were written in other
# forms and are confirmed; this guards the entries drafted from here on.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $FROM    = '2026-11-16';
my $AWAIT   = qr/awaiting the release manager's confirmation/;
my $CONFIRM = qr/confirmed by the release manager on [^.\n]*? \(ruling \d+\)/;

# The faults in a register's text: one line each, naming the entry.
sub faults {
    my ($text) = @_;
    my @out;
    for my $entry ( split /(?=^### )/m, $text ) {
        my ($head) = $entry =~ /\A(### (\d{4}-\d{2}-\d{2})\b[^\n]*)/ or next;
        my $date = $2;
        next unless $head =~ /PENDING/;
        next if $date lt $FROM;

        # The Assessment: its paragraph, up to the next blank line.
        my @assessment = $entry =~ /^(Assessment\b[^\n]*(?:\n(?!\n)[^\n]*)*)/mg;
        next unless grep { /drafted by the developer agent/ } @assessment;
        my $title = $head =~ s/^### //r;

        my @bad = grep { !/$AWAIT|$CONFIRM/ } grep { /drafted by the developer agent/ } @assessment;
        push @out, "$title: the Assessment says drafted by the developer agent and not where its confirmation stands" if @bad;

        # The verdict: `verdict : ...` on a line, or `verdict` and `: ...` below it; to the blank line.
        my @verdict = $entry =~ /^verdict\b[ ]*(?::[^\n]*|\n:[^\n]*)(?:\n(?!\n)[^\n]*)*/mg;
        if ( !@verdict ) { push @out, "$title: it has no verdict" }
        elsif ( grep { !/$AWAIT|$CONFIRM/ } @verdict ) {
            push @out, "$title: the verdict does not say where the confirmation stands";
        }
    }
    return @out;
}

# --- the guard works: the wording that slipped through is a fault -------------

my $GOOD = <<'MD';
### 2026-11-20 - SM9001 (PENDING): a patch's entry

Assessment drafted by the developer agent (n900); awaiting the release manager's confirmation. A fix.

verdict : accepted, awaiting the release manager's confirmation. No trigger fires.

### 2026-11-20 - SM9002 (PENDING): a confirmed one

Assessment drafted by the developer agent; confirmed by the release manager on 20 Nov 2026 (ruling 262). A fix.

verdict
: accepted, confirmed by the release manager on 20 Nov 2026 (ruling 262). A stable patch.
MD
is_deeply( [ faults($GOOD) ], [], 'an entry awaiting confirmation, and one confirmed, are as they should be' );

# n837's: "for the release manager's confirmation", in both places (a961517e7^).
( my $n837 = $GOOD ) =~ s/awaiting the release manager's confirmation/for the release manager's confirmation/g;
is_deeply(
    [ faults($n837) ],
    [   '2026-11-20 - SM9001 (PENDING): a patch\'s entry: the Assessment says drafted by the developer agent and not where its confirmation stands',
        '2026-11-20 - SM9001 (PENDING): a patch\'s entry: the verdict does not say where the confirmation stands',
    ],
    'the n837 wording is a fault in the Assessment and in the verdict'
);

( my $half = $GOOD ) =~ s/^(verdict : accepted), awaiting the release manager's confirmation\./$1./m;
is_deeply( [ faults($half) ], ['2026-11-20 - SM9001 (PENDING): a patch\'s entry: the verdict does not say where the confirmation stands'],
    'a marker in the Assessment alone is not enough' );

( my $novd = $GOOD ) =~ s/^verdict :.*\n//m;
is_deeply( [ faults($novd) ], ['2026-11-20 - SM9001 (PENDING): a patch\'s entry: it has no verdict'], 'an entry with no verdict is a fault' );

( my $old = $n837 ) =~ s/2026-11-20/2026-11-15/g;
is_deeply( [ faults($old) ], [], 'an entry dated before 2026-11-16 is grandfathered' );

( my $nopending = $n837 ) =~ s/ \(PENDING\)//g;
is_deeply( [ faults($nopending) ], [], 'and one whose heading is not PENDING is not this lint\'s' );

( my $human = $n837 ) =~ s/drafted by the developer agent/written by the release manager/g;
is_deeply( [ faults($human) ], [], 'nor is one the agent did not draft' );

# --- the register as it stands ---------------------------------------------------

my $file = repo_root() . '/docs/SECURITY.md';
open my $fh, '<:utf8', $file or die "$file: $!";
my $register = do { local $/; <$fh> };
close $fh;
my $drafted = () = $register =~ /^### 20(?:2[6-9]|[3-9]\d)-\d\d-\d\d[^\n]*PENDING[^\n]*\n\nAssessment[^\n]*drafted by the developer agent/mg;
cmp_ok( $drafted, '>', 0, 'the register has drafted PENDING entries to read' );
is_deeply( [ faults($register) ], [], 'every drafted PENDING entry from 2026-11-16 says where its confirmation stands' )
    or diag( "Write \"awaiting the release manager's confirmation\" in the Assessment and the verdict,\n"
        . 'the words tools/confirm-register.pl rewrites on the release manager\'s ruling.' );

done_testing();
