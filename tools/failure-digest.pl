#!/usr/bin/perl
# SM1083: tools/failure-digest.pl LOG - at most 20 lines from a prove or gate
# log: each failing test file, its first failed assertion, its first diagnostic
# line, and a class: ENV (inodes/memory/tmp/killed/lock) or TEST.
#
# THE COVERAGE STAGE HAS ITS OWN SHAPE. A gate log carries cover(1)'s source
# listing, where comment lines quote words like "inodes" and "BELOW"; the first
# version let one of those stand in for the failure ("70 # The first version
# let them start..." on 0.15.5). A line that starts with '#' (after any line
# number) is never quoted. "COVERAGE BELOW FLOOR" is reported as the group and
# the file: measured X% against floor Y%, or not measured by the group's tests.
use strict;
use warnings;
my $log = shift // die "usage: failure-digest.pl LOG\n";
open my $f, '<', $log or die "$log: $!\n";
my $ENVRE =
    qr/inodes?\b|No\sspace\sleft|Cannot\sallocate\smemory|Out\sof\smemory|\bKILLED\b|exit\s(?:137|143)|Killed\b|heavy\slock|preflight:\snot\snow|ENOSPC|tmpfs/ix;
my ( @order, %name, %diag, %envhit, %seen, $cur, $want, @gl );
my $group = '?';
my ( @below, $below_flag, $group_failed );
while ( my $l = <$f> ) {
    chomp $l;
    my $comment = $l =~ /^\s*\d*\s*#/;   # a comment, or a source-listing line quoting one
    push @gl, $l if !$comment && $l =~ $ENVRE;

    # The coverage stage, group by group.
    if ( $l =~ /^coverage: group (\S+): MEASURING/ ) { $group = $1; next }
    if ( $l =~ /^coverage: group (\S+): PASSED/ )    { @below = (); next }
    if ( $l =~ /^\s+(\S+)\s+stmt\s+([\d.]+)%\s+bran\s+([\d.]+)%\s+\(floors\s(\d+)%\/(\d+)%\)\s+(BELOW(?:-BRANCH)?)$/x ) {
        my ( $file, $st, $br, $sfl, $bfl, $what ) = ( $1, $2, $3, $4, $5, $6 );
        push @below,
            $what eq 'BELOW'
            ? "coverage: group $group below floor - $file measured $st% vs floor $sfl% (statements) | TEST"
            : "coverage: group $group below floor - $file measured $br% vs floor $bfl% (branches) | TEST";
        next;
    }
    if ( $l =~ /^\s+(\S+)\s+NOT MEASURED - gate failure/ ) {
        push @below, "coverage: group $group below floor - $1 not measured by the group's tests | TEST";
        next;
    }
    if ( $l =~ /^COVERAGE BELOW FLOOR$/ ) { $below_flag = 1; next }
    if ( $l =~ /^coverage: group (\S+): FAILED (.*)$/ ) { $group_failed = "coverage: group $1: FAILED $2"; next }

    # prove's shape.
    if ( $l =~ /^#\s+Failed test '(.*)'/ ) { $cur = $1; $want = undef; next }
    if ( $l =~ /^not ok \d+\s*-?\s*(.*)/ ) { $cur = $1; next }
    if ( $l =~ /^#\s+at (\S+\.t) line \d+/ ) {
        my $t = $1;
        push @order, $t unless $seen{$t}++;
        $name{$t} //= $cur if defined $cur;
        $want = $t;
        next;
    }
    if ( defined $want && $l =~ /^#\s+(\S.*)/ ) {
        $diag{$want} //= $1;
        $envhit{$want} = 1 if $l =~ $ENVRE;
        next;
    }
    $want = undef if $l !~ /^#/;
    if ( $l =~ /^(t\/\S+\.t)\s+\(Wstat: (\d+)/ ) {
        push @order, $1 unless $seen{$1}++;
        $diag{$1} //= "Wstat $2";
    }
}
my @out;
if (@order) {
    my $global = @gl ? 1 : 0;
    for my $t (@order) {
        my $env = $envhit{$t} || ( ( $diag{$t} // '' ) =~ $ENVRE ) || ( $global && !defined $name{$t} );
        push @out, sprintf '%s | %s | %s | %s', $t, $name{$t} // '(no assertion named)', $diag{$t} // '(no diagnostic)', $env ? 'ENV' : 'TEST';
    }
}
elsif ( $below_flag && @below ) {
    @out = @below;
    push @out, "$group_failed | TEST" if $group_failed;
}
elsif ($group_failed) {
    push @out, "$group_failed | " . ( ( $group_failed =~ $ENVRE || ( @gl && $gl[-1] =~ $ENVRE ) ) ? 'ENV' : 'TEST' );
    push @out, "no failing test file named | ENV | $gl[-1]" if @gl;
}
elsif (@gl) {
    push @out, "no failing test file named | ENV | $gl[-1]";
}
else {
    push @out, "no failing test file named | TEST | read the log tail of $log";
}
if ( @out > 20 ) {
    my $n = @out - 19;
    splice @out, 19;
    push @out, "... and $n more line(s)";
}
print map { "$_\n" } @out;
