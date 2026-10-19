package Odoo::Ops::Core::OneRecord;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();
use Odoo::JSON ();

use Odoo::Error;
use Odoo::Portable;
use Odoo::Ops::Core::Import;
use Odoo::Ops::File;

=head1 NAME

Odoo::Ops::Core::OneRecord - what C<core.get>, C<core.set> and C<core.make> share

=head1 DESCRIPTION

The three one-record operations take only strings, integers and booleans, so
a lazysite binding can feed them from a request. This module holds the parts
they have in common: the C<set.E<lt>fieldE<gt>> parameters (named by the
field, typed from C<fields_get>), the typing of a value, and the row and
schema a read returns. It is not an operation.

=head2 set_params(\%raw)

The C<set.E<lt>fieldE<gt>> entries of a raw parameter hash, as C<< field => text >>;
an entry with no field name, or a value that is not text, is a usage error. The
value for a binary field is a file value (C<< { name, bytes, mimetype? } >>, see
L<Odoo::Ops::File>), checked as a file parameter is: it stays a hash.

=cut

sub set_params ($class, $op, $raw) {
    my %set;
    for my $k ( sort grep { /\Aset\./ } keys %$raw ) {
        my $f = substr $k, 4;
        Odoo::Error->throw( kind => 'usage', message => "$op: parameter '$k' names no field",
            fix => "give set.<field>=<value>, e.g. --set set.name=Acme" ) if $f !~ /\A\w+\z/;
        my $v = $raw->{$k};
        if ( ref $v eq 'HASH' ) {
            $set{$f} = Odoo::Ops::File->check( $op, $k, $v );
            next;
        }
        Odoo::Error->throw( kind => 'usage', message => "$op: parameter '$k' must be one text value",
            fix => "oom-ops describe $op shows each parameter's type" ) if !defined $v || ref $v;
        $set{$f} = "$v";
    }
    return \%set;
}

=head2 typed_values($op, $model, \%fields, \%set)

The values to write, typed and checked against C<fields_get>. A file value is
for a binary field and stays the file value; the operation holds its bytes in
the plan's blob store. A usage error names
the field and carries a fix line:

    the model has no such field
    the field is one2many or many2many (a later piece), or reference, json or properties (not typed here)
    the field is binary and the value is text (a binary field takes a file)
    the text is not a value of the field's type

Types: integer and many2one_reference (a whole number), float and monetary (a number), boolean (C<1 0 true false yes no>),
date (C<YYYY-MM-DD>), datetime (C<YYYY-MM-DD HH:MM:SS>), selection (the key),
many2one (an id), char, text, and html (plain text is made into paragraphs;
text that starts with a tag is kept as written). An empty value clears a
char, text, html, date, datetime, selection or many2one; for a number or a
boolean it is refused.

=cut

my %TYPED = map { $_ => 1 } qw(integer many2one_reference float monetary boolean date datetime selection many2one char text html);

sub typed_values ($class, $op, $model, $fields, $set) {
    my %vals;
    for my $f ( sort keys %$set ) {
        my $d = $fields->{$f};
        Odoo::Error->throw( kind => 'usage', message => "$op: $model has no field '$f'",
            fix => "oom-ops run core.skeleton --conf <conf> --set model=$model lists the stored, writable fields" ) if !$d;
        my $type = $d->{type} // '';
        if ( ref $set->{$f} eq 'HASH' ) {
            Odoo::Error->throw( kind => 'usage', message => "$op: $model.$f is a $type field; a file is for a binary field",
                fix => "give set.$f as text of its type" ) if $type ne 'binary';
            $vals{$f} = $set->{$f};
            next;
        }
        Odoo::Error->throw( kind => 'usage', message => "$op: $model.$f is a binary field; give it a file, not text",
            fix => "pass --file set.$f=PATH on the command line, or a { name, bytes } value in a program" ) if $type eq 'binary';
        Odoo::Error->throw( kind => 'usage',
            message => "$op: $model.$f is a $type field; one record's $type fields are not set here",
            fix => $type =~ /^(?:one2many|many2many)\z/
                ? 'a later piece of OOM sets x2many fields; core.import loads them today'
                : "core.import or core.action reaches a $type field" ) if !$TYPED{$type};
        my ( $ok, $v ) = $class->coerce( $d, $set->{$f} );
        Odoo::Error->throw( kind => 'usage', message => "$op: $model.$f: $v",
            fix => "give $f as " . $class->shape($d) ) if !$ok;
        $vals{$f} = $v;
    }
    return \%vals;
}

=head2 coerce(\%field, $text)

C<(1, $value)> in the field's terms, or C<(0, $why)>.

=cut

sub coerce ($class, $d, $v) {
    my $type = $d->{type};
    $type = 'integer' if $type eq 'many2one_reference';    # a number on the wire, on every series
    if ( $v =~ /\A\s*\z/ ) {
        return ( 1, JSON::PP::false ) if $type =~ /\A(?:char|text|html|date|datetime|selection|many2one)\z/;
        return ( 0, "an empty value is not a $type value" );
    }
    if ( $type eq 'many2one' ) {
        return $v =~ /\A\s*(\d+)\s*\z/ ? ( 1, 0 + $1 ) : ( 0, "'$v' is not an id (a whole number)" );
    }
    if ( $type eq 'selection' ) {
        for my $pair ( @{ $d->{selection} // [] } ) { return ( 1, $pair->[0] ) if "$pair->[0]" eq $v }
        return ( 0, "'$v' is not one of " . join( ', ', map { $_->[0] } @{ $d->{selection} // [] } ) );
    }
    if ( $type eq 'char' || $type eq 'text' ) { return ( 1, "$v" ) }
    if ( $type eq 'html' ) { return ( 1, Odoo::Ops::Core::Import::_to_html($v) ) }
    if ( $type eq 'integer' ) {
        return $v =~ /\A\s*-?\d+\s*\z/ ? ( 1, 0 + $v ) : ( 0, "'$v' is not an integer" );
    }
    if ( $type eq 'float' || $type eq 'monetary' ) {
        my $n = $v =~ s/^\s+|\s+\z//gr;
        return $n =~ /\A-?(?:\d+\.?\d*|\.\d+)\z/ ? ( 1, 0 + $n ) : ( 0, "'$v' is not a number" );
    }
    # boolean, date, datetime: the import's own reading
    return Odoo::Ops::Core::Import::_coerce( $d, $v );
}

=head2 shape(\%field)

How a value of the field is written, for a fix line.

=cut

sub shape ($class, $d) {
    my $t = $d->{type} // '';
    return {
        integer => 'a whole number', many2one_reference => 'a whole number (the id)', float => 'a number', monetary => 'a number', boolean => 'true or false',
        date => 'YYYY-MM-DD', datetime => 'YYYY-MM-DD HH:MM:SS', many2one => 'the id of the record it points at',
        selection => 'one of ' . join( ', ', map { $_->[0] } @{ $d->{selection} // [] } ),
    }->{$t} // 'text';
}

=head2 state_hold($ctx, $model, \%vals)

The reason to hold when the values set a state field of a model whose
behaviour file says Odoo changes its state through its own actions, or undef.

=cut

sub state_hold ($class, $ctx, $model, $vals) {
    my $beh  = $ctx->behaviour($model);
    my $rule = $beh->state_rule or return undef;
    my ($sf) = grep { exists $vals->{$_} } $beh->state_fields or return undef;
    my @ops = @{ $rule->{operations} // [] };
    return "$model $sf is changed through Odoo's own action, never written"
        . ( @ops ? ': ' . join( ', ', map { "oom-ops run $_" } @ops ) : '' ) . "; take set.$sf out";
}

=head2 shown($value)

A value as a plan line shows it: short, ids for a many2one, C<false> for empty.

=cut

sub shown ($class, $v) {
    return 'false' if !defined $v || ( !ref $v && $v eq '' ) || Odoo::Portable::is_false_value($v);
    if ( ref $v eq 'ARRAY' ) { return @$v == 2 && !ref $v->[0] ? $v->[0] : '[' . join( ', ', grep { !ref } @$v ) . ']' }
    return ( $v ? 'true' : 'false' ) if Odoo::JSON::is_bool($v);
    my $t = "$v" =~ s/\s+/ /gr;
    return length $t > 40 ? q(') . substr( $t, 0, 37 ) . q(...') : ( $t =~ /\A-?\d+(?:\.\d+)?\z/ ? $t : "'$t'" );
}

=head2 schema_entry(\%field)

The read-side schema entry of a field: type, portable type, label, relation,
selection values. A many2one's id is C<integer>.

=cut

sub schema_entry ($class, $d) {
    my %pt = Odoo::Portable::describe($d);
    $pt{portable_type} = 'integer' if ( $d->{type} // '' ) eq 'many2one';    # the id sits under the field's name
    return {
        type => $d->{type}, string => $d->{string},
        ( $pt{portable_type} ? ( portable_type => $pt{portable_type} ) : () ),
        ( $d->{relation} ? ( relation => $d->{relation} ) : () ),
        ( $pt{values} ? ( values => $pt{values} )
          : ref $d->{selection} eq 'ARRAY' ? ( values => [ map { $_->[0] } @{ $d->{selection} } ] ) : () ),
    };
}

=head2 rows_and_schema(\%fields, \@want, \@rows)

Rows with each many2one as its id under the field and its label under
C<E<lt>fieldE<gt>_name> (both null when empty), and the schema of the fields
asked. The label is C<portable_type: text>.

=cut

sub rows_and_schema ($class, $f, $want, $rows) {
    my @out;
    for my $r (@$rows) {
        my %o;
        for my $k (@$want) {
            my $v = $r->{$k};
            if ( ( $f->{$k}{type} // '' ) eq 'many2one' ) {
                if ( ref $v eq 'ARRAY' ) { @o{ $k, "${k}_name" } = @$v }
                else                      { @o{ $k, "${k}_name" } = ( undef, undef ) }
            }
            else { $o{$k} = $v }
        }
        push @out, \%o;
    }
    my %schema;
    for my $k (@$want) {
        my $d = $f->{$k};
        $schema{$k} = $class->schema_entry($d);
        $schema{"${k}_name"} = { type => 'char', string => ( $d->{string} // $k ) . ' (label)', portable_type => 'text' }
            if ( $d->{type} // '' ) eq 'many2one';
    }
    return ( \@out, \%schema );
}

1;
