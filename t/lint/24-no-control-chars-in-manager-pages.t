#!/usr/bin/perl
# DRIFT GUARD: no control characters in a shipped manager page or content page.
#
# A literal NUL was written into starter/manager/appearance.md in 0.10.2, as a
# JavaScript key separator mirroring a Perl-side "$a\0$b" key. It worked at
# runtime, which is why it survived - but it made git treat the file as BINARY,
# so the change shipped with no reviewable diff and every later grep for the code
# silently found nothing. A defect that hides the file it lives in is worth a
# mechanical guard.
#
# Tabs and CR are allowed (real formatting); everything else in C0 except the
# ordinary whitespace is not.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../lib";
use TestHelper qw(repo_root);

my $root = repo_root();
my @dirs = ( "$root/starter/manager", "$root/starter/docs", "$root/starter" );

my %seen;
my @files;
for my $d (@dirs) {
    next unless -d $d;
    opendir my $dh, $d or next;
    for my $f ( sort readdir $dh ) {
        next unless $f =~ /\.(?:md|html|css|js|tt)\z/;
        my $p = "$d/$f";
        next unless -f $p;
        next if $seen{$p}++;
        push @files, $p;
    }
    closedir $dh;
}

cmp_ok( scalar @files, '>=', 20, 'found the shipped page set to scan' );

for my $p (@files) {
    open my $fh, '<:raw', $p or do { fail("$p: unreadable"); next };
    my $c = do { local $/; <$fh> };
    close $fh;
    ( my $rel = $p ) =~ s{^\Q$root\E/}{};

    if ( $c =~ /([\x00-\x08\x0b\x0c\x0e-\x1f])/ ) {
        my $ch  = ord($1);
        my $pos = $-[0];
        my $ctx = substr( $c, ( $pos > 40 ? $pos - 40 : 0 ), 80 );
        $ctx =~ s/[\x00-\x1f]/./g;
        fail("$rel: control character 0x"
                . sprintf( '%02x', $ch )
                . " at byte $pos" );
        diag("  context: ...$ctx...");
        diag('  A NUL here makes git treat the file as binary, so the change '
                . 'ships with no reviewable diff.');
    }
    else {
        pass("$rel: no control characters");
    }
}

done_testing();
