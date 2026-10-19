package Odoo::Ops::Invariant;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;
use Odoo::Ops::Registry;

=head1 NAME

Odoo::Ops::Invariant - what must hold around an apply, from the behaviour files

=head1 SYNOPSIS

    my @inv  = Odoo::Ops::Invariant->for_plan( $ctx, $plan );
    my $before = Odoo::Ops::Invariant->measure_all( $client, \@inv );
    ... apply ...
    my $after  = Odoo::Ops::Invariant->measure_all( $client, \@inv );
    my @rows   = Odoo::Ops::Invariant->judge( \@inv, $before, $after );

=head1 DESCRIPTION

A behaviour file (L<Odoo::Ops::Behaviour>) may declare invariants:

    invariants:
      - name: probability-manual
        text: no open lead's probability equals its automated score
        check: count                    # count (default) or sum
        model: crm.lead
        domain: [["active","=",true],["probability","=",{"field":"automated_probability"}]]
        expect: 0                       # a number, or "unchanged"

      - name: lot-totals-internal
        text: the total of each product and lot over internal locations is unchanged
        check: sum
        model: stock.quant
        domain: [["location_id.usage","=","internal"]]
        field: quantity
        group_by: [product_id, lot_id]
        expect: unchanged

A C<count> is the number of records the domain finds; C<expect> is a
number the count must equal after the apply, or C<unchanged> (the
count after equals the count before). A C<sum> is the total of
C<field> per C<group_by> value; it can only be C<unchanged>, because
the point of it is the before/after comparison (a stock move shifts a
quantity from one place to another and must change no lot's total).

Domains are plain Odoo domains with one extension: a right-hand value
C<< {"field": "other"} >> compares two fields of the record. Odoo's
domain language cannot do that, so such terms are taken out of the
domain, the rest is searched, and the comparison is made here on the
rows read. The extension is allowed only on terms joined by the
implicit AND (no prefix C<|> or C<!> in the domain).

Records are read with C<search_read> and totalled here, so the check
is the same on every series (C<read_group> changed its shape in 17).
On a large model the read is large; name a domain that narrows it.

Which invariants an apply checks: those of every model the plan
writes - the C<model> of each change, plus, for a C<custom> change,
the models its handler names in C<models_touched> - that apply to the
operation. An invariant with a C<pack> (C<pack: crm>) is a rule of that
pack and judges only writes made by an operation of the pack (an
operation's C<pack>, or the packs its C<invariant_packs> names, see
L<Odoo::Ops::Operation>); a plain C<core.make> of a lead is not judged
by it. An invariant with no C<pack> judges every write to its model.

=cut

my %COMPARE = (
    '='  => sub { _num( $_[0], $_[1] ) ? abs( $_[0] - $_[1] ) < 0.005 : ( $_[0] // '' ) eq ( $_[1] // '' ) },
    '!=' => sub { _num( $_[0], $_[1] ) ? abs( $_[0] - $_[1] ) >= 0.005 : ( $_[0] // '' ) ne ( $_[1] // '' ) },
    '<'  => sub { ( $_[0] // 0 ) < ( $_[1] // 0 ) - 0.005 },
    '>'  => sub { ( $_[0] // 0 ) > ( $_[1] // 0 ) + 0.005 },
    '<=' => sub { ( $_[0] // 0 ) <= ( $_[1] // 0 ) + 0.005 },
    '>=' => sub { ( $_[0] // 0 ) >= ( $_[1] // 0 ) - 0.005 },
);

sub _num ( @v ) { !grep { !defined || ref || !/^-?\d+(?:\.\d+)?\z/ } @v }

=head2 check_definition($path, \%inv)

Class method used by the behaviour loader: refuses a malformed
invariant by name.

=cut

sub check_definition ($class, $path, $i) {
    my $bad = sub ($why) {
        Odoo::Error->throw( kind => 'config', message => "behaviour $path: invariant '" . ( $i->{name} // '?' ) . "' $why" );
    };
    $bad->('needs a name') if !defined $i->{name} || $i->{name} eq '';
    $bad->('needs a model') if !$i->{model};
    my $check = $i->{check} // 'count';
    $bad->("has check '$check'; use count or sum") if $check ne 'count' && $check ne 'sum';
    $bad->('has a pack that is not a name') if defined $i->{pack} && ( ref $i->{pack} || $i->{pack} !~ /\A\w+\z/ );
    $bad->('needs expect') if !defined $i->{expect};
    $bad->('has a domain that is not a list') if exists $i->{domain} && ref $i->{domain} ne 'ARRAY';
    if ( $check eq 'count' ) {
        $bad->("has expect '$i->{expect}'; use a number or unchanged") if $i->{expect} ne 'unchanged' && $i->{expect} !~ /^\d+\z/;
    }
    else {
        $bad->('needs field') if !$i->{field};
        $bad->("has expect '$i->{expect}'; a sum can only be unchanged") if $i->{expect} ne 'unchanged';
    }
    if ( !eval { $class->split_domain( $i->{domain} // [] ); 1 } ) {
        my $err = $@;
        $bad->( 'has a bad domain: ' . ( ref $err && $err->can('message') ? $err->message : $err ) );
    }
    return;
}

# ( plain domain, [ [field, op, other_field] ... ] )
sub split_domain ($class, $domain) {
    my ( @plain, @cmps );
    for my $t (@$domain) {
        if ( ref $t eq 'ARRAY' && @$t == 3 && ref $t->[2] eq 'HASH' && defined $t->[2]{field} ) {
            Odoo::Error->throw( kind => 'config', message => "invariant domain: field comparison with operator '$t->[1]' is not supported" )
                if !$COMPARE{ $t->[1] };
            push @cmps, [ $t->[0], $t->[1], $t->[2]{field} ];
        }
        else { push @plain, $t }
    }
    # a prefix operator left dangling by the removed terms would corrupt the rest
    Odoo::Error->throw( kind => 'config', message => 'invariant domain: a field comparison cannot sit under | or !' )
        if @cmps && grep { !ref && /^[|!]\z/ } @plain;
    return ( \@plain, \@cmps );
}

=head2 for_plan($ctx, $plan)

The invariants (each a hashref with C<model> and the rest of the
definition) of every model the plan writes that apply to the plan's
operation, once each, in a stable order.

=cut

sub for_plan ($class, $ctx, $plan) {
    my %models;
    my $reg;
    my $packs;    # the packs the plan's operation answers for, found when an invariant names a pack
    for my $c ( @{ $plan->changes } ) {
        next if $c->{action} eq 'skip' || $c->{action} eq 'hold';
        if ( $c->{action} eq 'custom' && $c->{handler} ) {
            $reg //= Odoo::Ops::Registry->new;
            my $h = eval { $reg->class_for_handler( $c->{handler} ) };
            $models{$_} = 1 for $h ? $h->models_touched($c) : ( $c->{model} // () );
        }
        elsif ( $c->{model} ) { $models{ $c->{model} } = 1 }
    }
    my ( %seen, @out );
    for my $m ( sort keys %models ) {
        for my $i ( @{ $ctx->behaviour($m)->invariants } ) {
            my $key = "$i->{model}\0$i->{name}";
            next if $seen{$key}++;
            if ( defined $i->{pack} ) {
                $packs //= $class->_packs_of( $reg //= Odoo::Ops::Registry->new, $plan->op );
                next if !$packs->{ $i->{pack} };
            }
            push @out, $i;
        }
    }
    return @out;
}

# The packs an operation answers for, as a set: none for a name the registry
# does not know (a revert, a resume), which no pack's rules judge.
sub _packs_of ($class, $reg, $op) {
    # every operation name has a dot (core.read, crm_page.lead); a revert or resume plan's does not, and asking the registry for it would scan every namespace
    return {} if !defined $op || $op !~ /\./;
    my $cls = eval { $reg->class_for_handler($op) } or return {};
    return { map { $_ => 1 } $cls->invariant_packs };
}

=head2 for_models($ctx, @models)

The invariants of the named physical models.

=cut

sub for_models ($class, $ctx, @models) {
    my ( %seen, @out );
    for my $m ( sort @models ) {
        for my $i ( @{ $ctx->behaviour($m)->invariants } ) {
            push @out, $i if !$seen{"$i->{model}\0$i->{name}"}++;
        }
    }
    return @out;
}

=head2 add_scope(
\%scope, @invariants)

Adds C<search_read> on each invariant's model to a physical scope
(the plan's apply scope).

=cut

sub add_scope ($class, $scope, @inv) {
    for my $i (@inv) {
        my %have = map { $_ => 1 } @{ $scope->{ $i->{model} } // [] };
        $have{search_read} = 1;
        $scope->{ $i->{model} } = [ sort keys %have ];
    }
    return $scope;
}

=head2 measure($client, \%invariant)

The current value: a number for C<count>, a hashref group => total for
C<sum>.

=cut

sub measure ($class, $client, $i) {
    my ( $dom, $cmps ) = $class->split_domain( $i->{domain} // [] );
    my $model = $client->model( $i->{model} );
    my $check = $i->{check} // 'count';
    if ( $check eq 'count' ) {
        my %f = map { $_ => 1 } map { ( $_->[0], $_->[2] ) } @$cmps;
        my $rows = $model->search_read( $dom, [ 'id', sort keys %f ] );
        return scalar @$rows if !@$cmps;
        my $n = 0;
        ROW: for my $r (@$rows) {
            for my $c (@$cmps) {
                next ROW if !$COMPARE{ $c->[1] }->( _plain( $r->{ $c->[0] } ), _plain( $r->{ $c->[2] } ) );
            }
            $n++;
        }
        return $n;
    }
    my @by = ref $i->{group_by} eq 'ARRAY' ? @{ $i->{group_by} } : defined $i->{group_by} ? ( $i->{group_by} ) : ();
    my $rows = $model->search_read( $dom, [ 'id', @by, $i->{field} ] );
    my %sum;
    for my $r (@$rows) {
        my $key = join '/', map { _plain( $r->{$_} ) // '' } @by;
        $sum{$key} += $r->{ $i->{field} } // 0;
    }
    return { map { $_ => 0 + sprintf( '%.6f', $sum{$_} ) } keys %sum };
}

# a many2one reads as [id, label]; a false reads as a boolean
sub _plain ($v) {
    return $v->[0] if ref $v eq 'ARRAY';
    return undef if ref $v;    # JSON false
    return $v;
}

=head2 measure_all($client, \@invariants)

C<< { "model\0name" => value } >>.

=cut

sub measure_all ($class, $client, $inv) {
    return { map { _key($_) => $class->measure( $client, $_ ) } @$inv };
}

sub _key ($i) { "$i->{model}\0$i->{name}" }

=head2 judge(\@invariants, \%before, \%after)

One row per invariant: C<< { name, model, text, before, after, ok } >>.
For a C<sum>, C<before> and C<after> are C<< { groups, total } >> and a
failing row adds C<changed> (the groups that moved, at most 50).
C<preexisting> is true when the invariant was already broken before
the apply and the apply left the value as it was: the row stays not
C<ok>, but it is not the apply's doing, so it does not fail the run.

=cut

sub judge ($class, $inv, $before, $after) {
    my @rows;
    for my $i (@$inv) {
        my ( $b, $a ) = ( $before->{ _key($i) }, $after->{ _key($i) } );
        my ( $ok, %extra );
        my $sum = ( $i->{check} // 'count' ) eq 'sum';
        if ($sum) {
            my %moved;
            for my $k ( keys %{ { %$b, %$a } } ) {
                my ( $x, $y ) = ( $b->{$k} // 0, $a->{$k} // 0 );
                $moved{$k} = { before => $x, after => $y } if abs( $x - $y ) >= 0.0005;
            }
            $ok = !%moved;
            if ( !$ok ) {
                my @k = sort keys %moved;
                splice @k, 50 if @k > 50;
                $extra{changed} = { map { $_ => $moved{$_} } @k };
            }
            my $tot = sub ($h) { my $t = 0; $t += $_ for values %$h; 0 + sprintf( '%.6f', $t ) };
            ( $b, $a ) = ( { groups => scalar keys %$b, total => $tot->($b) }, { groups => scalar keys %$a, total => $tot->($a) } );
        }
        else {
            $ok = $i->{expect} eq 'unchanged' ? $a == $b : $a == $i->{expect};
        }
        my $pre = !$ok && !$sum && $i->{expect} ne 'unchanged' && $b != $i->{expect} && $a == $b ? 1 : 0;
        push @rows, { name => $i->{name}, model => $i->{model}, text => $i->{text}, before => $b, after => $a, ok => $ok ? 1 : 0,
            ( $pre ? ( preexisting => 1 ) : () ), %extra };
    }
    return @rows;
}

1;
