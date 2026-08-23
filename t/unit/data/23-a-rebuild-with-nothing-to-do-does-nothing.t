#!/usr/bin/perl
# SM489: a rebuild with nothing to do does nothing.
#
# THE FIELD AGENT FOUND THIS BY BEING CARELESS IN A USEFUL WAY. Sweeping
# data-* replies for leaked paths, they pointed data-rebuild at a live table
# that had NO pending change - data-migrate on it returned applied:[] - and
# expected it to say the same. It rebuilt: built the copy, copied the rows,
# dropped the original, renamed into place. Rows intact, but a production
# table had been dropped and recreated with no prompt and no change to justify
# it. Nothing was lost, so nothing was confirmed - correct in isolation, wrong
# when nothing needed doing.
#
# Fixing the no-op closes the no-confirmation gap WITHOUT adding a
# confirmation: the thing that would have been confirmed does not happen.
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib";

BEGIN {
    eval { require DBI; require DBD::SQLite; require YAML::PP; 1 }
        or plan skip_all => 'DBI/DBD::SQLite/YAML::PP not available';
}
use Lazysite::Data::Tables qw(apply_schema insert_row read_rows rebuild_table);
use Lazysite::Manager::Data ();

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/db/tables");
open my $c, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$c} "site_name: T\nplugins:\n  - plugins/data.pl\n";
close $c;
my $path = "$docroot/lazysite/db/tables/live.yaml";
sub describe { open my $f, '>', $path or die $!; print {$f} $_[0]; close $f }
describe("public: true\nkey: code\nfields:\n  code:\n    type: text\n  note:\n    type: text\n");
apply_schema( $docroot, 'live' );
insert_row( $docroot, 'live', { code => 'L1', note => 'keep' } );
$Lazysite::Manager::Data::DOCROOT = $docroot;

subtest 'A REBUILD WITH NO PENDING CHANGE IS A NO-OP' => sub {
    my $r = rebuild_table( $docroot, 'live' );
    ok( $r->{ok},   'it answers ok' ) or diag( $r->{error} );
    ok( $r->{noop}, 'and says it did nothing' )
        or diag( 'This dropped and recreated a live table with no prompt and '
            . 'no change to justify it. Nothing was lost, so nothing was '
            . 'confirmed - and nothing needed doing.' );
    ok( !$r->{rebuilt}, 'rebuilt is false' );
    like( $r->{note}, qr/already matches/, 'saying the shapes agree' );
    ok( !-d "$docroot/lazysite/db/rebuilds"
            || !( glob "$docroot/lazysite/db/rebuilds/live-*" ),
        'and no safety export was written - there was nothing to protect' );
};

subtest 'a rebuild that drops a column still asks, then runs' => sub {
    # The no-op must not swallow real rebuilds. Drop `note`: now there IS
    # something to lose, and the confirmation flow is unchanged.
    describe("public: true\nkey: code\nfields:\n  code:\n    type: text\n");
    my $ask = rebuild_table( $docroot, 'live' );
    is( $ask->{kind}, 'needs_confirmation', 'a real rebuild still asks' );
    my $r = rebuild_table( $docroot, 'live', confirm_lost => ['note'] );
    ok( $r->{ok} && !$r->{noop}, 'and runs when confirmed' ) or diag( $r->{error} );
    is_deeply( $r->{lost}, ['note'], 'dropping what was confirmed' );
};

subtest 'data-table reports what data-tables reports' => sub {
    # The reply for a published and an unpublished table used to be identical.
    my $one = Lazysite::Manager::Data::action_data_table('live');
    ok( $one->{public}, 'a published table says so' );
    ok( !$one->{pending_schema}, 'and a migrated one carries no pending flag' );

    describe("key: code\nfields:\n  code:\n    type: text\n  extra:\n    type: text\n");
    my $two = Lazysite::Manager::Data::action_data_table('live');
    ok( !$two->{public}, 'an unpublished table says so' )
        or diag( 'data-table is what somebody inspecting ONE table reaches '
            . 'for when asking why a page is empty. It has to answer.' );
    # The stored table still exists, so pending_schema is a question the
    # listing answers as "exists" - a field added but unmigrated is an additive
    # step, reported by data-migrate-plan, not by this flag.
    ok( !$two->{pending_schema}, 'pending_schema means the store, not a diff' );
};

done_testing();
