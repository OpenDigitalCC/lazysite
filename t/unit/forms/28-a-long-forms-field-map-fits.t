#!/usr/bin/perl
# SM923 limit 2: a 31-field form could not reach a data table without mangling its
# column names.
#
# The table handler's field map is a comma-separated list of `field=column` pairs
# and was capped at 500 characters, the generic bound every handler conf value
# carries. At 31 fields that is about SIXTEEN CHARACTERS PER PAIR, so an operator
# building a long form had to abbreviate the column names until they stopped
# matching the field names on their own form - and then hold the mapping in their
# head when reading the table later.
#
# RULED 2026-10-01, AMENDING THE RULING OF 2026-09-30 ON MEASUREMENT. The first
# ruling was to default the map to IDENTITY, which makes it optional. Measuring what
# reaches a handler showed why that cannot be: `_visible_fields` strips only
# `_`-prefixed keys, so every other key a VISITOR posts arrives at the handler -
# including keys the form never declared. The map is what drops them. Under an
# identity default, a posted key matching any column of the bound table would write
# it, and the table's own column set would be the only limit. So the map stays
# REQUIRED - its schema note says in those words that it is what keeps a visitor
# from choosing where their data goes, and that is literally true - and the CAP is
# what gives way.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Handlers ();

# A 31-field map with names of the length a real form uses. This is the shape that
# produced the report: the live business diagnostic had 31 fields.
my @FIELDS = qw(
    name role org website country sector employees annual_turnover
    growth_target biggest_constraint current_systems data_location
    backup_approach security_posture compliance_needs team_capability
    budget_range decision_timeline previous_projects success_measure
    existing_suppliers integration_needs reporting_needs training_needs
    support_expectation contract_preference start_date other_notes
    phone email best_time_to_call
);
is( scalar @FIELDS, 31, 'the fixture is the size of the form that was reported' );

my $map = join ', ', map { "$_=$_" } @FIELDS;
cmp_ok( length $map, '>', 500,
    'and its identity map is longer than the old cap (' . length($map) . ' characters)' );

sub handler {
    my (%over) = @_;
    return {
        id     => 'table-one',
        type   => 'table',
        name   => 'To the table',
        table  => 'enquiries',
        fields => $map,
        %over,
    };
}

subtest 'a long map is accepted' => sub {
    my ( $clean, $why, $field ) = Lazysite::Handlers::validate_handler( handler() );
    ok( $clean, 'the handler validates' ) or diag "refused: $why (field $field)";
    is( $clean->{fields}, $map, 'and the map is stored whole, not truncated' );

    my ( $parsed, $pwhy ) = Lazysite::Handlers::parse_fields( $clean->{fields} );
    ok( $parsed, 'it parses' ) or diag $pwhy;
    is( scalar keys %$parsed, 31, 'all 31 pairs survive' );
    is( $parsed->{annual_turnover}, 'annual_turnover',
        'and a column name can match its field name, which is the whole complaint' );
};

subtest 'the bound is still a bound' => sub {
    my $far_too_long = join ', ', map { "field_number_$_=column_number_$_" } ( 1 .. 200 );
    cmp_ok( length $far_too_long, '>', 4000, 'the fixture exceeds the new bound' );
    my ( $clean, $why, $field ) = Lazysite::Handlers::validate_handler(
        handler( fields => $far_too_long ) );
    ok( !$clean, 'it is refused' );
    is( $field, 'fields', 'naming the field it is about' );
    like( $why, qr/4000/,
        'and the limit it broke - the message carried the generic 500 before this, '
            . 'so a refusal named a number that was not the one being applied' );
};

subtest 'every other conf value keeps the generic 500' => sub {
    # The cap is per field now, and raising one of them must not raise them all: 500
    # is a sensible bound for a path, an address or a table name.
    my $long_name = 'x' x 501;
    my ( $clean, $why, $field ) = Lazysite::Handlers::validate_handler(
        {   id   => 'file-one', type => 'file', name => 'Keep a copy',
            path => $long_name,
        } );
    ok( !$clean, 'a 501-character path is refused' );
    like( $why, qr/500/, 'at 500 characters' ) or diag "why: $why";
};

subtest 'the map is still REQUIRED, which is the measured reason' => sub {
    # THE DECLARATION, not only the behaviour. A sabotage pass removed
    # `required => 1` from the schema and this file still passed, because
    # parse_fields refuses an empty map on its own - defence in depth, and a gate
    # that cannot tell the two apart would let the declaration go quietly while the
    # Handlers page stopped marking the field as required.
    my ($table) = grep { $_->{type} eq 'table' } @{ Lazysite::Handlers::types() };
    ok( $table, 'the table handler type is published' );
    my ($fields_def) = grep { $_->{key} eq 'fields' } @{ $table->{schema} };
    ok( $fields_def, 'with a fields entry' );
    ok( $fields_def->{required},
        'DECLARED required - the surfaces read this to mark the input, and the map '
            . 'is the only thing between a posted key and a column' );
    is( $fields_def->{max_len}, 4000, 'and carrying its own bound' );

    my ( $clean, $why, $field )
        = Lazysite::Handlers::validate_handler( handler( fields => '' ) );
    ok( !$clean, 'a table handler with no map is refused' );
    is( $field, 'fields', 'naming the map' );

    # And the reason, stated as behaviour rather than as a comment: a key the form
    # never declared reaches the handler, and only the map's absence from it drops
    # that key. This is the assertion that would fail if someone made the map
    # optional later without re-opening the question.
    my ( $parsed ) = Lazysite::Handlers::parse_fields('name=full_name, message=body');
    ok( $parsed, 'a two-pair map parses' );
    ok( !exists $parsed->{status},
        'a posted key the map does not name is not in it - so it reaches no column, '
            . 'which is what the map is FOR' );
};

done_testing();
