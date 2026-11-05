package Odoo::Ops::Core::OneRecord;

use strict;
use warnings;
use feature qw(signatures);
no warnings qw(experimental::signatures experimental::builtin);

use Encode ();
use JSON::PP ();
use Odoo::JSON ();

use Scalar::Util qw(blessed);

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
    the field is one2many (core.make takes lines.<field>), or reference, json or properties (not typed here)
    a many2many value that is not a list, names no record or names several
    the field is binary and the value is text (a binary field takes a file)
    the text is not a value of the field's type

Types: integer and many2one_reference (a whole number), float and monetary (a number), boolean (C<1 0 true false yes no>),
date (C<YYYY-MM-DD>), datetime (C<YYYY-MM-DD HH:MM:SS>), selection (the key),
many2one (an id, or false for empty), many2many (a list, see many2many), char, text, and html (plain text is made into paragraphs;
text that starts with a tag is kept as written). An empty value clears a
char, text, html, date, datetime, selection or many2one; for a number or a
boolean it is refused.

=cut

my %TYPED = map { $_ => 1 } qw(integer many2one_reference float monetary boolean date datetime selection many2one char text html);

sub typed_values ($class, $op, $model, $fields, $set, %o) {
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
        if ( $type eq 'many2many' ) {
            $vals{$f} = $class->many2many( $op, $model, $f, $d, $set->{$f}, $o{resolver} );
            next;
        }
        Odoo::Error->throw( kind => 'usage',
            message => "$op: $model.$f is a $type field; one record's $type fields are not set here",
            fix => $type eq 'one2many'
                ? ( $op eq 'core.make' ? "give the lines with lines.$f, or load them with core.import" : 'core.import loads a one2many field' )
                : "core.import or core.action reaches a $type field" ) if !$TYPED{$type};
        my ( $ok, $v ) = $class->coerce( $d, $set->{$f} );
        Odoo::Error->throw( kind => 'usage', message => "$op: $model.$f: $v",
            fix => "give $f as " . $class->shape($d) ) if !$ok;
        $vals{$f} = $v;
    }
    return \%vals;
}

=head2 many2many($op, $model, $field, \%field, $text, $resolver)

The replace command Odoo takes for a many2many field, C<< [[6, 0, \@ids]] >>, from
the text of a C<set.> value: a JSON list (C<[3,4]> ids, C<["Sales","HR"]> names, a
JSON number is an id and a JSON string a name) or plain text split on C<;> or C<,>
(a whole number is an id, anything else a name). An empty text, C<[]> and C<false> mean
none: the field is cleared. A name is looked up in the comodel by its C<name>, without
case, as C<core.import> looks a many2many name up (L<Odoo::Ops::Core::Import/lookup>);
C<$resolver> is C<< sub ($relation, $name) >> returning that answer. A name no record
has, or several records have, is a usage error naming it (and the ids, for several).

=cut

sub many2many ($class, $op, $model, $f, $d, $text, $resolver) {
    my $t = $text =~ s/\A\s+|\s+\z//gr;
    my @items;    # [ kind, value ]: id or name
    if ( $t eq '' || $t eq 'false' ) { }
    elsif ( $t =~ /\A\[/ ) {
        my $list = eval { Odoo::JSON->new->decode( Encode::encode( 'UTF-8', $t ) ) };
        Odoo::Error->throw( kind => 'usage', message => "$op: $model.$f: '$t' is not a JSON list",
            fix => "give $f as a list of ids [3,4] or of names [\"Sales\",\"HR\"], or as ids and names split by commas" ) if ref $list ne 'ARRAY';
        for my $i (@$list) {
            Odoo::Error->throw( kind => 'usage', message => "$op: $model.$f: a list item must be an id or a name, not " . ( ref $i ? 'a ' . lc( ref $i ) : 'empty' ),
                fix => "give $f as a list of ids [3,4] or of names" ) if ref $i || !defined $i;
            push @items, builtin::created_as_number($i) ? [ id => 0 + $i ] : [ name => "$i" ];
        }
    }
    else {
        for my $i ( split /\s*[;,]\s*/, $t ) {
            next if $i eq '';
            push @items, $i =~ /\A\d+\z/ ? [ id => 0 + $i ] : [ name => $i ];
        }
    }
    my ( @ids, %seen );
    for my $it (@items) {
        my ( $kind, $v ) = @$it;
        my $id = $v;
        if ( $kind eq 'name' ) {
            Odoo::Error->throw( kind => 'usage', message => "$op: $model.$f: names are looked up in " . ( $d->{relation} // 'the related model' ) . ', which is not known here',
                fix => 'give ids' ) if !$resolver;
            my $r = $resolver->( $d->{relation}, $v );
            Odoo::Error->throw( kind => 'usage', message => "$op: $model.$f: no $d->{relation} is named '$v'",
                fix => 'give the id of the record, or a name it has' ) if !defined $r;
            Odoo::Error->throw( kind => 'usage', message => "$op: $model.$f: '$v' names $d->{relation} " . join( ', ', @{ $r->{ambiguous} } ),
                fix => 'give the id of the one meant' ) if ref $r eq 'HASH';
            $id = $r;
        }
        Odoo::Error->throw( kind => 'usage', message => "$op: $model.$f: an id must be a whole number above 0, got $v",
            fix => "give $f as ids [3,4] or names" ) if $id < 1;
        push @ids, $id if !$seen{$id}++;
    }
    return [ [ 6, 0, \@ids ] ];
}

=head2 refused_or_missing($op, $model_object, $model, $id)

Called when a search by id came back empty. A search hides a record the user's rules
do not show as it hides one that does not exist, so the id is read: when Odoo refuses
the read, the answer is C<refused/access> carrying Odoo's own text and the model and
id; when Odoo says the record is gone, or answers no row, it returns (the record does
not exist and the caller says so). Any other fault is thrown as it came.

=cut

sub refused_or_missing ($class, $op, $m, $model, $id) {
    # display_name, not id: a read of id alone is answered without touching the record
    my $rows = eval { $m->read( [$id], ['display_name'] ) };
    my $err  = $@;
    return if !$err;
    die $err if !blessed($err) || !$err->isa('Odoo::Error');
    my $cat = $err->fault_category // '';
    return if $cat eq 'missing';
    die $err if $cat ne 'access';
    my $why = $err->message =~ s/\s+\z//r =~ s/\s*\n\s*/ /gr;
    Odoo::Error->throw( kind => 'refused', code => 'access',
        message => "$op: Odoo refuses to show $model $id to this login: $why",
        fix => 'the record exists but this login may not read it; ask for a login that may, or for the right to be given' );
}

=head2 coerce(\%field, $text)

C<(1, $value)> in the field's terms, or C<(0, $why)>.

=cut

sub coerce ($class, $d, $v) {
    my $type = $d->{type};
    $type = 'integer' if $type eq 'many2one_reference';    # a number on the wire, on every series
    # false says empty for a many2one, as an empty value does (it is never the id 0)
    return ( 1, JSON::PP::false ) if $type eq 'many2one' && $v =~ /\A\s*false\s*\z/;
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

sub shown ($class, $v, $type = undef) {
    if ( ( $type // '' ) eq 'many2many' ) {
        # the before-image is a list of ids, the new value a replace command
        my @ids = ref $v eq 'ARRAY' ? ( @$v && ref $v->[0] eq 'ARRAY' ? @{ $v->[0][2] // [] } : @$v ) : ();
        return '[' . join( ', ', sort { $a <=> $b } grep { !ref } @ids ) . ']';
    }
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
