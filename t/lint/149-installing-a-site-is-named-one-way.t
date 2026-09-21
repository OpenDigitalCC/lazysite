#!/usr/bin/perl
# SM892 D5: the operator task "set this site up" and the operator task "move
# this site forward" are each named ONE way in every shipped document and
# script, and that way is a `lazysite` verb.
#
# WHY A LINT AND NOT JUST A SWEEP. The ruling this implements (U3) exists
# because the same task was named four ways depending on which file you opened,
# and the cost was not confusion in the abstract: on 2026-09-15 an operator
# walked the published install page, ran the command it gave on a LIVE site, and
# was told "Next steps: 1. Create the first account. A fresh install has NO
# accounts". The page said `install.sh`; the deb READMEs said `lazysite
# provision`; the runbook said a third thing; and the restart the release had
# just added lived in a fourth place none of them named. Each document was
# internally consistent. A reader who checked one place found an answer and
# stopped - which is the same shape t/lint/138 was written for, and the reason
# its rule is copied here rather than reinvented.
#
# WHAT IS CHECKED, AND WHAT IS DELIBERATELY NOT. This reads the DOCUMENTS AND
# SCRIPTS against the CLI's dispatcher. install.pl is not at fault and this does
# not pretend otherwise: it refuses a run with no --mode, by name, naming the
# three verbs. What failed was a set of readers nobody re-read.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();

sub slurp {
    my ($p) = @_;
    open my $fh, '<', $p or return undef;
    local $/;
    return <$fh>;
}

# --- A. the verbs the CLI actually dispatches --------------------------------
#
# Read from the dispatcher, never from a second list here: a hand-kept copy of
# the verb set is the thing that drifts, which is what this whole file is about.
my $cli = slurp("$root/tools/lazysite-cli.pl");
ok( $cli, 'the lazysite CLI is readable' ) or do { done_testing(); exit };

my %DISPATCHED;
while ( $cli =~ /\$verb\s+eq\s+'([a-z][a-z0-9-]*)'/g ) { $DISPATCHED{$1} = 1 }
cmp_ok( scalar keys %DISPATCHED, '>=', 12,
    'the dispatcher was parsed (12+ verbs found)' )
    or diag( 'If this drops, the dispatch chain changed shape and the regex no '
        . 'longer finds verbs - which would make the assertions below pass by '
        . 'examining an empty set rather than by being true.' );

for my $v (qw(provision upgrade reinstall)) {
    ok( $DISPATCHED{$v}, "`lazysite $v` is dispatched" )
        or diag( 'The documents repointed by SM892 D5 all name this verb. If it '
            . 'is gone, they name nothing - which is worse than the four '
            . 'spellings they replaced.' );
}
ok( $DISPATCHED{'backups'}, '`lazysite backups` is dispatched' )
    or diag( 'The recovery half. Without it the install page has to reach past '
        . 'the CLI to install.pl, and the second spelling is back.' );
ok( $DISPATCHED{'channel'} && $DISPATCHED{'policy'},
    '`lazysite channel` and `lazysite policy` are dispatched' );

# --- B. install.sh installs nothing ------------------------------------------
#
# It is kept because README.md, starter/docs/install.md and UPGRADE.md named it
# for years and deleting it would strand anyone still typing it. A signpost that
# quietly went on installing would be the second spelling with extra steps.
my $sh = slurp("$root/install.sh");
ok( $sh, 'install.sh is present (readers still name it)' );
SKIP: {
    skip 'no install.sh', 4 unless $sh;
    unlike( $sh, qr/^\s*exec\s+perl/m,
        'install.sh does not exec the installer' )
        or diag( 'This is the line that made it a second spelling of the same '
            . 'operation - and the spelling the documentation gave, so the '
            . 'spelling the field used.' );
    like( $sh, qr/\bexit\s+[1-9]/, 'it exits non-zero' )
        or diag( 'A signpost that exits 0 reports success for work it did not '
            . 'do. A deploy script wrapping it would carry on.' );
    for my $v (qw(provision upgrade)) {
        like( $sh, qr/\b\Q$v\E\b/, "it names `$v`" )
            or diag( 'Refusing without saying what to run instead leaves the '
                . 'operator exactly where the V3 walk left them.' );
    }
}

# --- the readers -------------------------------------------------------------
#
# Same inversion as t/lint/138, for the same reason: a hand-picked list is how
# that check missed the four worst instances in the tree. Every tracked file is
# a reader unless it is somewhere the project RECORDS HISTORY, where quoting the
# command an operator actually ran is correct and removing it would falsify the
# record.
my @EXEMPT = (
    qr{^CHANGELOG\.md$},           # dated entries describe the release they shipped in
    qr{^docs/review/},             # eight-dimension snapshots, true as at their date
    qr{^docs/feature-requests/},   # a filing ABOUT this must quote what was run
    qr{^inbox/},                   # field reports quote the command the operator typed
    qr{^install\.sh$},             # the signpost names itself
    qr{^install\.pl$},             # the implementation's own usage and comments
);

sub tracked_files {
    my @out;
    open my $ls, '-|', 'git', '-C', $root, 'ls-files' or return ();
    while ( my $l = <$ls> ) {
        chomp $l;
        next if $l =~ m{^(?:t/|tmp/)};
        push @out, $l;
    }
    close $ls;
    return @out;
}

my @READERS = grep {
    my $rel = $_;
    !( grep { $rel =~ $_ } @EXEMPT )
} tracked_files();

# Flattened the way t/lint/138 flattens, and for the reason it learned: the
# worst instance in that tree was a message built by concatenating over three
# lines, so a per-line grep saw innocent halves and missed it. NOT the full
# stop - `.` is inside `install.sh`, and stripping it makes the match find
# nothing at all, which is a check that passes by measuring nothing.
sub flatten {
    my ($src) = @_;
    ( my $flat = $src ) =~ s/[\n\r]+/ /g;
    $flat =~ s/\s*(?:^|\s)#\s*/ /g;
    $flat =~ s/['"]\s*[.,]?\s*['"]?/ /g;
    $flat =~ s/\s+/ /g;
    return $flat;
}

my ( $named_sh, $named_pl ) = ( 0, 0 );
for my $rel (@READERS) {
    my $src = slurp("$root/$rel");
    next unless defined $src;
    my $flat = flatten($src);

    # --- C. nothing tells anyone to RUN install.sh ---------------------------
    #
    # A runnable instruction is the name next to a path option. Prose about the
    # file - "install.sh installs nothing", the tree listing in the development
    # briefing - carries no --docroot and is not matched, and should not be.
    if ( $flat =~ /install\.sh/ ) {
        $named_sh++;
        my @bad;
        push @bad, $1 while $flat =~ /(install\.sh.{0,160}?--docroot)/gs;
        is( scalar @bad, 0, "$rel does not tell anyone to run install.sh" )
            or diag( "install.sh installs nothing - it prints the verbs and "
                . "exits 2. An instruction to run it with paths is an "
                . "instruction that fails.\n  "
                . join( "\n  ", @bad ) );
    }

    # --- D. a caller that drives install.pl DECLARES the mode ---------------
    #
    # install.pl is the implementation, and the Hestia scripts legitimately call
    # it - they hold the context the verb would otherwise supply. What they may
    # not do is call it the way the operator used to: with both paths and no
    # word for which of the three operations they mean. That is U2, applied to
    # machinery as well as to people.
    #
    # The discriminator is both paths: install-or-upgrade is the only operation
    # that needs a --cgibin. The maintenance probes take --docroot alone and are
    # named here so a reader can see they were considered rather than missed.
    #
    # THE WINDOW IS A FIXED LENGTH AND NOT A LAZY MATCH TO `--cgibin`. The first
    # draft stopped at the first --cgibin it found, which in the CLI's own
    # _install_argv is the token immediately BEFORE --mode - so it reported the
    # one call site in the tree that gets this right, and would have gone on
    # reporting it for as long as the arguments stayed in that order. A window
    # that ends where the evidence begins measures the argument order, not the
    # declaration.
    if ( $flat =~ /install\.pl/ ) {
        $named_pl++;
        my @bad;
        while ( $flat =~ /install\.pl/g ) {
            my $at = $-[0];
            my $win = substr $flat, $at, 280;
            # Never run past the next invocation into its arguments.
            $win =~ s/(?<=.)install\.pl.*\z//s;
            next unless $win =~ /--docroot/ && $win =~ /--cgibin/;
            next if $win =~ /--mode\b/;
            next if $win =~ /--verify\b|--channel-check\b/;
            push @bad, $win;
        }
        is( scalar @bad, 0, "$rel declares a mode wherever it drives install.pl" )
            or diag( "install.pl no longer decides whether it is installing, "
                . "upgrading or reinstalling. Pass --mode, or - if this is a "
                . "reader rather than machinery - name the `lazysite` verb.\n  "
                . join( "\n  ", @bad ) );
    }
}

# The floors that stop this going vacuous. They are FLOORS, not counts: files
# come and go. If one trips, discovery broke (git ls-files empty, the tree
# moved), which would make every assertion above pass by finding nothing.
cmp_ok( $named_sh, '>=', 3, 'the tracked files naming install.sh were discovered' )
    or diag( "Only $named_sh files named install.sh. README.md, "
        . 'starter/docs/install.md, UPGRADE.md and the development notes all '
        . 'do - a number below that means discovery failed, not that the '
        . 'readers were fixed.' );
cmp_ok( $named_pl, '>=', 5, 'the tracked files naming install.pl were discovered' )
    or diag( "Only $named_pl files named install.pl." );

done_testing();
