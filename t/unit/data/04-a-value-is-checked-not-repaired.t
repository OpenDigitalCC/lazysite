#!/usr/bin/perl
# SM447: the write-side validation layer.
#
# SQLite.pm's header promises that values are bound, always - so a value
# containing SQL metacharacters is stored verbatim because it never reaches the
# parser as syntax. Binding makes a value SAFE and does nothing to make it
# CORRECT. This is where it becomes correct.
#
# THE PROMISES BEING KEPT are the ones the adapter makes in comments and
# deliberately does not implement in DDL, because DDL would put each engine's
# dialect in charge of a decision that must not vary between them:
#
#   decimal -> canonical string, never a float
#   boolean -> normalised 0/1
#   date    -> calendar-checked
#   enum    -> membership
#   default -> applied when a write OMITS the field
#
# REJECT, DO NOT REPAIR is asserted directly, because it is the decision most
# likely to be "helpfully" reversed later. 12.345 into places=2 is REFUSED
# rather than rounded: a store that silently rounds money is worse than one
# that will not take it, since the caller learns nothing and the difference
# surfaces later as an unexplained discrepancy in a total.
use strict;
use warnings;
use Test::More;
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use Lazysite::Data::Descriptor qw(load_descriptor);
use Lazysite::Data::Value qw(coerce_row coerce_field);

my $d = load_descriptor(
    'orders',
    {   key    => 'ref',
        fields => {
            ref      => { type => 'text', required => 1, max => 20 },
            note     => { type => 'text' },
            qty      => { type => 'integer', min => 1, max => 999 },
            total    => { type => 'decimal', digits => 8, places => 2 },
            paid     => { type => 'boolean', default => 0 },
            due      => { type => 'date' },
            seen_at  => { type => 'datetime' },
            state    => { type => 'enum', values => [qw(new sent done)],
                default => 'new' },
        },
    }
);
ok( $d->{ok}, 'the fixture descriptor loads' ) or BAIL_OUT( $d->{error} );

sub ok_row { my $r = coerce_row( $d, $_[0] ); return $r->{ok} ? $r->{values} : undef }
sub why    { my $r = coerce_row( $d, $_[0] ); return $r->{ok} ? undef : $r }

# --- the invariant this layer exists beside --------------------------------
subtest 'a value carrying SQL is stored verbatim, not escaped or refused' => sub {
    my $nasty = q{Robert'); DROP TABLE orders;--};
    my $v = ok_row( { ref => 'A1', note => $nasty } );
    is( $v->{note}, $nasty, 'the value survives byte for byte' )
        or diag( 'Escaping here would be the wrong repair in the wrong place: '
            . 'values are BOUND, so the text is data. A layer that mangled it '
            . 'would corrupt legitimate content to defend against a problem '
            . 'that does not exist at this point.' );
};

# --- reject, do not repair -------------------------------------------------
subtest 'money is refused rather than rounded' => sub {
    my $e = why( { ref => 'A1', total => '12.345' } );
    ok( $e, '12.345 into places=2 is refused' )
        or diag( 'Rounding here loses money silently. The caller is told '
            . 'nothing and the difference appears later in a total nobody '
            . 'can reconcile.' );
    like( $e->{error}, qr/more than 2 decimal places/, 'and says why' );
    is( $e->{field}, 'total', 'naming the field' );

    is( ok_row( { ref => 'A1', total => '12.3' } )->{total}, '12.30',
        'a SHORT fraction is padded - that loses nothing' );
    is( ok_row( { ref => 'A1', total => '007.50' } )->{total}, '7.50',
        'and leading zeros are canonicalised' );
    ok( why( { ref => 'A1', total => '1234567.00' } ),
        'more digits than declared is refused too' );
    is( ok_row( { ref => 'A1', total => '-0.00' } )->{total}, '0.00',
        'negative zero collapses - two spellings of one value is a defect' );
    ok( why( { ref => 'A1', total => '1e3' } ), 'and it is not a float' );
};

subtest 'a date must be a real date' => sub {
    ok( why( { ref => 'A1', due => '2025-02-30' } ), '30 February is refused' )
        or diag( 'A date column that accepts this is a date column in name only.' );
    ok( why( { ref => 'A1', due => '2025-13-01' } ), 'month 13 is refused' );
    ok( ok_row( { ref => 'A1', due => '2024-02-29' } ), 'a real leap day passes' );
    ok( why( { ref => 'A1', due => '2025-02-29' } ),
        'and a leap day in a non-leap year does not' );
    ok( why( { ref => 'A1', due => '01/02/2025' } ), 'a local format is refused' );
};

subtest 'a datetime is normalised to one spelling' => sub {
    my $t = '2025-03-04T05:06:07Z';
    is( ok_row( { ref => 'A1', seen_at => '2025-03-04 05:06:07' } )->{seen_at},
        $t, 'a space separator and a missing Z are accepted and normalised' )
        or diag( 'These sort and filter as STRINGS, so two spellings of one '
            . 'instant make string order disagree with chronology.' );
    is( ok_row( { ref => 'A1', seen_at => $t } )->{seen_at}, $t, 'already-canonical is unchanged' );
    ok( why( { ref => 'A1', seen_at => '2025-03-04T25:00:00Z' } ), 'hour 25 is refused' );
};

subtest 'a boolean is normalised, from a FIXED set of spellings' => sub {
    is( ok_row( { ref => 'A1', paid => 'true' } )->{paid},  1, 'true' );
    is( ok_row( { ref => 'A1', paid => 'NO' } )->{paid},    0, 'NO, case-insensitively' );
    is( ok_row( { ref => 'A1', paid => '1' } )->{paid},     1, '1' );
    ok( why( { ref => 'A1', paid => 'on' } ), "'on' is refused" )
        or diag( 'A wider set would make the stored answer depend on which '
            . 'surface wrote the row.' );
};

subtest 'enum membership, and integer bounds' => sub {
    ok( why( { ref => 'A1', state => 'archived' } ), 'a value outside the list is refused' );
    ok( why( { ref => 'A1', qty   => 0 } ),          'below min is refused' );
    ok( why( { ref => 'A1', qty   => '3.5' } ),      'a fraction is not a whole number' );
    is( ok_row( { ref => 'A1', qty => '42' } )->{qty}, 42, 'and a good one passes through' );
};

# --- absence, defaults and partials ----------------------------------------
subtest 'defaults apply on a full write and NEVER on a partial one' => sub {
    my $full = ok_row( { ref => 'A1' } );
    is( $full->{paid},  0,     'a default fills an omitted field' );
    is( $full->{state}, 'new', 'including an enum default' );

    my $part = coerce_row( $d, { note => 'hi' }, partial => 1 );
    ok( $part->{ok}, 'a partial write needs neither key nor required fields' );
    ok( !exists $part->{values}{paid},
        'and an omitted field with a default is LEFT ALONE' )
        or diag( 'Applying it would silently rewrite a column the caller '
            . 'never mentioned, which is the one thing a partial update must '
            . 'not do.' );
};

subtest 'empty means absent, except for text' => sub {
    my $v = ok_row( { ref => 'A1', qty => '', note => '' } );
    ok( !defined $v->{qty}, 'a cleared number is NULL, not 0' )
        or diag( 'Storing 0 would be inventing data the operator did not enter.' );
    is( $v->{note}, '', 'a cleared text field keeps its empty string' );
    my $e = why( { ref => '' } );
    ok( $e && $e->{rule} eq 'required', 'and a required field left blank is refused' );
};

# --- what must not be writable ---------------------------------------------
subtest 'the plugin keeps what it owns' => sub {
    my $e = why( { ref => 'A1', created_at => '2025-01-01T00:00:00Z' } );
    ok( $e && $e->{rule} eq 'reserved', 'a timestamp column cannot be written' );

    my $u = why( { ref => 'A1', colour => 'red' } );
    ok( $u && $u->{rule} eq 'unknown', 'an unknown field is REFUSED, not ignored' )
        or diag( 'Ignoring it makes a typo in a column name look like a '
            . 'successful write: the operator is told "saved" and the value '
            . 'is not there.' );

    my $auto = load_descriptor( 'notes',
        { fields => { body => { type => 'text' } } } );
    ok( $auto->{ok} && $auto->{auto_key}, 'an auto-key descriptor loads' );
    my $r = coerce_row( $auto, { id => 5, body => 'x' } );
    ok( !$r->{ok} && $r->{rule} eq 'auto_key',
        'and a caller cannot choose its own row id' );
};

subtest 'a bad DEFAULT is caught, not trusted' => sub {
    # A descriptor default is author-written text with no more claim to being
    # well-formed than a form field has.
    my $bad = load_descriptor( 'x',
        { key => 'k',
          fields => { k => { type => 'text' },
                      n => { type => 'integer', default => 'lots' } } } );
    ok( $bad->{ok}, 'the descriptor itself loads' );
    my $r = coerce_row( $bad, { k => 'a' } );
    ok( !$r->{ok} && $r->{rule} eq 'default',
        'and the default is refused when it is applied' );
};

done_testing();
