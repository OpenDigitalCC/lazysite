#!/usr/bin/perl
# SM677: every row save wrote an audit line, and on a big table that is the log.
#
# THIS REVERSES NOTHING BY DEFAULT. SM505 and SM465 each decided deliberately
# that a row action's entry carries the row KEY - "someone edited that table" is
# half an answer when the question the trail gets asked is which row. That
# remains the behaviour of every table that says nothing.
#
# What the switch adds is a decision the engine cannot make: whether THIS table
# is one where the volume outweighs the detail. The operator who has a
# thousand-row table is the one who knows, so it lives in the descriptor.
#
# Corroborated from the other side: the apps agent independently found the same
# per-row loop is slow and that bulk work belongs in data-import - which already
# audits once. The volume comes from loops, and this is the valve for an app
# that legitimately writes rows one at a time.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../lib";
use TestHelper qw(repo_root);

require Lazysite::Data::Descriptor;

sub parsed {
    my ($extra) = @_;
    my $raw = {
        key    => 'code',
        fields => { code => { type => 'text' } },
        ( $extra ? %{$extra} : () ),
    };
    return Lazysite::Data::Descriptor::load_descriptor( 'notes', $raw );
}

subtest 'the default is unchanged - a table audits its rows' => sub {
    my $d = parsed();
    ok( $d->{ok}, 'a plain descriptor loads' ) or diag( $d->{error} // '' );
    is( $d->{audit_rows}, 1, 'and audits row writes' )
        or diag( 'SM505 and SM465 both decided the row key belongs in the '
            . 'trail. A table that says nothing must keep it.' );
};

subtest 'an explicit off turns it off' => sub {
    for my $v (qw(off false 0)) {
        my $d = parsed( { audit_rows => $v } );
        is( $d->{audit_rows}, 0, "audit_rows: $v switches it off" );
    }
};

subtest 'anything else leaves it ON' => sub {
    # THE FAILURE THIS MUST NOT HAVE is a descriptor that silently stops
    # recording who changed what. A typo, a stray value, a `true` - all audit.
    for my $v ( 'no', 'nope', 'yes', 'true', '1', 'OFFF', ' off' ) {
        my $d = parsed( { audit_rows => $v } );
        is( $d->{audit_rows}, 1, "audit_rows: '$v' is NOT an off switch" )
            or diag( 'Defaulting the other way would make a misspelling into a '
                . 'quiet loss of the audit trail.' );
    }
};

subtest 'the table-level events are not affected' => sub {
    # An operator quietening a noisy table must not thereby silence the events
    # that matter most - a restructure, a drop, a bulk load.
    my $api = do {
        open my $fh, '<', repo_root() . '/lazysite-manager-api.pl' or die $!;
        local $/;
        <$fh>;
    };
    my ($block) = $api =~ /if \( \$ok && \$aud_action =~ \/\^data-row-\/ \) \{(.*?)\n        \}/s;
    ok( defined $block, 'the skip is scoped to row actions' ) or return;
    like( $block, qr/_table_audits_rows/, 'and consults the table' );

    # The guard is on data-row- specifically, so data-table-save, data-migrate,
    # data-table-drop and data-import each remain one audited event.
    unlike( $block, qr/data-table-save|data-import|data-migrate/,
        'and reaches no table-level verb' )
        or diag( 'Silencing a restructure or a bulk load is not what this '
            . 'switch is for.' );
};

subtest 'an unreadable descriptor still audits' => sub {
    my $api = do {
        open my $fh, '<', repo_root() . '/lazysite-manager-api.pl' or die $!;
        local $/;
        <$fh>;
    };
    my ($fn) = $api =~ /sub _table_audits_rows \{(.*?)\n\}/s;
    ok( defined $fn, '_table_audits_rows is present' ) or return;
    like( $fn, qr/return 1 unless ref \$d eq 'HASH' && \$d->\{ok\}/,
        'a descriptor that will not load audits anyway' )
        or diag( 'Losing the trail must never be the failure mode of a missing '
            . 'or broken file.' );
};

done_testing();
