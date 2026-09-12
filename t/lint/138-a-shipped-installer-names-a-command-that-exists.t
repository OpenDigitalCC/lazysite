#!/usr/bin/perl
# SM864: every users-tool command named in a shipped installer, README or runbook
# is one the tool actually dispatches.
#
# SM659 renamed `setup-manager` to `setup-sysop` and deliberately kept no alias.
# It updated installers/hestia/INSTALL-RUNBOOK.md and missed two other readers:
# lazysite-hestia-deploy.sh, which CALLED the dead verb on every fresh install,
# and debian/lazysite-hestia.README.Debian, which told operators to type it.
#
# The runbook being right is what hid it. A reader who checked one place found
# the current name and stopped - which is the shape this project keeps closing:
# a rename lands wherever the author was looking and survives everywhere else
# (feedback_a_declaration_the_code_ignores - find every reader).
#
# THE TOOL ITSELF IS NOT AT FAULT and this check does not pretend otherwise: it
# answers an unknown command with usage and exit 2, correctly. What failed was
# a caller that discarded that status, and a document nobody re-read. So this
# tests the DOCUMENTS AND SCRIPTS against the dispatcher, not the dispatcher.
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

# --- what the tool actually dispatches --------------------------------------
#
# Read from the ladder, never from a second list: the whole point is that a
# hand-kept copy is what drifts.
my $tool = slurp("$root/tools/lazysite-users.pl");
ok( $tool, 'the users tool is readable' ) or do { done_testing(); exit };

my %DISPATCHED;
while ( $tool =~ /\$cmd\s+eq\s+'([a-z][a-z0-9-]*)'/g ) { $DISPATCHED{$1} = 1 }
cmp_ok( scalar keys %DISPATCHED, '>=', 30,
    'the dispatcher was parsed (30+ commands found)' )
    or diag( 'If this drops, the ladder changed shape and the regex below no '
        . 'longer finds commands - which would make every assertion in this '
        . 'file vacuous rather than passing.' );

# --- the readers that name commands to an operator ---------------------------
my @READERS = qw(
    installers/hestia/lazysite-hestia-deploy.sh
    installers/hestia/lazysite-hestia-update-all.sh
    installers/hestia/INSTALL-RUNBOOK.md
    debian/lazysite-hestia.README.Debian
    debian/lazysite-common.postinst
    install.pl
    README.md
);

# Commands that were REMOVED and must not be named as though they work. Kept as
# an explicit list rather than "anything not dispatched", because prose legitimately
# mentions a retired name while explaining the change - only an INSTRUCTION to run
# one is a defect, and an explicit list is what lets this check say which is which.
my %RETIRED = ( 'setup-manager' => 'SM659 renamed it to setup-sysop, with no alias' );

my $checked = 0;
for my $rel (@READERS) {
    my $src = slurp("$root/$rel");
    next unless defined $src;
    $checked++;

    for my $dead ( sort keys %RETIRED ) {
        # An instruction to RUN it: the name preceded by the tool, or by the
        # `lazysite users` wrapper, on the same line. A sentence ABOUT the rename
        # is not matched, and should not be.
        my @bad = grep { /(?:lazysite-users\.pl|lazysite users)[^\n]*\b\Q$dead\E\b/ }
            split /\n/, $src;
        is( scalar @bad, 0, "$rel does not tell anyone to run '$dead'" )
            or diag( "$RETIRED{$dead}\n  " . join( "\n  ", @bad ) );
    }
}

cmp_ok( $checked, '>=', 5, 'the readers this checks were found on disk' )
    or diag( "Only $checked of " . scalar(@READERS) . " readers exist - if they "
        . 'moved, this list wants updating, not deleting.' );

# And the current name really is dispatched, so the advice these files now give
# is advice that works.
ok( $DISPATCHED{'setup-sysop'}, 'setup-sysop is dispatched' );
ok( !$DISPATCHED{'setup-manager'},
    'setup-manager is not - so naming it anywhere is naming nothing' );

done_testing();
