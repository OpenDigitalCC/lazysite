package Odoo::Ops::Core::Import;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';
no warnings 'experimental::builtin';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops::Modules;
use Odoo::Ops;
use Odoo::Ops::Rows;
use Odoo::Ops::Source;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Core::Import - plan a keyed load of records into any model

=head1 SYNOPSIS

    # in-process: the caller has already mapped its rows
    my $plan = Odoo::Ops::Core::Import->new(
        ctx    => $ctx,
        params => {
            model   => 'res.partner',
            key     => ['ref'],
            records => [
                { key => 'C0001', values => { ref => 'C0001', name => 'ACME Ltd', country_id => 'GB' } },
                { key => 'C0002', values => { ref => 'C0002', name => 'Bad Row' }, held => 'rule:no address' },
            ],
            lookup  => { country_id => 'code' },
        },
    )->run;
    my $result = Odoo::Ops::Runner->apply( $ctx, $plan, dir => $run_dir );

    # from the command line: a file of records in Odoo field names
    oom-ops run core.import --conf C --set model=product.product \
        --set key=default_code --set rows=products.csv

=head1 DESCRIPTION

C<core.import>: records already expressed in a model's own field
names, matched to existing records by a key field (or fields), and
planned as creates and updates. The mapping - from whatever the
source was to Odoo's fields - is the caller's: middleware, a
L<Odoo::Ops::Source> mapping, or a person with a spreadsheet. This
operation owns what comes after: types checked, relations resolved by
name, rows matched, the difference planned, applied once, read back,
journalled, revertible.

Three ways in, exactly one per run:

    records   in-process rows (a Perl list) - the middleware case
    rows      a file: .jsonl (one record per line), .json (a list),
              .csv (header row = field names)
    mapping   a Source mapping whose target is the model

A record is C<{ key, values, held?, error? }> - the shape Source
rows have - or a flat C<{ field => value }> (a flat record may carry
C<_key>; without one its position names it). A caller that has
judged a row bad passes it with C<held> and a reason, and the plan
carries the hold; nothing is dropped on the way.

The key fields are char, integer, date, datetime or many2one. A date part
compares as C<YYYY-MM-DD>, a datetime part in UTC as C<YYYY-MM-DD HH:MM:SS>,
as Odoo stores them.

Values are in the field's own terms, with relations by name:

    many2one    the name (or the field named by C<lookup>) of one record
    many2many   a list of names, or one string split on C<;> or C<,>
    boolean     true/false (a JSON boolean too), yes/no, 1/0
    selection   a value, or its label
    date        YYYY-MM-DD; datetime YYYY-MM-DD HH:MM:SS
    html        plain text is wrapped in paragraphs

An empty value (undef or '') is "nothing to say": it is never written
and never clears a field.

Every row lands in exactly one bucket:

    create               no record carries the key
    update               the key matched one active record and a field policy leaves something to change
    unchanged            matched; nothing to change (a re-run after apply is all unchanged)
    no-key               a key field is empty - held: a created record could not be recognised on a re-run
    ambiguous            the key matches more than one record, or a relational value (a name, or the field named by C<lookup>) matches more than one - held, naming the field and the ids; the first is never taken
    matches-archived     the key matches an archived record - held (archived=update updates it)
    duplicate-in-source  an earlier row carries the same key
    unresolved           a related record named by the row does not exist and may not be created
    invalid              a value does not fit its field's type, or the row carries an error
    state-field          the row sets the state of a model whose behaviour says Odoo changes it through its own action - held, naming the operation
    held-flag, held-rule, held-override   held by the source or the caller, with the reason

Field policies on a matched record, per field through C<policy> or a
Source mapping's C<on_match>, otherwise C<on_match> for every field:
C<fill> (write only where the record is empty), C<overwrite>,
C<append> (text not already present), C<add> (many2many: link, never
unlink), C<ignore>. A migration whose source is the truth runs with
C<on_match=overwrite>; the default is C<fill>.

Related records named by rows but absent in Odoo hold the row, unless
their model is in C<create_missing>: then they are planned as support
creates before the rows that use them.

Writes carry C<tracking_disable>, C<mail_create_nolog>,
C<mail_notrack> and C<mail_create_nosubscribe> (C<quiet>, default
on), so a load leaves no chatter and sends no mail.

=cut

sub op_name ($class) { 'core.import' }
sub summary ($class) { 'Plan a keyed load of records (in Odoo field names) into any model' }
sub pack    ($class) { undef }
# What a plan of this operation sorts rows into (oom-ops describe prints them;
# t/99-declared-buckets.t checks them against what the tests plan).
sub buckets ($class) {
    return [
        { name => 'create', meaning => 'no record matched the key; one is made' },
        { name => 'update', meaning => 'one record matched and a value differs' },
        { name => 'unchanged', meaning => 'one record matched and nothing differs' },
        { name => 'new-<model>', meaning => 'a related record named by rows that is absent is made first (model in create_missing; a support row)' },
    ];
}
sub holds ($class) {
    return [
        { name => 'no-key', meaning => 'a key field is empty; a created record could not be recognised on a re-run' },
        { name => 'ambiguous', meaning => 'the key matches more than one record, or a relational value names more than one (the reason names the field and the ids)' },
        { name => 'matches-archived', meaning => 'the key matches an archived record (archived=update would update it)' },
        { name => 'duplicate-in-source', meaning => 'an earlier row carries the same key' },
        { name => 'unresolved', meaning => 'a related record is named but absent and its model is not in create_missing' },
        { name => 'invalid', meaning => 'a value does not fit its field\'s type, or the row carries an error' },
        { name => 'state-field', meaning => 'the row sets the state of a model whose state Odoo changes through its own action (sale.order, purchase.order, account.move); the operation that does it is named' },
        { name => 'held-flag', meaning => 'the source or the caller flagged the row as held' },
        { name => 'held-rule', meaning => 'a mapping rule held the row' },
        { name => 'held-override', meaning => 'a person held the row in the source\'s overrides, with the reason' },
    ];
}

sub params ($class) {
    {   model   => { type => 'str',  help => 'physical model, e.g. res.partner (a mapping may name it as target)' },
        key     => { type => 'list', help => 'field(s) identifying a record, e.g. ref or default_code' },
        records => { type => 'json', help => 'in-process records (a list) - for a program, not the command line' },
        rows    => { type => 'path', help => 'records file: .jsonl, .json (a list) or .csv with field names as header' },
        mapping => { type => 'path', help => 'a Source mapping (mapping.yaml) targeting the model' },
        on_match => { type => 'str', default => 'fill', help => 'policy for a matched record: fill (default) or overwrite' },
        policy  => { type => 'json', help => 'per-field policy: {"field": "fill|overwrite|append|add|ignore"}' },
        lookup  => { type => 'json', help => 'per relational field, the related field a value names: {"country_id": "code"}; default name, "id" for ids' },
        create_missing => { type => 'list', default => '', help => 'related models whose missing names may be created, e.g. res.partner.category' },
        archived => { type => 'str', default => 'hold', help => 'a key matching an archived record: hold (default) or update' },
        quiet   => { type => 'bool', default => 1, help => 'no chatter, no mail during the load' },
        limit   => { type => 'int', help => 'plan only the first N rows (a trial)' },
    };
}
sub read_scope  ($class) { {} }    # built per run from the model and its relations
sub write_scope ($class) { {} }
sub writes      ($class) { 1 }

my %POLICY = map { $_ => 1 } qw(fill add append overwrite ignore);

# scopes depend on params: the model, and every relation a row names
sub scope_for ($self, $phase) {
    my $m = $self->_model_name;
    my %s = ( $m => { search_read => 1 } );
    $s{$_}{search_read} = 1 for keys %{ $self->{relations} // {} };
    if ( $phase eq 'apply' ) {
        $s{$m}{$_} = 1 for qw(create write read);
        $s{$_}{create} = 1, $s{$_}{read} = 1 for keys %{ $self->{create_ok} // {} };
    }
    return { map { $_ => [ sort keys %{ $s{$_} } ] } keys %s };
}

sub _model_name ($self) {
    return $self->{model_name} //= do {
        my $m = $self->param('model');
        if ( !defined $m && defined $self->param('mapping') ) {
            $m = $self->_source->target;
        }
        Odoo::Error->throw( kind => 'usage', message => 'core.import: parameter model is required (or a mapping naming its target)' )
            if !defined $m;
        Odoo::Error->throw( kind => 'usage', message => "core.import: model must be a physical model name, got '$m'" )
            if $m !~ /\./;
        $m;
    };
}

sub _source ($self) {
    return $self->{source} //= Odoo::Ops::Source->load( $self->param('mapping') );
}

sub plan ($self) {
    my @in = grep { defined $self->param($_) } qw(records rows mapping);
    Odoo::Error->throw( kind => 'usage', message => 'core.import: give exactly one of records, rows, mapping (got ' . ( @in ? "@in" : 'none' ) . ')' )
        if @in != 1;
    my $model = $self->_model_name;
    my $m     = $self->model($model);
    my $f     = eval { $m->fields } || Odoo::Ops::Modules->absent_model( $self->ctx, 'core.import', $model, $@ );
    $self->{create_ok} = { map { $_ => 1 } @{ $self->param('create_missing') } };
    my $on_match = $self->param('on_match');
    Odoo::Error->throw( kind => 'usage', message => "core.import: on_match must be fill or overwrite, got '$on_match'" )
        if $on_match !~ /^(fill|overwrite)\z/;
    for my $pol ( values %{ $self->param('policy') // {} } ) {
        Odoo::Error->throw( kind => 'usage', message => "core.import: unknown policy '$pol'" ) if !$POLICY{$pol};
    }
    $self->{policy} = { %{ $self->param('policy') // {} } };
    my $archived = $self->param('archived');
    Odoo::Error->throw( kind => 'usage', message => "core.import: archived must be hold or update, got '$archived'" )
        if $archived !~ /^(hold|update)\z/;

    my @keys = @{ $self->param('key') // [] };
    if ( !@keys && $in[0] eq 'mapping' ) {
        my $mk = $self->_source->mapping->{match}{keys};
        @keys = @$mk if ref $mk eq 'ARRAY';
    }
    Odoo::Error->throw( kind => 'usage', message => 'core.import: parameter key is required (the field(s) that identify a record)' ) if !@keys;
    for my $k (@keys) {
        Odoo::Error->throw( kind => 'usage', message => "core.import: key field '$k' is not a field of $model",
            fix => "name a field of $model as key" ) if !$f->{$k};
        Odoo::Error->throw( kind => 'usage', message => "core.import: key field '$k' is $f->{$k}{type}; a key is a char, integer, date, datetime or many2one field",
            fix => 'use a char, integer, date, datetime or many2one field as key' )
            if $f->{$k}{type} !~ /^(char|integer|date|datetime|many2one)\z/;
    }

    my $rows = $self->_rows;
    my $limit = $self->param('limit');
    $rows = [ @$rows[ 0 .. $limit - 1 ] ] if defined $limit && @$rows > $limit;

    # every field the rows mention, checked by name before anything is read
    my %used;
    for my $r (@$rows) {
        next if ref $r->{values} ne 'HASH';
        $used{$_} = 1 for keys %{ $r->{values} };
    }
    for my $fld ( sort keys %used ) {
        my $d = $f->{$fld}
            or Odoo::Error->throw( kind => 'usage', message => "core.import: '$fld' is not a field of $model",
                fix => "use the field names of $model in the rows" );
        Odoo::Error->throw( kind => 'usage', message => "core.import: '$fld' is a one2many field; load " . ( $d->{relation} // 'the related model' ) . ' with its own import',
            fix => 'load ' . ( $d->{relation} // 'the related model' ) . ' with its own import: oom-ops describe core.import' )
            if $d->{type} eq 'one2many';
        # a related field with an inverse (readonly false) is writable though not stored
        Odoo::Error->throw( kind => 'usage', message => "core.import: '$fld' is read-only and not stored on $model; it cannot be written",
            fix => "leave '$fld' out of the rows" )
            if exists $d->{store} && !$d->{store} && $d->{readonly};
        $self->{relations}{ $d->{relation} } = 1 if $d->{relation} && $d->{type} =~ /^many2(one|many)\z/;
    }
    if ( my $lk = $self->param('lookup') ) {
        for my $fld ( sort keys %$lk ) {
            Odoo::Error->throw( kind => 'usage', message => "core.import: lookup names '$fld', which is not a relational field of $model",
                fix => 'name a many2one or many2many field of the rows in lookup' )
                if !$f->{$fld} || $f->{$fld}{type} !~ /^many2(one|many)\z/;
        }
    }
    # the scope was sealed before the relations were known: widen it now
    $self->ctx->guard->with_scope( $self->scope_for('read'), $self->op_name, sub {
        $self->_plan_rows( $model, $f, \@keys, $rows, $on_match, $archived );
    } );
}

sub _plan_rows ($self, $model, $f, $keys, $rows, $on_match, $archived) {
    my $m = $self->model($model);
    # existing records, archived included, with every field we may compare
    my %want = map { $_ => 1 } @$keys;
    for my $r (@$rows) {
        next if ref $r->{values} ne 'HASH';
        $want{$_} = 1 for keys %{ $r->{values} };
    }
    $want{active} = 1 if $f->{active};
    my @domain;
    push @domain, [ 'active', 'in', [ JSON::PP::true, JSON::PP::false ] ] if $f->{active};
    # a many2one first key (key=order_id,product_id): only the records of the
    # parents the rows name are considered, not every line on the instance
    my $k1 = $keys->[0];
    my $scoped;
    if ( $f->{$k1}{type} eq 'many2one' ) {
        my %pid;
        for my $r (@$rows) {
            next if ref $r->{values} ne 'HASH' || defined $r->{error} || $r->{held};
            my $v = $r->{values}{$k1};
            next if !defined $v || ref $v || $v !~ /\S/;
            my $id = $self->_resolve( $k1, $f->{$k1}{relation}, $v );
            $pid{$id} = 1 if defined $id && !ref $id;
        }
        push @domain, [ $k1, 'in', [ sort { $a <=> $b } keys %pid ] ];
        $scoped = scalar keys %pid;
    }
    my $existing = defined $scoped && !$scoped ? [] : $m->all( \@domain, [ sort keys %want ] );
    my ( %index, %by_id );
    for my $e (@$existing) {
        $by_id{ $e->{id} } = $e;
        my $k = _key_of( $f, $keys, $e, 1 );
        push @{ $index{$k} }, $e->{id} if defined $k;
    }

    my ( @decisions, %seen, %needed );
    for my $i ( 0 .. $#$rows ) {
        my $row = $rows->[$i];
        my $d   = $self->_decide( $model, $f, $keys, $row, \%index, \%by_id, \%seen, $on_match, $archived );
        push @decisions, $d;
        if ( $d->{action} eq 'create' || $d->{action} eq 'write' ) {
            $needed{$_} = 1 for Odoo::Ops::Plan::_refs_in( $d->{vals} );
        }
        if ( $d->{action} ne 'hold' ) {
            my ($k) = $self->_row_key( $f, $keys, $row->{values} );
            $seen{$k} //= $i + 1 if defined $k;
        }
    }

    my $plan = $self->new_plan( input_count => scalar @$rows );
    $plan->note( "$model: " . scalar(@$rows) . ' rows, keyed by ' . join( '+', @$keys ) . "; on match: $on_match" );
    $plan->note( 'existing records considered: ' . scalar(@$existing) . ( $f->{active} ? ' (archived included)' : '' )
            . ( defined $scoped ? " (those of the $k1 values the rows name)" : '' ) );
    for my $ref ( sort keys %needed ) {
        my $s = $self->{support}{$ref};
        $plan->add( %$s, support => 1, ref => $ref );
    }
    my $ctx = $self->param('quiet')
        ? { tracking_disable => JSON::PP::true, mail_create_nolog => JSON::PP::true,
            mail_notrack => JSON::PP::true, mail_create_nosubscribe => JSON::PP::true }
        : undef;
    for my $d (@decisions) {
        $d->{context} = $ctx if $ctx && ( $d->{action} eq 'create' || $d->{action} eq 'write' );
        $plan->add(%$d);
    }
    return $plan;
}

# a row's composite key. A many2one part is resolved to the id Odoo's own
# records carry, so a row and the record it describes meet; the second value
# names the first empty part.
sub _row_key ($self, $f, $keys, $vals) {
    my @parts;
    for my $k (@$keys) {
        my $v = $vals->{$k};
        return ( undef, $k ) if !defined $v || ref $v || $v !~ /\S/;
        if ( $f->{$k}{type} eq 'many2one' ) {
            my $id = $self->_resolve( $k, $f->{$k}{relation}, $v );
            $v = !ref $id ? ( defined $id ? $id : $v )
               : $id->{ambiguous} ? 'ambiguous:' . join( ',', @{ $id->{ambiguous} } )
               :                    "ref:$id->{'$ref'}";
        }
        elsif ( $f->{$k}{type} =~ /^(date|datetime)\z/ ) {
            # as Odoo stores it: a date as YYYY-MM-DD, a datetime in UTC as YYYY-MM-DD HH:MM:SS;
            # a value that is neither stays as written, and the row is held invalid when its values are checked
            my ( $ok, $out ) = _coerce( $f->{$k}, $v );
            $v = $out if $ok;
        }
        push @parts, lc( $v =~ s/^\s+|\s+\z//gr );
    }
    return ( join( "\0", @parts ), undef );
}

# A row that sets the state of a model whose behaviour says Odoo changes it
# through its own actions is held: a state is changed by the action, never
# written. The reason names the operations that do it.
sub _state_field_hold ($self, $model, $vals) {
    my $beh  = $self->ctx->behaviour($model);
    my $rule = $beh->state_rule or return undef;
    my ($sf) = grep { my $v = $vals->{$_}; defined $v && !ref $v && $v =~ /\S/ } $beh->state_fields;
    return undef if !defined $sf;
    my @ops = @{ $rule->{operations} // [] };
    return "$model $sf is changed through Odoo's own action, never written"
        . ( @ops ? ': ' . join( ', ', map { "oom-ops run $_" } @ops ) : '' ) . "; take $sf out of the row";
}

# the composite key of a record or a row: normalised, undef when any part is empty
sub _key_of ($f, $keys, $vals, $from_odoo) {
    my @parts;
    for my $k (@$keys) {
        my $v = $vals->{$k};
        $v = $v->[0] if $from_odoo && ref $v eq 'ARRAY';     # many2one [id, name]
        return undef if !defined $v || ref $v || $v !~ /\S/;
        push @parts, lc( $v =~ s/^\s+|\s+\z//gr );
    }
    return join "\0", @parts;
}

sub _hold ($bucket, $row, $reason) {
    return { bucket => $bucket, action => 'hold', key => "src:$row->{key}", reason => $reason };
}

sub _decide ($self, $model, $f, $keys, $row, $index, $by_id, $seen, $on_match, $archived) {
    return _hold( 'invalid', $row, $row->{error} ) if defined $row->{error};
    if ( my $h = $row->{held} ) {
        my ($kind) = $h =~ /^(\w+):/;
        return _hold( 'held-' . ( $kind // 'flag' ), $row, $h );
    }
    my $vals = $row->{values};
    return _hold( 'invalid', $row, 'no values' ) if ref $vals ne 'HASH';
    if ( my $why = $self->_state_field_hold( $model, $vals ) ) { return _hold( 'state-field', $row, $why ) }

    my ( $k, $empty ) = $self->_row_key( $f, $keys, $vals );
    return _hold( 'no-key', $row, "key field $empty is empty - a created record could not be recognised on a re-run" )
        if !defined $k;
    return _hold( 'duplicate-in-source', $row, 'same ' . join( '+', @$keys ) . " as source row #$seen->{$k}" ) if $seen->{$k};

    # coerce every value to its field's terms; relations to ids
    my ( %resolved, @invalid, @unresolved, @ambiguous );
    for my $fld ( sort keys %$vals ) {
        my $v = $vals->{$fld};
        next if !defined $v || ( !ref $v && !_is_bool($v) && $v !~ /\S/ ) || ( ref $v eq 'ARRAY' && !@$v );
        my $d    = $f->{$fld};
        my $type = $d->{type};
        if ( $type eq 'many2one' || $type eq 'many2many' ) {
            my @names = ref $v eq 'ARRAY' ? @$v : $type eq 'many2many' ? split( /\s*[;,]\s*/, $v ) : ($v);
            my @ids;
            for my $n ( grep { defined && /\S/ } @names ) {
                my $id = $self->_resolve( $fld, $d->{relation}, $n );
                if ( !defined $id ) { push @unresolved, "$fld '$n'"; next }
                if ( ref $id eq 'HASH' && $id->{ambiguous} ) { push @ambiguous, $self->_ambiguous_words( $fld, $d->{relation}, $n, $id->{ambiguous} ); next }
                push @ids, $id;
            }
            next if !@ids;
            $resolved{$fld} = $type eq 'many2one' ? $ids[0] : \@ids;
        }
        else {
            my ( $ok, $out ) = _coerce( $d, $v );
            if ( !$ok ) { push @invalid, "$fld: $out"; next }
            $resolved{$fld} = $out;
        }
    }
    return _hold( 'invalid', $row, join( '; ', @invalid ) ) if @invalid;
    return _hold( 'unresolved', $row, 'unknown ' . join( ', ', @unresolved ) ) if @unresolved;
    return _hold( 'ambiguous', $row, join( '; ', @ambiguous ) ) if @ambiguous;

    my @ids = @{ $index->{$k} // [] };
    return _hold( 'ambiguous', $row, 'key matches records ' . join( ', ', @ids ) ) if @ids > 1;
    if ( !@ids ) {
        my %phys;
        for my $fld ( keys %resolved ) {
            $phys{$fld} = $f->{$fld}{type} eq 'many2many' ? [ [ 6, 0, $resolved{$fld} ] ] : $resolved{$fld};
        }
        # planning matches keys case-insensitively, so the apply-time look-up folds
        # a char part too; a part that waits on a support create has no id yet
        my $uniq;
        if ( !grep { ref $phys{$_} || !defined $phys{$_} } @$keys ) {
            $uniq = @$keys == 1 && $f->{ $keys->[0] }{type} eq 'char'
                ? { field => $keys->[0], fold => 1 }
                : { fields => [ map { $f->{$_}{type} eq 'char' ? { field => $_, fold => 1 } : $_ } @$keys ] };
        }
        return {
            bucket => 'create', action => 'create', model => $model, key => "src:$row->{key}", vals => \%phys,
            ( defined $uniq ? ( unique_by => $uniq ) : () ),
        };
    }

    my $id  = $ids[0];
    my $rec = $by_id->{$id};
    if ( $f->{active} && !$rec->{active} ) {
        return _hold( 'matches-archived', $row, "key matches archived record $id" ) if $archived ne 'update';
    }
    my ( %set, %before );
    for my $fld ( sort keys %resolved ) {
        my $type   = $f->{$fld}{type};
        my $policy = $self->{policy}{$fld} // ( $type eq 'many2many' ? 'add' : $on_match );
        next if $policy eq 'ignore';
        my ( $old, $new ) = ( $rec->{$fld}, $resolved{$fld} );
        my $write;
        if ( $type eq 'many2many' ) {
            my %have = map { $_ => 1 } @{ $old // [] };
            my @add  = grep { ref $_ || !$have{$_} } @$new;
            if ( $policy eq 'overwrite' ) {
                my $same = !grep( { ref } @$new )
                    && join( ',', sort { $a <=> $b } @$new ) eq join( ',', sort { $a <=> $b } keys %have );
                $write = [ [ 6, 0, $new ] ] if !$same;
            }
            elsif (@add) {
                $write = [ map { [ 4, $_, 0 ] } @add ];
            }
        }
        elsif ( $type eq 'many2one' ) {
            my $old_id = ref $old eq 'ARRAY' ? $old->[0] : undef;
            if ( ref $new || !defined $old_id || $old_id != $new ) {
                $write = $new if !$old_id || $policy eq 'overwrite';
            }
        }
        else {
            if ( _empty( $old, $type ) ) {
                $write = $new;
            }
            elsif ( $policy eq 'overwrite' && !_same( $old, $new, $type ) ) {
                $write = $new;
            }
            elsif ( $policy eq 'append' && index( _text($old), _text($new) ) < 0 ) {
                $write = $type eq 'html' ? "$old$new" : "$old\n\n$new";
            }
        }
        next if !defined $write;
        $set{$fld}    = $write;
        $before{$fld} = $old;
    }
    my $via = "key matches record $id" . ( $f->{active} && !$rec->{active} ? ' (archived)' : '' );
    return { bucket => 'unchanged', action => 'skip', key => "src:$row->{key}", id => $id, reason => $via } if !%set;
    return {
        bucket => 'update', action => 'write', model => $model, id => $id, key => "src:$row->{key}",
        vals   => \%set, before => \%before, reason => $via,
    };
}

# a JSON true or false (an object), or a native Perl boolean
sub _is_bool ($v) { return JSON::PP::is_bool($v) || builtin::is_bool($v) ? 1 : 0 }

# (ok, value) in the field's terms, or (0, why not)
sub _coerce ($d, $v) {
    my $type = $d->{type};
    $type = 'integer' if $type eq 'many2one_reference';    # the id half of res_model/res_id: a number on the wire, on every series
    if ( ref $v && !_is_bool($v) && $type ne 'binary' ) {
        return ( 0, ( ref $v eq 'HASH' ? 'an object' : 'a list' ) . " where one $type value is expected" );
    }
    if ( $type eq 'boolean' ) {
        # a JSON true or false, or 1 and 0, or the words; never a guess from anything else
        return ( 1, $v ? JSON::PP::true : JSON::PP::false ) if _is_bool($v);
        return ( 1, JSON::PP::true )  if $v =~ /^\s*(1|true|yes|y)\s*\z/i;
        return ( 1, JSON::PP::false ) if $v =~ /^\s*(0|false|no|n)\s*\z/i;
        return ( 0, "'$v' is not a boolean" );
    }
    return ( 0, ( $v ? 'a boolean true' : 'a boolean false' ) . " where one $type value is expected (only a boolean field takes true or false)" )
        if _is_bool($v) && $type ne 'binary';
    if ( $type eq 'integer' ) {
        return $v =~ /^\s*-?\d+\s*\z/ ? ( 1, 0 + $v ) : ( 0, "'$v' is not an integer" );
    }
    if ( $type eq 'float' || $type eq 'monetary' ) {
        my $n = $v =~ s/,//gr =~ s/^\s+|\s+\z//gr;
        return $n =~ /^-?(\d+\.?\d*|\.\d+)\z/ ? ( 1, 0 + $n ) : ( 0, "'$v' is not a number" );
    }
    if ( $type eq 'selection' ) {
        my $sel = $d->{selection} // [];
        for my $pair (@$sel) { return ( 1, $pair->[0] ) if "$pair->[0]" eq "$v" }
        for my $pair (@$sel) { return ( 1, $pair->[0] ) if lc "$pair->[1]" eq lc "$v" }
        return ( 0, "'$v' is not one of " . join( ', ', map { $_->[0] } @$sel ) );
    }
    if ( $type eq 'date' ) {
        return $v =~ /^\s*(\d{4}-\d\d-\d\d)\s*\z/ ? ( 1, $1 ) : ( 0, "'$v' is not a date (YYYY-MM-DD)" );
    }
    if ( $type eq 'datetime' ) {
        return ( 1, "$1 $2" ) if $v =~ /^\s*(\d{4}-\d\d-\d\d)[T ](\d\d:\d\d:\d\d)\s*\z/;
        return ( 1, "$1 00:00:00" ) if $v =~ /^\s*(\d{4}-\d\d-\d\d)\s*\z/;
        return ( 0, "'$v' is not a datetime (YYYY-MM-DD HH:MM:SS)" );
    }
    return ( 1, _to_html($v) ) if $type eq 'html';
    return ( 1, "$v" );
}

# What a held row says of a value that names several records: the field, the
# value, the records and the way out.
sub _ambiguous_words ($self, $fld, $relation, $name, $ids) {
    my $by = ( $self->param('lookup') // {} )->{$fld} // 'name';
    return "$fld '$name' matches $relation " . join( ', ', @$ids ) . " by $by; give the id of the one meant (lookup {\"$fld\":\"id\"})";
}

# A name -> id (or a $ref to a planned support create) for a relational
# field; undef when it neither exists nor may be created; { ambiguous => [ids] }
# when more than one record carries the name (the first is never taken).
sub _resolve ($self, $fld, $relation, $name) {
    my $lk = $self->param('lookup') // {};
    my $by = $lk->{$fld} // 'name';
    return $name =~ /^\d+\z/ ? 0 + $name : undef if $by eq 'id';
    my $norm  = lc( $name =~ s/^\s+|\s+\z//gr );
    my $index = $self->{cache}{"$relation.$by"} //= do {
        my $rm = $self->model($relation);
        Odoo::Error->throw( kind => 'usage', message => "core.import: lookup field '$by' is not a field of $relation",
                fix => "name a field of $relation in lookup" )
            if !$rm->fields->{$by};
        my @domain;
        push @domain, [ 'active', 'in', [ JSON::PP::true, JSON::PP::false ] ] if $rm->fields->{active};
        my %i;
        for my $r ( @{ $rm->all( \@domain, [$by] ) } ) {
            my $v = $r->{$by};
            $v = $v->[1] if ref $v eq 'ARRAY';
            next if !defined $v || $v eq '';
            push @{ $i{ lc $v } }, $r->{id};
        }
        \%i;
    };
    if ( my $ids = $index->{$norm} ) {
        return $ids->[0] if @$ids == 1;
        return { ambiguous => [ sort { $a <=> $b } @$ids ] };
    }
    return undef if !$self->{create_ok}{$relation};
    my $ref = "$relation:$norm";
    $self->{support}{$ref} //= {
        bucket => "new-$relation", action => 'create', model => $relation,
        vals   => { $by => $name =~ s/^\s+|\s+\z//gr }, unique_by => $by,
    };
    return { '$ref' => $ref };
}

sub _empty ($v, $type) {
    return 1 if !defined $v;
    return 0 if $type =~ /^(integer|many2one_reference|float|monetary|boolean)\z/;
    return 1 if !ref $v && $v eq '';
    return 1 if $type eq 'html' && _text($v) eq '';
    return 0;
}

sub _same ($old, $new, $type) {
    return ( $old ? 1 : 0 ) == ( $new ? 1 : 0 ) if $type eq 'boolean';
    return 0 if !defined $old;
    return $old == $new if $type =~ /^(integer|many2one_reference|float|monetary)\z/;
    return _text($old) eq _text($new) if $type eq 'html';
    return "$old" eq "$new";
}

sub _text ($v) {
    return '' if !defined $v || ref $v;
    my $t = $v =~ s/<[^>]*>/ /gr;
    $t =~ s/&nbsp;/ /g;
    $t =~ s/\s+/ /g;
    return $t =~ s/^ | \z//gr;
}

sub _to_html ($v) {
    return $v if $v =~ /^\s*</;
    my $e = $v =~ s/&/&amp;/gr =~ s/</&lt;/gr =~ s/>/&gt;/gr =~ s/"/&quot;/gr;
    return join '', map { '<p>' . ( s/\n/<br>/gr ) . '</p>' } split /\n{2,}/, $e;
}

# --- rows: records | rows file | mapping -----------------------------------

sub _rows ($self) {
    return Odoo::Ops::Rows->load( 'core.import', records => $self->param('records') ) if defined $self->param('records');
    return Odoo::Ops::Rows->load( 'core.import', rows => $self->param('rows') )       if defined $self->param('rows');
    my $src = $self->_source;
    Odoo::Error->throw( kind => 'usage', message => 'core.import: mapping target ' . $src->target . ' is not model ' . $self->_model_name,
        fix => 'pass model=' . $src->target . ' or a mapping whose target is ' . $self->_model_name )
        if $src->target ne $self->_model_name;
    for my $lf ( $src->fields ) {
        my $pol = $src->field_policy($lf) // next;
        Odoo::Error->throw( kind => 'usage', message => "mapping field '$lf': unknown on_match '$pol'",
            fix => 'use fill, add, append, overwrite or ignore' ) if !$POLICY{$pol};
        $self->{policy}{$lf} = $pol;
    }
    return $src->rows;
}

1;
