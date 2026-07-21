#!/usr/bin/perl
# Regression: concurrent writers of the auth store (lazysite/auth/users) must
# never leave it truncated. write_users used to open the store with '>'
# (truncate in place) and lock only AFTERWARDS, so a concurrent reader
# (verify-credential runs lock-free on every authenticated request) could catch
# it empty, and a crash mid-write left the credential store wiped. write_users
# now writes a temp sibling and rename(2)s it into place, so a reader always sees
# a complete store.
#
# This test drives many concurrent `add` commands and, while they run, reads the
# store repeatedly asserting the seed accounts are ALWAYS present (never a
# truncated/empty read). The lost-update guarantee (every concurrent add
# survives) is asserted once the store lock lands - see the note at the end.
use strict;
use warnings;
use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root  = repo_root();
my $utool = "$root/tools/lazysite-users.pl";

my $d = tempdir( CLEANUP => 1 );

# Seed a handful of accounts (sequential, operator CLI).
my @seed = map {"seed$_"} 1 .. 4;
for my $u (@seed) {
    system( $^X, $utool, '--docroot', $d, 'add', $u, "pw-$u" ) == 0
        or die "seed add $u failed";
}
my $store = "$d/lazysite/auth/users";
ok( -s $store, 'seed store written' );

# Fire K concurrent `add`s.
my $K = 10;
my @kids;
for my $id ( 1 .. $K ) {
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ( $pid == 0 ) {
        # Clean env: strip coverage instrumentation so K children don't contend
        # on cover_db (the writer is exercised by the other users tests too).
        %ENV = ( PATH => $ENV{PATH} // '/usr/bin:/bin' );
        open STDOUT, '>', '/dev/null';
        open STDERR, '>', '/dev/null';
        exec( $^X, $utool, '--docroot', $d, 'add', "extra$id", "pw$id" )
            or die "exec: $!";
    }
    push @kids, $pid;
}

# While the adds run, read the store repeatedly: every seed account must be
# present on every read. A truncated read (the old bug) drops them.
my $reads = 0;
my $bad   = 0;
while ( grep { waitpid( $_, 1 ) == 0 } @kids ) {    # 1 = WNOHANG
    for ( 1 .. 30 ) {
        $reads++;
        open my $rf, '<', $store or next;
        my $c = do { local $/; <$rf> };
        close $rf;
        $bad++ if grep { $c !~ /^\Q$_\E:/m } @seed;    # any seed account missing
    }
}
waitpid( $_, 0 ) for @kids;

cmp_ok( $reads, '>', 0, "reader observed the store mid-flight ($reads reads)" );
is( $bad, 0, 'no read ever saw a truncated store (seed accounts always present)' );

# Final store parses and still holds every seed account.
open my $f, '<', $store or die $!;
my $final = do { local $/; <$f> };
close $f;
for my $u (@seed) {
    like( $final, qr/^\Q$u\E:/m, "seed account $u intact after concurrent adds" );
}

# Every concurrent add survives (no lost update): each `add` holds the exclusive
# store lock across its whole read-modify-write, so two adds cannot both read the
# old store and clobber each other's new account. Without the lock, some of these
# adds are silently lost.
for my $id ( 1 .. $K ) {
    like( $final, qr/^extra$id:/m, "concurrent add extra$id survived (no lost update)" );
}

done_testing();
