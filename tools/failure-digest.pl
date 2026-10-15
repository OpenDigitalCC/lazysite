#!/usr/bin/perl
# SM1083: tools/failure-digest.pl LOG - at most 20 lines from a prove or gate
# log: each failing test file, its first failed assertion, its first diagnostic
# line, and a class: ENV (inodes/memory/tmp/killed/lock) or TEST.
use strict;
use warnings;
my $log = shift // die "usage: failure-digest.pl LOG\n";
open my $f, '<', $log or die "$log: $!\n";
my $ENVRE = qr/inodes?\b|No\sspace\sleft|Cannot\sallocate\smemory|Out\sof\smemory|\bKILLED\b|exit\s(?:137|143)|Killed\b|heavy\slock|preflight:\snot\snow|ENOSPC|tmpfs/ix;
my ( @order, %name, %diag, %envhit, %seen, $cur, $want, @gl );
while ( my $l = <$f> ) {
    chomp $l;
    push @gl, $l if $l =~ $ENVRE;
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
    if ( @out > 19 ) {
        my $n = @out - 19;
        splice @out, 19;
        push @out, "... and $n more failing file(s)";
    }
}
elsif (@gl) {
    push @out, "no failing test file named | ENV | $gl[-1]";
}
else {
    push @out, "no failing test file named | TEST | read the log tail of $log";
}
print map { "$_\n" } @out;
