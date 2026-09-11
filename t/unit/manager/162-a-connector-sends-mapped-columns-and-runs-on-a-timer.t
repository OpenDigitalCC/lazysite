#!/usr/bin/perl
# SM579 phase 2: the row source (mode 2 from a page action) and the timer
# (mode 1). Two of the filing's own proving tests live here:
#
#   "A table-sourced call sends only mapped columns; an unmapped new column
#    is not sent."
#   "A connector configured as scheduled-only refuses a request-time
#    invocation."
#
# THE SHAPE THAT MAKES A ROW SOURCE SAFE is that the caller sends a KEY, never
# a payload. A page action says "send order 41"; what order 41 actually
# contains is decided by the connector's map and by what the account may read.
# A caller that could hand over a payload could send anything at all under the
# operator's credential, which is the difference between a button and a relay.
use strict;
use warnings;
use Test::More;
use File::Path qw(make_path);
use FindBin;
use lib "$FindBin::Bin/../../lib", "$FindBin::Bin/../../../lib";
use TestHelper qw(site_tempdir);

use Lazysite::Manager::Connectors ();

my $d = site_tempdir();
make_path("$d/lazysite/connectors");
$Lazysite::Manager::Connectors::DOCROOT = $d;

sub save {
    my ( $id, %def ) = @_;
    return Lazysite::Manager::Connectors::action_connector_save( $id, {%def} );
}

subtest 'a row map is validated, and a map without a table is refused' => sub {
    my $r = save( 'orders', url => 'https://example.test/x',
        row_table => 'orders', row_map => { customer => 'name', total => 'amount' } );
    ok( $r->{ok}, 'a connector may name a table and map its columns' ) or diag explain $r;

    my $bad = save( 'nomap', url => 'https://example.test/x',
        row_map => { customer => 'name' } );
    ok( !$bad->{ok}, 'a map with no table is refused' );
    like( $bad->{error}, qr/row_table/, 'and says what is missing' );

    my $badcol = save( 'badcol', url => 'https://example.test/x',
        row_table => 'orders', row_map => { 'Not A Column' => 'x' } );
    ok( !$badcol->{ok}, 'a column name that is not one is refused' );
};

# The heart of it. The connector is asked for a row whose table has a column
# the map does not name - the shape of a table that gained a field after the
# connector was written.
subtest 'only mapped columns are sent, including when the table grows' => sub {
    my $all = Lazysite::Manager::Connectors::connectors();
    my $c   = $all->{orders};
    ok( $c, 'the connector is stored' ) or return;

    # Stand in for the store: what row_payload does with a row is the subject
    # here. THE REQUIRE COMES FIRST - loading the module after the override
    # replaces it with the real sub, and the first version of this test did
    # exactly that, which is why it could not resolve a row.
    require Lazysite::Data::Tables;
    no warnings 'redefine';
    local *Lazysite::Data::Tables::load_table = sub { { ok => 1, table => { key => 'id' } } };
    local *Lazysite::Data::Tables::read_rows = sub {
        return { ok => 1, rows => [ {
                    id       => 41,
                    customer => 'Ada',
                    total    => '99.00',
                    # The column nobody mapped. Added to the table last week; it must
                    # not start leaving the site because it exists.
                    internal_note => 'do not send this',
        } ] };
    };

    my ( $payload, $why ) = Lazysite::Manager::Connectors::row_payload(
        $c, 41, as => 'sysop', actor => 'op', groups => [] );
    # Nothing below this line means anything if the payload is undef: an
    # `exists` on undef answers false and every absence check passes for the
    # wrong reason.
    ok( $payload, 'the row resolves to a payload' ) or do { diag $why; return };
    is_deeply( $payload, { name => 'Ada', amount => '99.00' },
        'ONLY the mapped columns, under the names the remote expects' );
    ok( !exists $payload->{internal_note},
        'an unmapped column is not sent - a table gaining a field does not widen what leaves' );
    ok( !exists $payload->{id}, 'and neither is the key, which was not mapped either' );
};

subtest 'a connector with no row source says so rather than sending nothing' => sub {
    save( 'plain', url => 'https://example.test/x' );
    my $all = Lazysite::Manager::Connectors::connectors();
    my ( $p, $why ) = Lazysite::Manager::Connectors::row_payload( $all->{plain}, 1, as => 'sysop' );
    ok( !$p, 'refused' );
    like( $why, qr/row_table/, 'and names what the connector is missing' );
};

# SM842: THE SCHEDULE IS NOT THE CONNECTOR'S ANY MORE. A connector on a timer
# is a schedule entry calling a connector handler (t/unit/lib/34 and
# t/unit/daemon/05); here, the connector refuses the old keys BY NAME, because
# a caller that sends them expects them to do something.
subtest 'a connector refuses the schedule keys it no longer owns' => sub {
    for my $k (qw(schedule_every schedule_payload)) {
        my $r = save( 'sched', url => 'https://example.test/x', modes => { scheduled => 1 },
            $k => ( $k eq 'schedule_every' ? 900 : { report => 'daily' } ) );
        ok( !$r->{ok}, "$k is refused" );
        like( $r->{error}, qr/\Q$k\E is not a connector setting any more.*schedules call handlers/,
            'and the refusal says where the schedule lives now' );
    }
    ok( !Lazysite::Manager::Connectors->can('due_scheduled'),
        'the connector-only timer is gone - no second due-ness to disagree with the schedule' );
    my $ok = save( 'sched', url => 'https://example.test/x', modes => { scheduled => 1 } );
    ok( $ok->{ok}, 'a connector that PERMITS scheduled invocation is saved without them' );
};

# The declaration is the gate, and it is one gate for all three modes.
subtest 'scheduled-only refuses a request-time invocation' => sub {
    save( 'timeronly', url => 'https://example.test/x',
        modes          => { scheduled => 1, authenticated => 0, public => 0 } );
    my $all = Lazysite::Manager::Connectors::connectors();
    my ( $may, $why )
        = Lazysite::Manager::Connectors::may_call( $all->{timeronly}, mode => 'authenticated',
        caps => { manage_connectors => 1 }, groups => [] );
    is( $may, 0, 'even manage_connectors cannot invoke a scheduled-only connector by request' );
    like( $why, qr/does not permit authenticated/, 'and is told which mode it declared' );

    my ($ok2) = Lazysite::Manager::Connectors::may_call( $all->{timeronly}, mode => 'scheduled' );
    is( $ok2, 1, 'while the timer may' );
};

done_testing;
