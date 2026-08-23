#!/usr/bin/perl
# DM-5: the two things a descriptor editor needs that nothing provided.
#
# 1. THE DESCRIPTOR'S SOURCE. data-table returns the parsed shape, which is
#    right for an agent and wrong for a person: their comments, key order and
#    spacing are part of what they wrote, and a round trip through the parser
#    throws all three away. An editor that loaded the parsed shape would save
#    a file the operator did not write.
#
# 2. A PLAN THAT APPLIES NOTHING. data-migrate plans and applies in one call.
#    An operator deciding whether to migrate needs to see what it would do
#    first - and when a step is blocked, they need SM487's data checks ("2 rows
#    have no when") at the moment of deciding, not as a rollback after they
#    have confirmed losing a column.
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
use Lazysite::Data::Tables qw(apply_schema insert_row read_rows);
use Lazysite::Manager::Data ();

my $docroot = tempdir( CLEANUP => 1 );
make_path("$docroot/lazysite/db/tables");
open my $c, '>', "$docroot/lazysite/lazysite.conf" or die $!;
print {$c} "site_name: T\nplugins:\n  - plugins/data.pl\n";
close $c;
$Lazysite::Manager::Data::DOCROOT = $docroot;

my $SOURCE = <<'YAML';
# The events calendar. Keep `when` optional until the backfill is done.
key: code
fields:
  code:
    type: text
  when:
    type: date
  note:
    type: text
YAML
open my $f, '>', "$docroot/lazysite/db/tables/events.yaml" or die $!;
print {$f} $SOURCE;
close $f;
apply_schema( $docroot, 'events' );
insert_row( $docroot, 'events', { code => 'E1', when => '2026-01-01', note => 'a' } );
insert_row( $docroot, 'events', { code => 'E2', note => 'b' } );    # no when

subtest 'THE SOURCE COMES BACK AS WRITTEN' => sub {
    my $r = Lazysite::Manager::Data::action_data_table_source('events');
    ok( $r->{ok}, 'the source is returned' ) or diag( $r->{error} );
    is( $r->{descriptor}, $SOURCE, 'byte for byte' )
        or diag( 'A comment or a key order lost here is a file the operator '
            . 'did not write, saved back over the one they did.' );
    like( $r->{descriptor}, qr/^# The events calendar/m, 'including the comment' );
};

subtest 'a plan with nothing to do says so' => sub {
    my $p = Lazysite::Manager::Data::action_data_migrate_plan('events');
    ok( $p->{ok}, 'a plan is produced' ) or diag( $p->{error} );
    ok( !$p->{create}, 'the table exists' );
    is( scalar @{ $p->{additive} }, 0, 'nothing additive' );
    is( scalar @{ $p->{blocked} },  0, 'nothing blocked' );
    ok( !$p->{rebuild}, 'and no rebuild is offered' )
        or diag( 'Offering a rebuild when nothing needs one invites one.' );
};

subtest 'A PLAN SHOWS THE DATA CHECKS BEFORE ANYTHING IS CONFIRMED' => sub {
    # Tighten `when` to required and drop `note`: the field agent's session.
    open my $g, '>', "$docroot/lazysite/db/tables/events.yaml" or die $!;
    print {$g} "key: code\nfields:\n  code:\n    type: text\n  when:\n    type: date\n    required: true\n";
    close $g;

    my $p = Lazysite::Manager::Data::action_data_migrate_plan('events');
    ok( $p->{ok}, 'a plan is produced' ) or diag( $p->{error} );
    ok( scalar @{ $p->{blocked} }, 'the tightening is blocked for migrate' );
    ok( $p->{rebuild}, 'so a rebuild is assessed' )
        or diag( 'Without this the operator learns about the rebuild only by '
            . 'trying it.' );

    my @db = @{ $p->{rebuild}{data_blocked} || [] };
    ok( scalar @db, 'AND THE DATA CHECK IS IN THE PLAN' )
        or diag( 'This is SM487 surfacing where it is useful: at decision '
            . 'time, not as a rollback after confirming.' );
    like( $db[0]{why}, qr/1 row has no 'when'/, 'counting the row that blocks it' );
    is_deeply( $p->{rebuild}{lost}, ['note'], 'and the column that would be dropped' );

    # AND NOTHING CHANGED. A plan is a plan.
    my $rows = read_rows( $docroot, 'events', as => 'operator', order_by => 'code' )->{rows};
    is( scalar @{$rows}, 2, 'both rows still there' );
    ok( exists $rows->[0]{note}, 'note is still a column' );
};

subtest 'fix the row, and the plan offers the rebuild' => sub {
    Lazysite::Data::Tables::update_row( $docroot, 'events', 'E2', { when => '2026-02-02' } );
    my $p = Lazysite::Manager::Data::action_data_migrate_plan('events');
    is( scalar @{ $p->{rebuild}{data_blocked} || [] }, 0, 'no data blocks now' )
        or diag( explain $p->{rebuild} );
    is_deeply( $p->{rebuild}{lost}, ['note'], 'the dropped column is still named' );
};

subtest 'a table that does not exist is not a plan' => sub {
    my $p = Lazysite::Manager::Data::action_data_migrate_plan('nosuch');
    ok( !$p->{ok}, 'refused' );
    my $s = Lazysite::Manager::Data::action_data_table_source('nosuch');
    ok( !$s->{ok}, 'and has no source' );
    is( $s->{kind}, 'no_such_table', 'as no such table' );
};

done_testing();
