package Odoo::Ops::Runner;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use File::Spec;
use Scalar::Util qw(blessed);

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Invariant;
use Odoo::Ops::Journal;
use Odoo::Ops::Plan;
use Odoo::Ops::Registry;
use Odoo::Ops::Result;
use Odoo::Ops::Runs;

=head1 NAME

Odoo::Ops::Runner - apply a plan through a journal; plan a revert

=head1 SYNOPSIS

    my $result = Odoo::Ops::Runner->apply($ctx, $plan, dir => $run_dir);
    my $undo   = Odoo::Ops::Runner->revert_plan($ctx, "$run_dir/journal.jsonl");

=head1 DESCRIPTION

C<apply> is the only code path that writes. Before sending anything
it refuses when:

=over

=item * the config does not say C<allow_writes = 1>;

=item * the plan was made against a different instance (url, db,
login);

=item * the run directory already holds a journal - a plan is applied
once;

=item * the run is past its C<expires> (C<expired>), or - unless the
config says C<approval = none> - is not approved (C<unapproved>) or was
approved for a different plan (C<approval-stale>); see
L<Odoo::Ops::Runs>. A program approves with
C<< Odoo::Ops::Runs->approve_plan($dir, $plan, by => ...) >> first.
After the journal, the run's C<run.json> records the apply.

=item * any write or unlink's before-image no longer matches the live
record (stale plan): nothing is sent, and the refusal lists the
change numbers.

=back

Changes then run in order under the plan's declared scope. Every
change's outcome goes to the journal as it happens; each create and
write is read back from the server and the after-image journalled
(C<verified>). The first failure stops the run - the rest are
C<not_attempted> - unless C<< continue_on_error => 1 >>, with which a
row's failure (a fault Odoo raised for that row) is counted C<failed>
and the run goes on. A fault of kind C<transport> stops the run
whatever was asked: a dead connection is not a row's failure.
C<< stop_after => N >> stops once N changes have failed (and carries
on past failures until then); C<< only => [KEY, ...] >> applies just
the changes with those keys, the rest C<not_attempted> and not checked
for staleness - how a big plan is worked in parts and one row retried.

C<revert_plan> reads a journal and returns a new plan (not applied)
that undoes its creates (unlink) and writes (write the before-image
back). A C<custom> change is undone by what its handler's class method
C<undo_custom($journal_entry)> returns: a change (the opposite
transfer, say) or C<(undef, $reason)>, which becomes a hold. Deletes
and method calls are held as irreversible. Each undo carries the
journalled after-image as its before-image, so a record edited since
the run makes the revert stale rather than clobbering the edit. The
plan's params carry C<reverts> (the journal) and each undo names the
journal entry it undoes (C<undoes>).

C<resume_plan> reads a journal and its plan and returns a new plan of
the changes that failed or were not attempted.

=cut

sub apply ($class, $ctx, $plan, %opts) {
    Odoo::Error->throw(
        kind    => 'refused',
        code    => 'read-only',
        message => 'this config does not allow writes (allow_writes = 1 is required)',
    ) if !$ctx->allow_writes;

    Odoo::Error->throw(
        kind    => 'refused',
        code    => 'instance',
        message => 'plan was made against a different instance than this config',
    ) if Odoo::Ops::json()->encode( $plan->instance ) ne Odoo::Ops::json()->encode( $ctx->instance );

    my $dir = $opts{dir}
        or Odoo::Error->throw( kind => 'usage', message => 'apply needs a dir for its journal' );
    my $journal_path = File::Spec->catfile( $dir, 'journal.jsonl' );
    Odoo::Error->throw(
        kind    => 'refused',
        code    => 'applied',
        message => "$journal_path exists: this plan has already been applied from here",
    ) if -e $journal_path;

    # after the applied check, so a second apply says "applied", not "unapproved"
    Odoo::Ops::Runs->check_apply( $dir, $plan, approval => $ctx->approval, now => $ctx->now );

    my $client  = $ctx->client;
    my $started = $ctx->now;

    return $ctx->guard->with_scope( $plan->scope, $plan->op, sub {
        # a plan worked in parts (only) is checked for the rows it will touch
        my $only = $opts{only} ? { map { $_ => 1 } @{ $opts{only} } } : undef;
        my $wanted = sub ($c) { !$only || ( defined $c->{key} && $only->{ $c->{key} } ) };
        my @stale = $class->_stale_changes( $client, [ grep { $wanted->($_) } @{ $plan->changes } ] );
        Odoo::Error->throw(
            kind    => 'refused',
            code    => 'stale',
            message => 'plan is stale: live data differs from the before-image of change(s) '
                . join( ', ', @stale ) . ' - re-plan',
        ) if @stale;

        my $journal = Odoo::Ops::Journal->create($journal_path);
        $journal->header(
            op               => $plan->op,
            plan_fingerprint => $plan->fingerprint,
            instance         => $plan->instance,
            actor            => $ctx->actor,
            started          => Odoo::Ops::iso_time($started),
        );

        # what must hold around the apply: read now, and again after the last change
        my @invariants = Odoo::Ops::Invariant->for_plan( $ctx, $plan );
        my @skipped    = grep { !_scope_reads( $plan, $_->{model} ) } @invariants;
        @invariants = grep { _scope_reads( $plan, $_->{model} ) } @invariants;
        my $inv_before = Odoo::Ops::Invariant->measure_all( $client, \@invariants );

        my ( %counts, %by_bucket, %refs, $verified, $not_verified, $stopped );
        my $record = sub ( $c, $entry, $outcome ) {
            $refs{ $c->{ref} } = $entry->{id} if $outcome eq 'done' && defined $c->{ref};
            $entry->{outcome} = $outcome;
            $journal->change(%$entry);
            $counts{$outcome}++;
            $by_bucket{ $c->{bucket} }{$outcome}++;
        };
        # A row's failure and a dead connection are different things: a
        # transport fault stops the run whatever was asked, so a server that
        # went away never marks every remaining row failed. stop_after N
        # implies carrying on past a row's failure until N have failed.
        my $keep_going = $opts{continue_on_error} || $opts{stop_after};
        my $fail = sub ( $c, $entry, $err ) {
            my $is_err = blessed($err) && $err->isa('Odoo::Error');
            $entry->{error} = $is_err
                ? { kind => $err->kind, category => $err->fault_category, message => $err->message }
                : { kind => 'perl', message => "$err" };
            my $transport = $is_err && $err->kind eq 'transport';
            $stopped = $c->{seq} if $transport || !$keep_going;
            $stopped = $c->{seq} if $opts{stop_after} && ( $counts{failed} // 0 ) + 1 >= $opts{stop_after};
        };
        # one change at a time; or, with batch => N, runs of up to N
        # consecutive creates on one model sent as one create call
        my @changes = @{ $plan->changes };
        my $batch   = $opts{batch} // 1;
        my $i       = 0;
        while ( $i < @changes ) {
            my $c = $changes[$i];
            if ( $stopped || !$wanted->($c) ) {
                $counts{not_attempted}++;
                $i++;
                next;
            }
            my @run = ($c);
            if ( $batch > 1 && _batchable($c) ) {
                while ( @run < $batch && $i + @run < @changes && $wanted->( $changes[ $i + @run ] ) && _batchable( $changes[ $i + @run ] ) && _same_batch( $c, $changes[ $i + @run ] ) ) {
                    push @run, $changes[ $i + @run ];
                }
            }
            $i += @run;
            if ( @run > 1 ) {
                my ( $ok_v, $ok_nv, $done ) = $class->_apply_batch( $client, \@run, \%refs, $record, $fail );
                $verified     += $ok_v;
                $not_verified += $ok_nv;
                next if $done;
                # the batch failed as a whole: each change again, one at a time, so the failure is named
                @run = grep { !$_->{_journalled} } @run;
            }
            for my $c (@run) {
                if ($stopped) { $counts{not_attempted}++; next }
                my %entry = _entry($c);
                my $outcome = 'done';
                if ( $c->{action} eq 'skip' || $c->{action} eq 'hold' ) {
                    $outcome = $c->{action} eq 'skip' ? 'skipped' : 'held';
                }
                elsif ( $c->{action} eq 'create' && $c->{unique_by}
                    && defined( my $have = $class->_existing( $client, $c ) ) )
                {
                    # Another plan (or a person) created it since planning.
                    $entry{id}     = $have;
                    $entry{reason} = "already exists by $c->{unique_by}; reused";
                    $outcome       = 'skipped';
                    $refs{ $c->{ref} } = $have if defined $c->{ref};
                }
                else {
                    my $ok = eval {
                        my $resolved = { %$c, vals => _resolve_refs( $c->{vals}, \%refs ) };
                        $entry{vals} = $resolved->{vals} if exists $c->{vals};
                        my $after = $class->_do_change( $client, $resolved, \%entry );
                        if ($after) { $verified++ } else { $not_verified++ }
                        1;
                    };
                    if ( !$ok ) { $outcome = 'failed'; $fail->( $c, \%entry, $@ ) }
                }
                $record->( $c, \%entry, $outcome );
            }
        }

        my @inv_rows = Odoo::Ops::Invariant->judge( \@invariants, $inv_before, Odoo::Ops::Invariant->measure_all( $client, \@invariants ) );
        # a plan saved before its scope named the read cannot be checked: say so, never pass it silently
        push @inv_rows, map { { name => $_->{name}, model => $_->{model}, text => $_->{text}, ok => 1, skipped => "plan scope lacks search_read on $_->{model}" } } @skipped;
        my $inv_failed = grep { !$_->{ok} && !$_->{preexisting} && !$_->{skipped} } @inv_rows;

        my $finished = $ctx->now;
        $journal->footer( finished => Odoo::Ops::iso_time($finished), counts => \%counts,
            ( @inv_rows ? ( invariants => \@inv_rows ) : () ), ( $inv_failed ? ( invariants_failed => $inv_failed ) : () ) );
        my $result = Odoo::Ops::Result->new(
            op               => $plan->op,
            plan_fingerprint => $plan->fingerprint,
            total            => scalar @{ $plan->changes },
            counts           => \%counts,
            by_bucket        => \%by_bucket,
            verified         => $verified // 0,
            not_verified     => $not_verified // 0,
            journal          => $journal_path,
            started          => Odoo::Ops::iso_time($started),
            finished         => Odoo::Ops::iso_time($finished),
            stopped_by       => $stopped,
            invariants       => \@inv_rows,
            invariants_failed => $inv_failed,
        );
        # the run record follows the journal; a folder that cannot take it does not undo the apply
        eval { Odoo::Ops::Runs->record_applied( $dir, $result, by => $ctx->actor, now => $finished, plan => $plan ) };
        return $result;
    } );
}

# does the plan's declared scope let the apply read this model?
sub _scope_reads ($plan, $model) {
    return scalar grep { $_ eq 'search_read' } @{ $plan->scope->{$model} // [] };
}

sub _entry ($c) {

    return map { $_ => $c->{$_} } grep { exists $c->{$_} }
        qw(seq bucket action kind model id method handler before vals key ref support context);
}

# a plain create: no reference to an earlier change's id, nothing narrowing the read-back
sub _batchable ($c) {
    return $c->{action} eq 'create' && !$c->{readback} && !Odoo::Ops::Plan::_refs_in( $c->{vals} );
}

sub _same_batch ($a, $b) {
    return $a->{model} eq $b->{model}
        && ( $a->{unique_by} // '' ) eq ( $b->{unique_by} // '' )
        && Odoo::Ops::json()->encode( $a->{context} // {} ) eq Odoo::Ops::json()->encode( $b->{context} // {} );
}

# A run of creates as one call: the unique_by re-check as one search,
# the creates as one create, the read-back as one read; every change
# still gets its own journal line, in order. Returns (verified,
# not_verified, done); done is false when the batch create itself
# failed and nothing of it was journalled, so the caller retries one
# at a time.
sub _apply_batch ($class, $client, $run, $refs, $record, $fail) {
    my $first = $run->[0];
    my $model = $client->model( $first->{model} );
    my @ctx   = $first->{context} ? ( context => $first->{context} ) : ();
    my ( $verified, $not_verified ) = ( 0, 0 );
    my ( @to_create, %pending );    # seq -> [ entry, outcome ], journalled in plan order at the end
    if ( my $f = $first->{unique_by} ) {
        # the same comparison as the single path (=ilike), as one OR
        my @terms  = map { [ $f, '=ilike', $_->{vals}{$f} ] } @$run;
        my @domain = ( ('|') x ( @terms - 1 ), @terms );
        my %have;
        for my $row ( @{ $model->search_read( \@domain, [$f] ) } ) {
            $have{ lc $row->{$f} } //= $row->{id};
        }
        for my $c (@$run) {
            if ( defined( my $id = $have{ lc $c->{vals}{$f} } ) ) {
                $pending{ $c->{seq} } = [ { _entry($c), id => $id, reason => "already exists by $f; reused" }, 'skipped' ];
            }
            else { push @to_create, $c }
        }
    }
    else { @to_create = @$run }
    if (@to_create) {
        my $ids = eval { $model->create( [ map { $_->{vals} } @to_create ], @ctx ) };
        return ( 0, 0, 0 ) if !$ids || ref $ids ne 'ARRAY' || @$ids != @to_create;
        my %fields;
        for my $c (@to_create) { $fields{$_} = 1 for keys %{ $c->{vals} } }
        my $rows = eval { $model->read( $ids, [ sort keys %fields ] ) } // [];
        my %after = map { $_->{id} => $_ } @$rows;
        for my $k ( 0 .. $#to_create ) {
            my $c = $to_create[$k];
            my %entry = ( _entry($c), id => $ids->[$k] );
            if ( $after{ $ids->[$k] } ) { $entry{after} = $after{ $ids->[$k] }; $verified++ } else { $not_verified++ }
            $pending{ $c->{seq} } = [ \%entry, 'done' ];
        }
    }
    for my $c (@$run) {
        my ( $entry, $outcome ) = @{ $pending{ $c->{seq} } };
        $refs->{ $c->{ref} } = $entry->{id} if defined $c->{ref};
        $record->( $c, $entry, $outcome );
        $c->{_journalled} = 1;
    }
    return ( $verified, $not_verified, 1 );
}

# ids out of what a method returned: a list of ints, or the string
# form of a recordset, "mail.activity(203,)" / "mail.activity(1, 2)"
sub _returned_ids ($ret) {
    return grep { /^\d+\z/ } @$ret if ref $ret eq 'ARRAY';
    return () if ref $ret || !defined $ret;
    return ( 0 + $ret ) if $ret =~ /^\d+\z/;    # a method that returns one id (message_post)
    my ($inner) = $ret =~ /^[\w.]+\(([\d,\s]*)\)\z/ or return ();
    return grep { length } map { s/\s//gr } split /,/, $inner;
}

# a read-back value against an expectation: many2one [id, name] vs id,
# numbers vs numbers, everything else as strings
sub _same ($got, $want) {
    $got = $got->[0] if ref $got eq 'ARRAY' && @$got == 2 && !ref $want;
    return 0 if !defined $got || !defined $want;
    return $got == $want if $got =~ /^-?\d+(?:\.\d+)?\z/ && $want =~ /^-?\d+(?:\.\d+)?\z/;
    return "$got" eq "$want";
}

# The id of a record matching a create's unique_by field, if any.
sub _existing ($class, $client, $c) {
    my $f    = $c->{unique_by};
    my $rows = $client->model( $c->{model} )->search_read( [ [ $f, '=ilike', $c->{vals}{$f} ] ], ['id'], limit => 1 );
    return @$rows ? $rows->[0]{id} : undef;
}

# Replace { '$ref' => name } with the id an earlier change created.
sub _resolve_refs ($v, $refs) {
    return $v if !ref $v;
    if ( ref $v eq 'HASH' ) {
        if ( keys %$v == 1 && exists $v->{'$ref'} ) {
            return $refs->{ $v->{'$ref'} } // Odoo::Error->throw(
                kind    => 'usage',
                message => "\$ref '$v->{'$ref'}' was not created before it was needed",
            );
        }
        return { map { $_ => _resolve_refs( $v->{$_}, $refs ) } keys %$v };
    }
    return [ map { _resolve_refs( $_, $refs ) } @$v ] if ref $v eq 'ARRAY';
    return $v;
}

# Returns the after-image when the change was read back.
sub _do_change ($class, $client, $c, $entry) {
    my $model = $client->model( $c->{model} );
    my $action = $c->{action};
    my @ctx    = $c->{context} ? ( context => $c->{context} ) : ();
    if ( $action eq 'create' ) {
        my $id = $model->create( $c->{vals}, @ctx );
        $entry->{id} = $id;
        # readback narrows what is read back (e.g. not a file's content)
        my $rb = $c->{readback} ? { map { $_ => 1 } @{ $c->{readback} } } : $c->{vals};
        return $entry->{after} = $class->_read_back( $model, $id, $rb );
    }
    if ( $action eq 'write' ) {
        $model->write( $c->{id}, $c->{vals}, @ctx );
        return $entry->{after} = $class->_read_back( $model, $c->{id}, $c->{vals} );
    }
    if ( $action eq 'unlink' ) {
        $model->unlink( $c->{id} );
        return undef;
    }
    if ( $action eq 'custom' ) {
        # The operation that planned it knows how to carry it out.
        my $class = Odoo::Ops::Registry->new->class_for( $c->{handler} );
        my $out = $class->apply_custom( $client, $c );
        $entry->{id}       = $out->{id} if defined $out->{id};
        $entry->{returned} = $out->{returned} if exists $out->{returned};
        return $out->{after};
    }
    if ( $action eq 'call' ) {
        my $ids = $c->{ids} // ( $c->{id} ? [ $c->{id} ] : [] );
        my $ret = $client->execute_kw( $c->{model}, $c->{method},
            [ $ids, @{ $c->{args} // [] } ], $c->{kwargs} // {} );
        $entry->{returned} = $ret if !ref $ret || ( ref $ret eq 'ARRAY' && !grep { ref } @$ret );
        # a call that says what it should have produced is read back:
        # verify => { model, fields => { field => expected } }, the ids
        # named in verify->{ids}, else taken from the return value (ints,
        # or Odoo's "model(1,2,)")
        if ( my $v = $c->{verify} ) {
            my @made = $v->{ids} ? @{ $v->{ids} } : _returned_ids($ret);
            return undef if !@made;
            my $rows = $client->model( $v->{model} )->read( \@made, [ sort keys %{ $v->{fields} } ] );
            my $ok   = @$rows == @made;
            for my $row (@$rows) {
                for my $f ( keys %{ $v->{fields} } ) {
                    $ok = 0 if !_same( $row->{$f}, $v->{fields}{$f} );
                }
            }
            return $entry->{after} = $ok ? { ids => \@made, %{ $v->{fields} } } : undef;
        }
        return undef;
    }
    Odoo::Error->throw( kind => 'usage', message => "cannot apply action '$action'" );
}

sub _read_back ($class, $model, $id, $vals) {
    my @f   = sort keys %$vals;
    my $row = $model->read_one( $id, @f ? \@f : ['id'] );
    Odoo::Error->throw(
        kind    => 'fault',
        message => "read-back found no record $id on " . $model->name,
    ) if !$row;
    return $row;
}

sub _stale_changes ($class, $client, $changes) {
    my %by_model;
    for my $c (@$changes) {
        next if $c->{action} !~ /^(write|unlink|custom|call)\z/;
        next if ref $c->{before} ne 'HASH' || !$c->{id};
        push @{ $by_model{ $c->{model} } }, $c;
    }
    my @stale;
    for my $m ( sort keys %by_model ) {
        my @cs = @{ $by_model{$m} };
        my %fields;
        for my $c (@cs) { $fields{$_} = 1 for grep { $_ ne 'id' } keys %{ $c->{before} } }
        my @ids  = map { $_->{id} } @cs;
        my $rows = $client->model($m)->read( \@ids, [ sort keys %fields ] );
        my %live = map { $_->{id} => $_ } @$rows;
        for my $c (@cs) {
            my $now = $live{ $c->{id} };
            if ( !$now ) { push @stale, $c->{seq}; next }
            for my $f ( grep { $_ ne 'id' } keys %{ $c->{before} } ) {
                if ( _norm( $c->{before}{$f} ) ne _norm( $now->{$f} ) ) {
                    push @stale, $c->{seq};
                    last;
                }
            }
        }
    }
    return sort { $a <=> $b } @stale;
}

# Comparable form of a read value: many2one [id, label] -> id (labels
# drift without the record changing); id lists sorted; empties equal.
sub _norm ($v) {
    return '' if !defined $v || ( !ref $v && ( $v eq '0' || $v eq '' ) );
    if ( ref $v eq 'ARRAY' ) {
        return "m2o:$v->[0]" if @$v == 2 && !ref $v->[0] && defined $v->[1] && $v->[1] !~ /^-?\d+\z/;
        return 'ids:' . join ',', sort { $a <=> $b } grep { !ref } @$v;
    }
    return Odoo::Ops::json()->encode($v) if ref $v;
    return "$v";
}

=head2 revert_plan($ctx, $journal_path)

A new, unapplied plan undoing the journal's done changes, newest
first.

=cut

sub revert_plan ($class, $ctx, $journal_path) {
    my ( $header, $changes ) = Odoo::Ops::Journal->read($journal_path);
    Odoo::Error->throw(
        kind    => 'refused',
        code    => 'instance',
        message => 'journal was written against a different instance than this config',
    ) if Odoo::Ops::json()->encode( $header->{instance} ) ne Odoo::Ops::json()->encode( $ctx->instance );

    my @done = reverse grep { $_->{outcome} eq 'done' } @$changes;
    my $plan = Odoo::Ops::Plan->new(
        op          => 'revert',
        params      => { journal => $journal_path, reverts => $journal_path, of => $header->{plan_fingerprint}, of_op => $header->{op} },
        instance    => $ctx->instance,
        input_count => scalar @done,
        created     => Odoo::Ops::iso_time( $ctx->now ),
        actor       => $ctx->actor,
    );
    my %scope;
    for my $c (@done) {
        if ( $c->{action} eq 'create' ) {
            $plan->add(
                bucket => 'undo-create', action => 'unlink', model => $c->{model},
                id => $c->{id}, before => $c->{after}, of_seq => $c->{seq}, undoes => $c->{seq},
            );
            $scope{ $c->{model} }{$_} = 1 for qw(read unlink);
        }
        elsif ( $c->{action} eq 'write' ) {
            my $types = $ctx->client->model( $c->{model} )->fields;
            my %back;
            for my $f ( keys %{ $c->{vals} } ) {
                $back{$f} = _writable( $c->{before}{$f}, $types->{$f}{type} // '' );
            }
            $plan->add(
                bucket => 'undo-write', action => 'write', model => $c->{model},
                id => $c->{id}, vals => \%back, before => $c->{after}, of_seq => $c->{seq}, undoes => $c->{seq},
            );
            $scope{ $c->{model} }{$_} = 1 for qw(read write);
        }
        elsif ( $c->{action} eq 'custom' ) {
            my ( $undo, $why, $handler ) = $class->_undo_custom($c);
            if ($undo) {
                $undo->{bucket} //= 'undo-custom';
                $undo->{undoes} = $c->{seq};
                $plan->add(%$undo);
                if ( $undo->{action} eq 'custom' ) {
                    my $op = bless { ctx => $ctx, params => {} }, $handler;
                    my $hs = $op->scope_for('apply');
                    for my $m ( keys %$hs ) { $scope{$m}{$_} = 1 for @{ $hs->{$m} } }
                }
                else {
                    $scope{ $undo->{model} }{$_} = 1 for 'read', $undo->{action};
                }
            }
            else {
                $plan->add(
                    bucket => 'irreversible', action => 'hold', model => $c->{model},
                    of_seq => $c->{seq}, undoes => $c->{seq},
                    reason => $why // "$c->{handler} has no inverse (e.g. a sent email)",
                );
            }
        }
        else {
            $plan->add(
                bucket => 'irreversible', action => 'hold', model => $c->{model},
                of_seq => $c->{seq}, undoes => $c->{seq},
                reason => $c->{action} eq 'unlink' ? 'a deleted record cannot be recreated faithfully'
                    :                                "method $c->{method} has no inverse",
            );
        }
    }
    my $ps = { map { $_ => [ sort keys %{ $scope{$_} } ] } keys %scope };
    Odoo::Ops::Invariant->add_scope( $ps, Odoo::Ops::Invariant->for_models( $ctx, keys %scope ), Odoo::Ops::Invariant->for_plan( $ctx, $plan ) );
    $plan->note("reverts $journal_path");
    $plan->set_scope($ps);
    return $plan->finalize;
}

# What the handler of a done custom entry says about undoing it:
# (change) or (undef, reason, class).
sub _undo_custom ($class, $entry) {
    my $h = eval { Odoo::Ops::Registry->new->class_for( $entry->{handler} ) };
    return ( undef, "$entry->{handler} is not a known operation here; its change has no known inverse", undef ) if !$h;
    return ( undef, "$entry->{handler} has no inverse (e.g. a sent email)", $h ) if !$h->can('undo_custom');
    my ( $undo, $why ) = $h->undo_custom($entry);
    return ( $undo, $why, $h );
}

=head2 resume_plan($ctx, $journal_path)

A new, unapplied plan of the changes of a run that C<failed> or were
C<not_attempted>, in their original order with their keys, read from
the journal and the C<plan.json> beside it. Holds and skips are not
carried. A C<$ref> to a record the earlier run created is replaced by
its id. The before-image of each write, unlink, call and custom change
is read again from the server: a record that changed since planning
(or is gone) is held C<stale> in the new plan, so one changed row does
not block the rest. Creates keep C<unique_by>, so a row the failed
attempt created is found and skipped. The plan notes the run it
resumes.

=cut

sub resume_plan ($class, $ctx, $journal_path) {
    my ( $header, $entries ) = Odoo::Ops::Journal->read($journal_path);
    Odoo::Error->throw(
        kind    => 'refused',
        code    => 'instance',
        message => 'journal was written against a different instance than this config',
    ) if Odoo::Ops::json()->encode( $header->{instance} ) ne Odoo::Ops::json()->encode( $ctx->instance );
    my ( $vol, $dirs ) = File::Spec->splitpath($journal_path);
    my $plan_path = File::Spec->catpath( $vol, $dirs, 'plan.json' );
    my $orig = Odoo::Ops::Plan->load($plan_path);
    Odoo::Error->throw(
        kind    => 'refused',
        code    => 'plan',
        message => "$plan_path is not the plan this journal came from",
    ) if $orig->fingerprint ne ( $header->{plan_fingerprint} // '' );

    my %outcome = map { $_->{seq} => $_ } @$entries;
    my ( %made, @carry );
    for my $c ( @{ $orig->changes } ) {
        my $e = $outcome{ $c->{seq} };
        if ( $e && ( $e->{outcome} eq 'done' || $e->{outcome} eq 'skipped' ) && defined $c->{ref} && defined $e->{id} ) {
            $made{ $c->{ref} } = $e->{id};
        }
        next if $c->{action} eq 'skip' || $c->{action} eq 'hold';
        next if $e && $e->{outcome} !~ /^(failed|not_attempted)\z/;
        push @carry, $c;
    }

    my $n = grep { !$_->{support} } @carry;
    my $plan = Odoo::Ops::Plan->new(
        op          => $orig->op,
        params      => { %{ $orig->{params} // {} }, resumes => $journal_path },
        instance    => $ctx->instance,
        profile     => $orig->{profile},
        input_count => $n,
        created     => Odoo::Ops::iso_time( $ctx->now ),
        actor       => $ctx->actor,
    );

    # the before-images, read again now; the reads are declared in the scope
    my %models;
    for my $c (@carry) {
        next if $c->{action} !~ /^(write|unlink|custom|call)\z/ || ref $c->{before} ne 'HASH' || !$c->{id};
        $models{ $c->{model} } = 1;
    }
    my $scope = { %{ $orig->scope } };
    for my $m ( keys %models ) { $scope->{$m} = [ sort keys %{ { map { $_ => 1 } @{ $scope->{$m} // [] }, 'read' } } ] }
    my @stale = $ctx->guard->with_scope( $scope, 'resume', sub { $class->_stale_changes( $ctx->client, \@carry ) } );
    my %stale = map { $_ => 1 } @stale;

    for my $c (@carry) {
        if ( $stale{ $c->{seq} } ) {
            $plan->add(
                bucket => 'stale', action => 'hold', model => $c->{model}, id => $c->{id}, key => $c->{key},
                reason => "stale: $c->{model} $c->{id} changed since the plan was made; re-plan this row",
                resumes => $c->{seq},
            );
            next;
        }
        my %copy = %$c;
        delete $copy{$_} for qw(seq effects);
        $copy{vals}    = _subst_refs( $c->{vals}, \%made ) if exists $c->{vals};
        $copy{resumes} = $c->{seq};
        $plan->add(%copy);
    }
    $plan->note( "resumes $journal_path: " . scalar(@carry) . ' changes failed or were not attempted' );
    $plan->set_scope($scope);
    return $plan->finalize;
}

# { '$ref' => name } becomes the id when the earlier run made it; a ref to a
# change carried into this plan stays a ref
sub _subst_refs ($v, $made) {
    return $v if !ref $v;
    if ( ref $v eq 'HASH' ) {
        return $made->{ $v->{'$ref'} } if keys %$v == 1 && exists $v->{'$ref'} && exists $made->{ $v->{'$ref'} };
        return { map { $_ => _subst_refs( $v->{$_}, $made ) } keys %$v };
    }
    return [ map { _subst_refs( $_, $made ) } @$v ] if ref $v eq 'ARRAY';
    return $v;
}

# A read value turned back into something write accepts.
sub _writable ($v, $type) {
    return undef if !defined $v;
    if ( $type eq 'many2one' ) {
        return ref $v eq 'ARRAY' ? $v->[0] : ( $v ? $v : undef );
    }
    if ( $type eq 'many2many' || $type eq 'one2many' ) {
        return [ [ 6, 0, ref $v eq 'ARRAY' ? $v : [] ] ];
    }
    return $v;
}

1;
