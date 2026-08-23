#!/usr/bin/perl
# SM495: the Status button's answer carries a message.
#
# The Plugin Manager renders data.message || 'Done.' - so a status() that
# returns modules, store and tables but no message is a button that says
# 'Done.' while three fields go unread. Reported from the field minutes
# after SM477 made the button work at all: true, and useless.
#
# The message is one line, worst news first. The missing-module branch is
# driven with an @INC hook (via PERL5OPT) that refuses DBD/SQLite.pm - the
# branch exists FOR hosts this test host is not, so the test makes itself
# one.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON::PP   qw(decode_json);
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

my $root   = repo_root();
my $plugin = "$root/plugins/data.pl";

sub status_for {
    my ($docroot) = @_;
    my $out = qx($^X \Q$plugin\E --action status --docroot \Q$docroot\E 2>/dev/null);
    return eval { decode_json($out) } || {};
}

subtest 'no store yet: the message says so, as a state, not an error' => sub {
    my $docroot = tempdir( CLEANUP => 1 );
    my $r       = status_for($docroot);
    ok( $r->{ok}, 'status ok' );
    like( $r->{message}, qr/^Data tables: no store yet/, 'names the state' );
    like( $r->{message}, qr/created on the first declared table/,
        'and says how it changes - the reader is one step from healthy' );
};

subtest 'a store with tables: count, names, size' => sub {
    my $docroot = tempdir( CLEANUP => 1 );
    make_path("$docroot/lazysite/db/tables");
    open my $st, '>', "$docroot/lazysite/db/data.sqlite" or die $!;
    print {$st} 'x' x 2048;
    close $st;
    for my $t (qw(events products)) {
        open my $fh, '>', "$docroot/lazysite/db/tables/$t.yaml" or die $!;
        print {$fh} "table: $t\n";
        close $fh;
    }
    my $r = status_for($docroot);
    like( $r->{message}, qr/2 table\(s\): events, products/, 'count and names' );
    like( $r->{message}, qr/store 2 KB/,                     'and the store size' );
    is_deeply( $r->{tables}, [qw(events products)],
        'the structured fields are still there for tooling' );
};

subtest 'a store with no tables is its own state' => sub {
    my $docroot = tempdir( CLEANUP => 1 );
    make_path("$docroot/lazysite/db");
    open my $st, '>', "$docroot/lazysite/db/data.sqlite" or die $!;
    print {$st} 'x';
    close $st;
    my $r = status_for($docroot);
    like( $r->{message}, qr/store present, no tables declared/,
        'distinct from both "no store" and "N tables"' );
};

subtest 'a missing module is the FIRST thing the message says' => sub {
    # The one failure that explains every other failure. Block DBD::SQLite
    # from loading in the child and the message must lead with it - even
    # though a store and tables are present and would otherwise be the news.
    my $docroot = tempdir( CLEANUP => 1 );
    make_path("$docroot/lazysite/db/tables");
    open my $st, '>', "$docroot/lazysite/db/data.sqlite" or die $!;
    print {$st} 'x';
    close $st;
    open my $fh, '>', "$docroot/lazysite/db/tables/events.yaml" or die $!;
    print {$fh} "table: events\n";
    close $fh;
    my $hookdir = tempdir( CLEANUP => 1 );
    open my $bh, '>', "$hookdir/BlockSqlite.pm" or die $!;
    print {$bh} <<'PM';
package BlockSqlite;
unshift @INC, sub { die "blocked by test\n" if $_[1] eq 'DBD/SQLite.pm'; return };
1;
PM
    close $bh;
    local $ENV{PERL5OPT} = "-I$hookdir -MBlockSqlite";
    my $r = status_for($docroot);
    is( $r->{modules}{'DBD::SQLite'}, 'missing', 'the hook bites: module reported missing' )
        or diag('If this says present, the test host leaked through and the subtest proves nothing.');
    like( $r->{message}, qr/^Data tables: missing Perl module\(s\): DBD::SQLite/,
        'the message leads with the missing module, not the table count' )
        or diag("message was: $r->{message}");
};

done_testing();
