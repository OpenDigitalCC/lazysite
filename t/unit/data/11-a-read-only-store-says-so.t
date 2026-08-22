#!/usr/bin/perl
# SM447 / D15: a store that cannot be read says WHY, and never reads as empty.
#
# THE FINDING, corrected. The first version of this claim said SQLite silently
# returns zero rows from a read-only directory. It does not - it raises
# "attempt to write a readonly database", because the store uses WAL and a WAL
# reader has to create a `-shm` file beside the database, so even
# `PRAGMA journal_mode` needs a writable directory.
#
# THE SILENCE WAS OURS. read_rows wrapped the schema probe in
# `eval { ... } || { exists => 0 }`, so a raised error became "the table has
# not been created yet" and the caller was told the table was empty. The engine
# reported the fault accurately and our fallback discarded it. That is worse
# than the fault, and it is the defect class this codebase spends most of its
# time removing.
#
# Read-only deployment may be a legitimate choice. Being unable to tell it
# apart from an empty table is not - which is the whole of this test.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../../lib";

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
plan skip_all => 'running as root - directory modes do not bind' if $> == 0;

use Lazysite::Data::Tables qw(apply_schema insert_row read_rows);
use Lazysite::Data::Connect qw(store_diagnosis);

sub site {
    my $d = tempdir( CLEANUP => 1 );
    make_path("$d/lazysite/db/tables");
    open my $fh, '>', "$d/lazysite/db/tables/p.yaml" or die $!;
    print {$fh} "key: code\nfields:\n  code:\n    type: text\n";
    close $fh;
    return $d;
}

subtest 'the diagnosis names each condition it has actually checked' => sub {
    my $d = site();
    my $n = store_diagnosis($d);
    is( $n->{reason}, 'no_store', 'no store yet is its own answer' );
    like( $n->{detail}, qr/created the first time a table is migrated/,
        'and says what would create one' );

    apply_schema( $d, 'p' );
    my $ok = store_diagnosis($d);
    is( $ok->{reason}, 'unknown',
        'a healthy store gives no false cause' )
        or diag( 'Offering a plausible story for a fault that is not there '
            . 'sends an operator to fix the wrong thing.' );
    like( $ok->{detail}, qr/not one this check knows about/,
        'and says so plainly' );
};

subtest 'a read-only store directory is REPORTED, not read as empty' => sub {
    my $d = site();
    apply_schema( $d, 'p' );
    insert_row( $d, 'p', { code => 'C1' } );

    my $dir = "$d/lazysite/db";
    my $mode = ( stat $dir )[2] & 07777;
    chmod 0500, $dir or plan skip_all => 'cannot chmod';

    my $why = store_diagnosis($d);
    is( $why->{reason}, 'directory_not_writable', 'the probe finds it' );
    like( $why->{detail}, qr/WAL/, 'and explains why a READ needs it' );

    my $r = read_rows( $d, 'p', as => 'operator' );
    ok( !$r->{ok}, 'and the read is an ERROR' )
        or diag( 'It used to return ok with an empty list and '
            . 'pending_schema, so an operator was told their table was '
            . 'empty when the store was unreadable.' );
    is( $r->{kind}, 'store_directory_not_writable',
        'with a kind a surface can branch on' );
    like( $r->{error}, qr/not writable/, 'and a message naming the cause' );

    chmod $mode, $dir;
};

subtest 'the probe is a real write, not a stat' => sub {
    # `-w` answers from the mode bits and the real uid, and gets a read-only
    # MOUNT, an ACL, or a container's view wrong - in the direction that
    # matters, reporting "writable" for a directory that is not.
    #
    # THE SABOTAGE FOR THIS ONE IS UNREACHABLE HERE, and that is recorded
    # rather than papered over. Replacing the real write with `-w` passes this
    # suite, because in a plain temp directory owned by the test user the two
    # answers agree. Making them disagree needs a read-only MOUNT or a POSIX
    # ACL, and both need root, which this environment does not have.
    #
    # So the argument for the real write is a reasoned one and not a
    # demonstrated one: `-w` reports on the mode bits, and the question is
    # whether a file can be created. What IS demonstrated below is that the
    # probe cleans up after itself, which is the risk the real write brings
    # with it.
    my $d = site();
    apply_schema( $d, 'p' );
    my $dir = "$d/lazysite/db";

    opendir my $dh, $dir or die $!;
    my @before = sort grep { !/\A\.\.?\z/ } readdir $dh;
    closedir $dh;

    store_diagnosis($d);

    opendir $dh, $dir or die $!;
    my @after = sort grep { !/\A\.\.?\z/ } readdir $dh;
    closedir $dh;
    is_deeply( \@after, \@before, 'the probe file is removed again' )
        or diag( 'A diagnostic that leaves litter in the store directory is '
            . 'a diagnostic somebody will later mistake for data.' );
};

done_testing();
