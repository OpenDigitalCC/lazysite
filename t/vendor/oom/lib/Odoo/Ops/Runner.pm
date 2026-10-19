package Odoo::Ops::Runner;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use File::Basename ();
use File::Spec;
use JSON::PP ();
use Scalar::Util qw(blessed);

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Invariant;
use Odoo::Ops::Guard ();
use Odoo::Ops::Journal;
use Odoo::Ops::Blob;
use Odoo::Ops::Plan;
use Odoo::Ops::PlanPrint;
use Odoo::Ops::Registry;
use Odoo::Ops::Result;
use Odoo::Ops::Runs;
use Odoo::Portable;

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

A journal is bound to its url, db and login. An administrator (a member of
C<base.group_system>, as Odoo answers C<has_group> at plan time) may revert
another login's run on the same url and db, and resume a revert another
login began; the plan says whose run it was (C<reverted_for>), and each
write's audit line names both logins. A resume of an ordinary apply stays
bound to its login, and another url or db is always refused.

C<revert_plan> reads a journal and returns a new plan (not applied)
that undoes its creates (unlink) and writes (write the before-image
back). It first reads the live records: a create is undone only while
the record is as it was made and a write only while the fields it set
are as it left them, otherwise the row is held C<changed-since> with
the differing fields named (the comparison leaves out C<write_date>,
C<write_uid>, C<__last_update>, C<message_ids>, C<activity_ids>, and the
C<volatile> fields of the model's behaviour file: the counters Odoo bumps on
its own, such as a partner's C<customer_rank>, which a confirm or a posting
moves without anyone editing the record). An
undo-create of a record that others point at carries C<effects> naming
them (found through C<ir.model.fields>), and one with a C<restrict>
reference is held C<referenced>. An undo-create of a record whose model's
behaviour says Odoo deletes it only from certain states (C<unlink_requires>)
is read at plan time; when the record (or, for a line, its parent) is in
another state the plan carries a note stating it and naming the state
operations the pack has for that model (C<account.move.line 150: its move
INV/2026/00005 (54) is posted; Odoo deletes a line only from draft or cancel;
state operations for account.move: account.post, account.cancel,
account.draft>). The delete is still planned; Odoo refuses at apply if it
must, the run reads C<failed> or C<partly-applied> with Odoo's words, and
C<resume> finishes it. An unlink is read back as absence and
is C<verified>; a C<unique_by> is C<'field'> (exact), C<< { field =>
'email', fold => 1 } >> (case-insensitive, wildcards escaped) or, for a
composite key, C<< { fields => [ 'order_id', { field => 'name', fold => 1 } ] } >>
(every part must match). A C<custom> change is undone by what its handler's class method
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
        fix     => 'add allow_writes = 1 to the config you apply with, if this instance may be written',
    ) if !$ctx->allow_writes;

    Odoo::Error->throw(
        kind    => 'refused',
        code    => 'instance',
        message => 'plan was made against a different instance than this config',
        fix     => 'apply with the config of the instance the plan was made for, or plan again with this one: oom-ops run ' . $plan->op . ' ...',
    ) if Odoo::Ops::json()->encode( $plan->instance ) ne Odoo::Ops::json()->encode( $ctx->instance );

    my $dir = $opts{dir}
        or Odoo::Error->throw( kind => 'usage', message => 'apply needs a dir for its journal' );
    # a run the caller closed is not applied, whatever else is true of it
    Odoo::Ops::Runs->refuse_closed($dir);
    my $journal_path = File::Spec->catfile( $dir, 'journal.jsonl' );
    Odoo::Error->throw(
        kind    => 'refused',
        code    => 'applied',
        message => "$journal_path exists: this plan has already been applied from here",
        fix     => 'a plan is applied once; plan again with oom-ops run ' . $plan->op . ' ... for a new run',
    ) if -e $journal_path;

    # after the applied check, so a second apply says "applied", not "unapproved"
    Odoo::Ops::Runs->check_apply( $dir, $plan, approval => $ctx->approval, now => $ctx->now );

    # the large values of the plan are in its run folder (Odoo::Ops::Blob): all of them are there, and
    # as they were planned, before anything is sent or journalled
    $plan->write_blobs($dir);
    my $blobs = $plan->blob_source($dir);
    my %has_blob;
    for my $c ( @{ $plan->changes } ) {
        my @refs = Odoo::Ops::Blob->refs($c) or next;
        $has_blob{ $c->{seq} } = 1;
        $blobs->verify($_) for @refs;
    }
    my $resolve = sub ($c) { $has_blob{ $c->{seq} } ? $blobs->resolve($c) : $c };
    # the journal keeps a blob's reference, as the plan does, whatever its size: a file's bytes are never in it
    my %orig = map { $_->{seq} => $_ } grep { $has_blob{ $_->{seq} } } @{ $plan->changes };

    my $client  = $ctx->client;
    my $started = $ctx->now;

    # an administrator's revert of another login's run: each audit line of the writes names both logins
    my $guard = $ctx->guard;
    local $guard->{for_login} = $plan->{params}{reverted_for};
    # audit_required: the check is made between changes, so a change that began is finished and read back
    local $guard->{no_check} = 1;
    return $ctx->guard->with_scope( $plan->scope, $plan->op, sub {
        # a plan worked in parts (only) is checked for the rows it will touch
        my $only = $opts{only} ? { map { $_ => 1 } @{ $opts{only} } } : undef;
        my $wanted = sub ($c) { !$only || ( defined $c->{key} && $only->{ $c->{key} } ) };
        my $detail = $class->_stale_detail( $client, [ map { $has_blob{ $_->{seq} } && ref $_->{before} ? { %$_, before => $blobs->resolve( $_->{before} ) } : $_ } grep { $wanted->($_) } @{ $plan->changes } ], $ctx );
        if ( my @stale = sort { $a <=> $b } keys %$detail ) {
            my %by_seq = map { $_->{seq} => $_ } @{ $plan->changes };
            my @what   = map { _stale_words( $by_seq{$_}, $detail->{$_} ) } @stale;
            Odoo::Error->throw(
                kind    => 'refused',
                code    => 'stale',
                message => 'plan is stale: live data differs from the before-image of change(s) '
                    . join( ', ', @stale ) . ' (' . join( '; ', @what ) . ') - re-plan',
                fix => $plan->op eq 'revert'
                    ? 'plan the revert again: a record that moved on since is held as changed-since, not undone'
                    : 'plan again (oom-ops run): the record changed between planning and applying',
            );
        }

        my $journal = Odoo::Ops::Journal->create( $journal_path, blob_min => $ctx->config->blob_min );
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
        my ( %created, %written, %unlinked, @custom, @failed, @held );    # what the result reports back
        my $record = sub ( $c, $entry, $outcome ) {
            $refs{ $c->{ref} } = $entry->{id} if $outcome eq 'done' && defined $c->{ref};
            if ( $outcome eq 'done' ) {
                my %made = ( create => \%created, write => \%written, unlink => \%unlinked );
                push @{ $made{ $c->{action} }{ $c->{model} } }, $entry->{id} // $c->{id} if $made{ $c->{action} };
                push @custom, { key => $c->{key}, kind => $c->{kind}, returned => $entry->{returned}, ( $entry->{created} ? ( created => $entry->{created} ) : () ) } if $c->{action} eq 'custom';
                # a custom change that made or changed a record says which, so its id is where ids are (created, written), not only in custom
                if ( $c->{action} eq 'custom' && ( $entry->{reported} // '' ) =~ /^(create|write)\z/ && defined( my $rid = $entry->{id} // $c->{id} ) ) {
                    push @{ ( $1 eq 'create' ? \%created : \%written )->{ $c->{model} } }, $rid;
                }
            }
            $entry->{outcome} = $outcome;
            # the audit trail names every button pressed, and what Odoo answered
            $class->_audit_action( $ctx, $c, $entry ) if $c->{action} eq 'custom' && ( $c->{handler} // '' ) =~ /\A(?:core\.(?:action|wizard)|discuss\.\w+)\z/;
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
            # the screen says why too, not only the journal
            push @failed, { seq => $c->{seq}, key => $c->{key}, action => $c->{action}, model => $c->{model},
                id => $entry->{id} // $c->{id}, message => $entry->{error}{message} };
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
            my @run = ( $resolve->($c) );
            if ( $batch > 1 && _batchable($c) && !( $ctx->trail && $ctx->trail->broken ) ) {
                while ( @run < $batch && $i + @run < @changes && $wanted->( $changes[ $i + @run ] ) && _batchable( $changes[ $i + @run ] ) && _same_batch( $c, $changes[ $i + @run ] ) ) {
                    push @run, $resolve->( $changes[ $i + @run ] );
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
                if ( my $o = $orig{ $c->{seq} } ) { $entry{$_} = $o->{$_} for grep { exists $o->{$_} } qw(before vals) }
                my $outcome = 'done';
                if ( $c->{action} eq 'skip' || $c->{action} eq 'hold' ) {
                    $outcome = $c->{action} eq 'skip' ? 'skipped' : 'held';
                }
                elsif ( $c->{action} eq 'create' && $c->{unique_by}
                    && defined( my $have = $class->_existing( $client, $c ) ) )
                {
                    # Another plan (or a person) created it since planning.
                    $entry{id}     = $have;
                    $entry{reason} = 'already exists by ' . ( _unique($c) )[0] . '; reused';
                    $outcome       = 'skipped';
                    $refs{ $c->{ref} } = $have if defined $c->{ref};
                }
                else {
                    my $ok = eval {
                        $ctx->audit->ready;
                        # id_ref: a custom change on a record an earlier change makes; its id is known now
                        my $resolved = { %$c, vals => _resolve_refs( $c->{vals}, \%refs ),
                            ( defined $c->{id_ref} ? ( id => _resolve_refs( { '$ref' => $c->{id_ref} }, \%refs ) ) : () ) };
                        $entry{vals} = $orig{ $c->{seq} } ? _resolve_refs( $orig{ $c->{seq} }{vals}, \%refs ) : $resolved->{vals} if exists $c->{vals};
                        my $after = $class->_do_change( $client, $resolved, \%entry, $ctx );
                        if ($after) { $verified++ } else { $not_verified++ }
                        1;
                    };
                    if ( !$ok ) {
                        my $err = $@;
                        # Odoo asked which way a backorder goes and the change did not say: held, with the moves
                        # short, for the caller to decide (the transfer stays staged)
                        if ( blessed($err) && $err->isa('Odoo::Error') && $err->kind eq 'refused' && ( $err->code // '' ) eq 'backorder-choice' ) {
                            $outcome = 'held';
                            $entry{reason} = $err->message . '; fix: ' . $err->fix;
                            $entry{hold}   = 'backorder-choice';
                            push @held, { seq => $c->{seq}, key => $c->{key}, bucket => $c->{bucket}, hold => 'backorder-choice', reason => $entry{reason} };
                        }
                        else { $outcome = 'failed'; $fail->( $c, \%entry, $err ) }
                    }
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
            created          => \%created,
            written          => \%written,
            unlinked         => \%unlinked,
            custom           => \@custom,
            failed_changes   => \@failed,
            held_changes     => \@held,
            invariants       => \@inv_rows,
            invariants_failed => $inv_failed,
        );
        # the run record follows the journal; a folder that cannot take it does not undo the apply
        my $idx = eval { Odoo::Ops::Runs->record_applied( $dir, $result, by => $ctx->actor, now => $finished, plan => $plan ) };
        $class->_audit_run( $ctx, $plan, $dir, $idx, $result, \%created, \%written, \%unlinked, \@custom );
        return $result;
    } );
}

# The audit line of a core.action or core.wizard change that was applied: the
# method, the state before and after, Odoo's answer in OOM's words. No value.
sub _audit_action ($class, $ctx, $c, $entry) {
    return if !$ctx->trail || ( $entry->{outcome} // '' ) ne 'done';
    my $r = ref $entry->{returned} eq 'HASH' ? $entry->{returned} : {};
    my $v = ref $c->{vals} eq 'HASH' ? $c->{vals} : {};
    my @ids = ref $v->{ids} eq 'ARRAY' && @{ $v->{ids} } ? @{ $v->{ids} } : ( defined $c->{id} ? ( $c->{id} ) : () );
    eval {
        $ctx->trail->event( action =>
            op => $c->{handler}, outcome => 'applied', model => $c->{model}, ids => \@ids,
            method => $r->{method} // $v->{method},
            ( ( $v->{on} // "" ) eq "model" ? ( args_count => scalar @{ $v->{args} // [] } ) : () ),
            ( exists $r->{state_before} ? ( state_before => $r->{state_before} ) : () ),
            ( exists $r->{state_after}  ? ( state_after  => $r->{state_after} )  : () ),
            ( defined $r->{says} ? ( answer => $r->{says} ) : () ),
            ( ref $r->{created} eq 'ARRAY' ? ( created => $r->{created} ) : () ),
        );
    };
    return;
}

# The audit line of an apply, a revert or a resume that finished: the run's state,
# the counts, and every record it wrote as model:id.
sub _audit_run ($class, $ctx, $plan, $dir, $idx, $result, $created, $written, $unlinked, $custom) {
    return if !$ctx->trail;
    my $h     = $result->to_hash;
    my $c     = $h->{counts} // {};
    my $p     = $plan->{params} // {};
    my $event = $plan->op eq 'revert' ? 'revert' : defined $p->{resumes} ? 'resume' : 'apply';
    my $state = $idx ? ( $idx->{outcome} // $idx->{state} ) : undef;
    $state //= !( $c->{failed} || $c->{not_attempted} ) ? 'applied' : $c->{done} ? 'partly-applied' : 'failed';
    my @touched;
    for my $m ( $created, $written, $unlinked ) {
        for my $model ( sort keys %$m ) { push @touched, map { "$model:$_" } grep { defined } @{ $m->{$model} } }
    }
    my %seen;
    @touched = grep { !$seen{$_}++ } @touched;
    eval {
        $ctx->trail->event( $event =>
            op => $plan->op, run => File::Basename::basename($dir), outcome => $state,
            changes => { done => $c->{done} // 0, failed => $c->{failed} // 0, held => $c->{held} // 0 },
            touched => \@touched,
        );
    };
    return;
}

# does the plan's declared scope let the apply read this model?
sub _scope_reads ($plan, $model) {
    return scalar grep { $_ eq 'search_read' } @{ $plan->scope->{$model} // [] };
}

sub _entry ($c) {

    return map { $_ => $c->{$_} } grep { exists $c->{$_} }
        qw(seq bucket action kind model id method handler before vals key ref support context reason);
}

# a plain create: no reference to an earlier change's id, nothing narrowing the read-back
sub _batchable ($c) {
    return $c->{action} eq 'create' && !$c->{readback} && !Odoo::Ops::Plan::_refs_in( $c->{vals} )
        && !_composite($c);
}

sub _same_batch ($a, $b) {
    return $a->{model} eq $b->{model}
        && Odoo::Ops::json()->encode( $a->{unique_by} // '' ) eq Odoo::Ops::json()->encode( $b->{unique_by} // '' )
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
    if ( $first->{unique_by} ) {
        # the same comparison as the single path, as one OR
        my ( $f, $fold ) = _unique($first);
        my $key    = sub ($v) { $fold ? lc( $v // '' ) : ( $v // '' ) };
        my @terms  = map { _unique_term( $f, $fold, $_->{vals}{$f} ) } @$run;
        my @domain = ( ('|') x ( @terms - 1 ), @terms );
        my %have;
        for my $row ( @{ $model->search_read( \@domain, [$f] ) } ) {
            $have{ $key->( $row->{$f} ) } //= $row->{id};
        }
        for my $c (@$run) {
            if ( defined( my $id = $have{ $key->( $c->{vals}{$f} ) } ) ) {
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

# A composite unique_by is { fields => [ 'order_id', { field => 'name', fold => 1 } ] }:
# every part must match at once. It is looked up one create at a time.
sub _composite ($c) {
    my $u = $c->{unique_by};
    return ref $u eq 'HASH' && ref $u->{fields} eq 'ARRAY';
}

# The parts of a composite unique_by as (field, fold) pairs.
sub _parts ($c) {
    return map { ref $_ ? [ $_->{field}, $_->{fold} ? 1 : 0 ] : [ $_, 0 ] } @{ $c->{unique_by}{fields} };
}

# A create's unique_by as (field, fold): the plain string means an exact
# match; { field => 'email', fold => 1 } means case-insensitive.
sub _unique ($c) {
    my $u = $c->{unique_by};
    return ( join( '+', map { $_->[0] } _parts($c) ), 0 ) if _composite($c);
    return ref $u eq 'HASH' ? ( $u->{field}, $u->{fold} ? 1 : 0 ) : ( $u, 0 );
}

# One term of the lookup. =ilike reads its value as a LIKE pattern, where
# _ and % are wildcards and a backslash escapes (Odoo hands the value to
# SQL ILIKE: proved on 16, t/84), so a folded value has all three escaped
# and first_last@x.com never matches firstXlast@x.com. An exact match
# uses =, which has no wildcards and does not fold case.
sub _unique_term ($f, $fold, $value) {
    return [ $f, '=', $value ] if !$fold;
    my $esc = $value // '';
    $esc =~ s/([\\_%])/\\$1/g;
    return [ $f, '=ilike', $esc ];
}

# The id of a record matching a create's unique_by field, if any.
sub _existing ($class, $client, $c) {
    my ( $f, $fold ) = _unique($c);
    my @domain = _composite($c)
        ? map { _unique_term( $_->[0], $_->[1], $c->{vals}{ $_->[0] } ) } _parts($c)
        : ( _unique_term( $f, $fold, $c->{vals}{$f} ) );
    my $rows = $client->model( $c->{model} )->search_read( \@domain, ['id'], limit => 1 );
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
sub _do_change ($class, $client, $c, $entry, $ctx = undef) {
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
        my $after = $class->_read_back( $model, $c->{id}, $c->{vals} );
        $entry->{after} = $after;
        # an undo says what it meant to put back (restores): the read-back
        # is compared with it, and a field that did not take is named
        if ( my $want = $c->{restores} ) {
            my @bad = map { $_->[0] } _diffs( $want, $after );
            if (@bad) { $entry->{unrestored} = \@bad; return undef }
        }
        return $after;
    }
    if ( $action eq 'unlink' ) {
        $model->unlink( $c->{id} );
        # Absence is the read-back. It is a read, not a count, because every
        # operation that unlinks already declares read on the model (a
        # search_count would be refused by the scope of an older operation);
        # Odoo 16 answers a read of a deleted id with no row, or with
        # MissingError, and either is "gone". The field asked for matters:
        # a read of 'id' alone is answered without touching the database
        # (live, 2026-10-15, t/84), so display_name is read, which every
        # model has.
        my $rows = eval { $model->read( [ $c->{id} ], ['display_name'] ) };
        my $err  = $@;
        my $gone = !$err ? !@{ $rows // [] }
            : ( blessed($err) && $err->isa('Odoo::Error') && ( $err->fault_category // '' ) eq 'missing' );
        die $err if $err && !$gone;
        return $gone ? ( $entry->{after} = { id => $c->{id}, absent => JSON::PP::true } ) : undef;
    }
    if ( $action eq 'custom' ) {
        # The operation that planned it knows how to carry it out.
        my $class = Odoo::Ops::Registry->new->class_for( $c->{handler} );
        # OOM_STRICT_CALLS=1 (the offline suite sets it): the apply may make only the calls the change declared
        local $Odoo::Ops::Guard::DECLARED = $ENV{OOM_STRICT_CALLS} && ref $c->{calls} eq 'ARRAY' ? { map { ( "$_->[0].$_->[1]" => 1 ) } @{ $c->{calls} } } : undef;
        my $out = $class->apply_custom( $client, $c );
        $entry->{id}       = $out->{id} if defined $out->{id};
        $entry->{returned} = $out->{returned} if exists $out->{returned};
        $entry->{reported} = $out->{reported} if defined $out->{reported};
        # what Odoo made as a side effect of the method (core.action, core.wizard): [ { model, id, name, state } ]
        $entry->{created} = $out->{created} if ref $out->{created} eq 'ARRAY' && @{ $out->{created} };
        return $out->{after};
    }
    if ( $action eq 'call' ) {
        my $ids = $c->{ids} // ( $c->{id} ? [ $c->{id} ] : [] );
        # no verify: the model's state, when its behaviour file names one, is read before and after
        my ( $sfield, $sbefore, $swhy ) = $c->{verify} ? () : $class->_call_state( $ctx, $client, $c->{model}, $ids );
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
        if ( defined $sfield ) {
            my $rows = $client->model( $c->{model} )->read( $ids, [$sfield] );
            my %now = map { $_->{id} => $_->{$sfield} } @$rows;
            if ( !@$rows || @$rows != @$ids ) {
                $entry->{unverified} = "the call was made and $c->{model} " . ( @$rows ? 'some of ' : '' ) . "$c->{method}'s records no longer read ($sfield could not be read back)";
                return undef;
            }
            $entry->{state_read} = join( '; ', map { (@$ids > 1 ? "$_: " : '') . "$sfield " . ($sbefore->{$_} // 'none') . ' -> ' . ($now{$_} // 'none') } @$ids );
            return $entry->{after} = { ids => [@$ids], $sfield => ( @$ids == 1 ? $now{ $ids->[0] } : \%now ) };
        }
        $entry->{unverified} = $swhy if defined $swhy;
        return undef;
    }
    Odoo::Error->throw( kind => 'usage', message => "cannot apply action '$action'" );
}

# The state field a call is read back by: the one the model's behaviour file
# names, read before the call. Returns (field, { id => state }) or, for a call
# that stays not verified, (undef, undef, the reason, in words).
sub _call_state ($class, $ctx, $client, $model, $ids) {
    return ( undef, undef, undef ) if !@$ids;
    my $st = $ctx ? $ctx->behaviour($model)->state_info : undef;
    return ( undef, undef, "not verified: $model names no state field in its behaviour file, and the call named no verify" ) if !$st || !defined $st->{field};
    my $field = $st->{field};
    return ( undef, undef, "not verified: $model has no field '$field' on this server" ) if !$client->model($model)->fields->{$field};
    return ( undef, undef, "not verified: the operation's scope does not read $model" ) if $ctx->guard->can('allows') && !$ctx->guard->allows( $model, 'read' );
    my $rows = $client->model($model)->read( $ids, [$field] );
    return ( $field, { map { $_->{id} => $_->{$field} } @$rows } );
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

# Fields Odoo moves on its own, or that other people's activity moves:
# never compared when deciding whether a record changed since a journal or
# a plan, or a revert would be refused over a timestamp.
my %MOVES_ALONE = map { $_ => 1 } qw(id write_date write_uid __last_update message_ids activity_ids);

# The fields where a wanted image and a live row differ, as
# [ field, was, now ], sorted by field. Only fields the image holds are
# compared, or only those in $only when given.
# $volatile: the fields the model's behaviour file says Odoo maintains itself
# (a counter a confirm bumps), left out beside the ones every model leaves out
sub _diffs ($want, $live, $only = undef, $volatile = undef) {
    my @f = $only ? @$only : keys %$want;
    return map { [ $_, $want->{$_}, $live->{$_} ] }
        sort grep { !$MOVES_ALONE{$_} && !( $volatile && $volatile->{$_} ) && exists $want->{$_} && _norm( $want->{$_} ) ne _norm( $live->{$_} ) } @f;
}

# the volatile fields of a model as a set, from its behaviour file
sub _volatile ($ctx, $model) {
    return undef if !$ctx;
    my %v = map { $_ => 1 } $ctx->behaviour($model)->volatile;
    return %v ? \%v : undef;
}

# Empty for a difference: undef, '', or the number 0 (a boolean, or the 0 an old
# journal holds for Odoo's false). The string "0" is a value.
sub _blank ($v) {
    return 1 if Odoo::Portable::is_false_value($v);
    return !ref $v && $v eq '' ? 1 : 0;
}

# a value as a person reads it in a difference: ids as [8], empties as []
# or false, a many2one as its id
sub _show ($v) {
    return 'false' if _blank($v);
    if ( ref $v eq 'ARRAY' ) {
        return $v->[0] if @$v == 2 && !ref $v->[0] && defined $v->[1] && $v->[1] !~ /^-?\d+\z/;
        return '[' . join( ', ', sort { $a <=> $b } grep { !ref } @$v ) . ']';
    }
    return Odoo::Ops::json()->encode($v) if ref $v;
    return '(' . length($v) . ' characters)' if length($v) > 200;
    return "$v";
}

sub _diff_words ($diffs) {
    return join ', ', map { "$_->[0]: " . _show( $_->[1] ) . ' -> ' . _show( $_->[2] ) } @$diffs;
}

sub _stale_words ($c, $d) {
    my $what = "$c->{model} $c->{id}";
    return "$what is gone" if $d->{gone};
    return "$what: " . _diff_words( $d->{diffs} );
}

# The changes whose before-image no longer matches the live record, as
# seq => { gone => 1 } or seq => { diffs => [[field, was, now], ...] }.
sub _stale_detail ($class, $client, $changes, $ctx = undef) {
    my %by_model;
    for my $c (@$changes) {
        next if $c->{action} !~ /^(write|unlink|custom|call)\z/;
        next if ref $c->{before} ne 'HASH' || !$c->{id};
        push @{ $by_model{ $c->{model} } }, $c;
    }
    my %stale;
    for my $m ( sort keys %by_model ) {
        my @cs = @{ $by_model{$m} };
        my %fields;
        for my $c (@cs) { $fields{$_} = 1 for grep { $_ ne 'id' } keys %{ $c->{before} } }
        my @ids  = map { $_->{id} } @cs;
        my $rows = $client->model($m)->read( \@ids, [ sort keys %fields ] );
        my %live = map { $_->{id} => $_ } @$rows;
        for my $c (@cs) {
            my $now = $live{ $c->{id} };
            if ( !$now ) { $stale{ $c->{seq} } = { gone => 1 }; next }
            my @d = _diffs( $c->{before}, $now, undef, _volatile( $ctx, $m ) );
            $stale{ $c->{seq} } = { diffs => \@d } if @d;
        }
    }
    return \%stale;
}

sub _stale_changes ($class, $client, $changes, $ctx = undef) {
    return sort { $a <=> $b } keys %{ $class->_stale_detail( $client, $changes, $ctx ) };
}

# Comparable form of a read value: many2one [id, label] -> its id, the same
# as a bare id (labels drift without the record changing, and a plan may hold
# either form); id lists sorted; empties equal.
sub _norm ($v) {
    return '' if _blank($v);
    if ( ref $v eq 'ARRAY' ) {
        return "$v->[0]" if @$v == 2 && !ref $v->[0] && defined $v->[1] && $v->[1] !~ /^-?\d+\z/;
        return 'ids:' . join ',', sort { $a <=> $b } grep { !ref } @$v;
    }
    return Odoo::Ops::json()->encode($v) if ref $v;
    return "$v";
}

# A journal is bound to its instance: url, db and login. The one exception is an administrator undoing
# another login's run on the same url and db (owner ruling, 2026-10-16): returns that login, or undef when the
# journal is this config's own. never => 1 keeps the binding whole (a resume of an ordinary apply).
sub _journal_owner ($class, $ctx, $header, $verb, %o) {
    my $was  = $header->{instance} // {};
    my $mine = $ctx->instance;
    my $json = Odoo::Ops::json();
    return undef if $json->encode($was) eq $json->encode($mine);
    my $same_server = ( $was->{url} // '' ) eq ( $mine->{url} // '' ) && ( $was->{db} // '' ) eq ( $mine->{db} // '' );
    return ( $was->{login} // 'another login' ) if $same_server && !$o{never} && $class->is_admin( $ctx, $verb );
    my $who = $was->{login} // 'another login';
    Odoo::Error->throw(
        kind    => 'refused',
        code    => 'instance',
        message => 'journal was written against a different instance than this config',
        fix     => !$same_server ? 'use the config of the instance the run was made against'
            : $o{never} ? "the run was made by $who: resume it with $who\'s config (finishing another user's write is not an administrator's to do)"
            :             "the run was made by $who: revert it with $who\'s config, or with an administrator's config (a member of base.group_system)",
    );
}

=head2 is_admin($ctx, $op)

True when Odoo says the config's user is a member of C<base.group_system>
(C<has_group>, asked at plan time). It is a model method on 16 and a
record method on later series, as L<Odoo::Ops::Core::Doctor> asks it. An
answer that cannot be had is no.

=cut

sub is_admin ($class, $ctx, $op = 'revert') {
    my $client = $ctx->client;
    return $ctx->guard->with_scope( { 'res.users' => ['has_group'] }, $op, sub {
        for my $args ( [ ['base.group_system'] ], [ [ [ $client->uid ], 'base.group_system' ] ] ) {
            my $r = eval { $client->execute_kw( 'res.users', 'has_group', $args->[0] ) };
            return $r ? 1 : 0 if defined $r && !$@;
        }
        return 0;
    } );
}

=head2 revert_plan($ctx, $journal_path)

A new, unapplied plan undoing the journal's done changes, newest
first.

=cut

sub revert_plan ($class, $ctx, $journal_path) {
    Odoo::Ops::Runs->refuse_closed( _dir_of($journal_path) );
    my ( $header, $changes ) = Odoo::Ops::Journal->read($journal_path);
    my $other = $class->_journal_owner( $ctx, $header, 'revert' );

    my @done = reverse grep { $_->{outcome} eq 'done' } @$changes;
    # A value the journal holds as a blob comes back for an undo that must put it back (a write, a custom
    # change). A create is undone by deleting the record, so its after-image is compared without the
    # blob-held fields and no blob is read.
    my $blobs = Odoo::Ops::Blob->source( dirs => [ _dir_of($journal_path) ] );
    @done = map {
        my $c = $_;
        $c->{action} eq 'create' ? { %$c, ( ref $c->{after} eq 'HASH' ? ( after => Odoo::Ops::Blob->strip( $c->{after} ) ) : () ) }
        : $c->{action} =~ /^(?:write|custom)\z/ ? $blobs->resolve($c)
        : $c
    } @done;
    my $plan = Odoo::Ops::Plan->new(
        blob_min    => $ctx->config->blob_min,

        op          => 'revert',
        params      => { journal => $journal_path, reverts => $journal_path, of => $header->{plan_fingerprint}, of_op => $header->{op},
            ( defined $other ? ( reverted_for => $other ) : () ) },
        instance    => $ctx->instance,
        input_count => scalar @done,
        created     => Odoo::Ops::iso_time( $ctx->now ),
        actor       => $ctx->actor,
    );
    my %scope;

    # What the records are now, against what the journal says the run left:
    # a create is undone only while the record is as it was made, a write
    # only while the fields it set are as it left them. Read once per model,
    # in a scope that names exactly these reads.
    my %moved = $class->_moved_since( $ctx, \@done );

    # Who points at the records about to be unlinked (item 12): found
    # through ir.model.fields, counted per referencing field.
    my %undo_ids;
    for my $c (@done) {
        $undo_ids{ $c->{model} }{ $c->{id} } = 1 if $c->{action} eq 'create' && !$moved{ $c->{seq} };
    }
    my $inbound = $class->_inbound( $ctx, \%undo_ids );
    my $states  = $class->_states_of( $ctx, \%undo_ids );
    my ( $ref_rows, $ref_records ) = ( 0, 0 );
    my %made_by;    # model => ids Odoo made as a side effect of the actions being reverted

    for my $c (@done) {
        if ( $c->{action} eq 'create' || $c->{action} eq 'write' ) {
            if ( my $m = $moved{ $c->{seq} } ) {
                my $what = $m->{gone} ? "$c->{model} $c->{id} is already gone"
                    : "$c->{model} $c->{id} has moved on since (" . _diff_words( $m->{diffs} ) . ')';
                $plan->add(
                    bucket => 'changed-since', action => 'hold', model => $c->{model}, id => $c->{id},
                    of_seq => $c->{seq}, undoes => $c->{seq},
                    reason => "$what. A create is undone only while the record is as it was made; "
                        . 'a write only while the fields it set are as it left them.',
                );
                next;
            }
        }
        if ( $c->{action} eq 'create' ) {
            if ( my $fact = _state_fact( $ctx, $c, $states ) ) { $plan->note($fact) }
            my $refs = $inbound->{refs}{ $c->{model} }{ $c->{id} } // [];
            my @effects = map { { effect => _inbound_words($_), suppressed => 0, evidence => 'ir.model.fields', references => $_ } } @$refs;
            my ($restrict) = grep { $_->{on_delete} eq 'restrict' } @$refs;
            if (@$refs) { $ref_records++; $ref_rows += $_->{count} for @$refs }
            if ($restrict) {
                $plan->add(
                    bucket => 'referenced', action => 'hold', model => $c->{model}, id => $c->{id},
                    of_seq => $c->{seq}, undoes => $c->{seq}, effects => \@effects,
                    reason => "$restrict->{count} $restrict->{model} row(s) point at $c->{model} $c->{id} through "
                        . "$restrict->{field} with ondelete restrict, so Odoo would refuse the delete; remove or repoint them first",
                );
                next;
            }
            $plan->add(
                bucket => 'undo-create', action => 'unlink', model => $c->{model},
                id => $c->{id}, before => $c->{after}, of_seq => $c->{seq}, undoes => $c->{seq},
                ( @effects ? ( effects => \@effects ) : () ),
            );
            $scope{ $c->{model} }{$_} = 1 for qw(read unlink);
        }
        elsif ( $c->{action} eq 'write' ) {
            my $types = $ctx->client->model( $c->{model} )->fields;
            my ( %back, %restores );
            for my $f ( keys %{ $c->{vals} } ) {
                $back{$f}     = _writable( $c->{before}{$f}, $types->{$f}{type} // '' );
                $restores{$f} = $c->{before}{$f};
            }
            $plan->add(
                bucket => 'undo-write', action => 'write', model => $c->{model},
                id => $c->{id}, vals => \%back, before => $c->{after}, of_seq => $c->{seq}, undoes => $c->{seq},
                restores => \%restores,
            );
            $scope{ $c->{model} }{$_} = 1 for qw(read write);
        }
        elsif ( $c->{action} eq 'custom' ) {
            my ( $undo, $why, $handler ) = $class->_undo_custom($c);
            # what the action made is named on the revert's line; the revert never plans a change to it
            # an undo that removes what the change made (unmakes) is not told that Odoo made it
            my @made = ref $c->{created} eq 'ARRAY' && !( $undo && $undo->{unmakes} ) ? @{ $c->{created} } : ();
            if (@made) {
                my $words = 'Odoo made ' . join( ', ', map { Odoo::Ops::PlanPrint::made_text($_) } @made ) . ' when it ran; the revert does not remove it';
                push @{ $made_by{ $_->{model} } }, $_->{id} for @made;
                if ($undo) { $undo->{line} = ( $undo->{line} // '' ) . "; $words"; $undo->{reason} = ( $undo->{reason} // '' ) . "; $words" }
                else        { $why = ( $why // "$c->{handler} has no inverse (e.g. a sent email)" ) . "; $words" }
            }
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
    $plan->note( "Odoo made $_ " . join( ', ', @{ $made_by{$_} } ) . " while the run's actions ran; the revert plans no change to them" ) for sort keys %made_by;
    $plan->note( "this run was applied by $other; you revert it as an administrator (" . $ctx->instance->{login} . ')' ) if defined $other;
    $plan->note( 'compared before undoing: the fields the journal image holds (a create) or the write set (a write), '
            . 'not ' . join( ', ', grep { $_ ne 'id' } sort keys %MOVES_ALONE ) )
        if grep { $_->{action} eq 'create' || $_->{action} eq 'write' } @done;
    $plan->note("inbound references: $ref_rows row(s) point at $ref_records record(s) about to be deleted (see effects on each change)")
        if $ref_rows;
    $plan->note( 'inbound references not counted: ' . join( ', ', map { "$_ ($inbound->{unknown}{$_})" } sort keys %{ $inbound->{unknown} } ) )
        if %{ $inbound->{unknown} };
    $plan->set_scope($ps);
    return $plan->finalize;
}

# { model => { id => state } } for the records about to be unlinked whose model
# says Odoo deletes it only from certain states (a behaviour file's
# unlink_requires): one read per such model, of the state field alone. A line
# model whose rule reads its parent's state (unlink_requires.parent) gets
# { model => { id => { state, parent_model, parent_id, parent_name } } }: one
# read of the lines for the parent field, one of the parents for state and name.
sub _states_of ($class, $ctx, $undo_ids) {
    my %out;
    for my $m ( sort keys %$undo_ids ) {
        my $beh = $ctx->behaviour($m);
        next if !$beh->unlink_requires;
        if ( my $pf = $beh->parent_field ) {
            my @ids = sort { $a <=> $b } keys %{ $undo_ids->{$m} };
            my $pm  = $ctx->client->model($m)->fields->{$pf}{relation}
                or Odoo::Error->throw( kind => 'config', message => "behaviour of $m: unlink_requires parent '$pf' is not a relation of $m" );
            my $lines = $ctx->guard->with_scope( { $m => ['read'] }, 'revert', sub { $ctx->client->model($m)->read( \@ids, [$pf] ) } );
            my %pid = map { $_->{id} => ref $_->{$pf} eq 'ARRAY' ? $_->{$pf}[0] : $_->{$pf} } @$lines;
            my @pids = sort { $a <=> $b } keys %{ { map { $_ => 1 } grep { $_ } values %pid } };
            next if !@pids;
            my $ps = $ctx->guard->with_scope( { $pm => ['read'] }, 'revert', sub { $ctx->client->model($pm)->read( \@pids, [ 'state', 'name' ] ) } );
            my %p = map { $_->{id} => $_ } @$ps;
            for my $id (@ids) {
                my $par = $p{ $pid{$id} // 0 } or next;
                $out{$m}{$id} = { state => $par->{state}, parent_model => $pm, parent_id => $par->{id}, parent_name => $par->{name} };
            }
            next;
        }
        next if !$beh->state_rule;
        my $sf  = $beh->state_rule->{field};
        my @ids = sort { $a <=> $b } keys %{ $undo_ids->{$m} };
        my $rows = $ctx->guard->with_scope( { $m => ['read'] }, 'revert', sub { $ctx->client->model($m)->read( \@ids, [$sf] ) } );
        $out{$m} = { map { $_->{id} => $_->{$sf} } @$rows };
    }
    return \%out;
}

# "a move", "an order": the article follows the noun's first sound. The nouns
# in the behaviour files are plain English words, so the vowel letters decide.
sub _with_article ($noun) {
    return ( $noun =~ /^[aeiou]/i ? 'an ' : 'a ' ) . $noun;
}

# The state of a record about to be deleted, as a fact for the plan, or undef
# when it is a state Odoo deletes from. A line is judged by its parent's state.
# The delete is still planned and Odoo refuses at apply if it must; the note
# names the state operations the pack has for the record that holds the state.
sub _state_fact ($ctx, $c, $states) {
    my $state = $states->{ $c->{model} }{ $c->{id} };
    return undef if !defined $state;
    my $u = $ctx->behaviour( $c->{model} )->unlink_requires;
    my ( $st, $who, $of, $holder ) = ( $state, "$c->{model} $c->{id}", $u->{noun} ? _with_article( $u->{noun} ) : 'a record of this model', $c->{model} );
    if ( ref $state eq 'HASH' ) {
        my $nm = defined $state->{parent_name} && $state->{parent_name} ne '' && $state->{parent_name} ne '0' ? "$state->{parent_name} " : '';
        ( $st, $who, $of, $holder ) = ( $state->{state}, "$c->{model} $c->{id}: its " . ( $u->{noun} // 'parent' ) . " $nm($state->{parent_id})", 'a line', $state->{parent_model} );
    }
    return undef if !defined $st || grep { $_ eq $st } @{ $u->{state} };
    my $sr  = $ctx->behaviour($holder)->state_rule;
    my @ops = $sr ? @{ $sr->{operations} // [] } : ();
    return "$who is " . ( $st eq 'posted' ? 'posted' : "in state $st" ) . "; Odoo deletes $of only from " . join( ' or ', @{ $u->{state} } )
        . ( @ops ? "; state operations for $holder: " . join( ', ', @ops ) : '' );
}

# seq => { diffs => [...] } or { gone => 1 } for every done create and write
# whose live record no longer matches what the journal says the run left.
# A create compares every field its after-image holds; a write only the
# fields it set. An entry with no after-image cannot be compared and is
# left to the stale check at apply.
sub _moved_since ($class, $ctx, $done) {
    my ( %want, %fields );
    for my $c (@$done) {
        next if $c->{action} !~ /^(create|write)\z/ || ref $c->{after} ne 'HASH';
        my @f = $c->{action} eq 'write' ? keys %{ $c->{vals} // {} } : keys %{ $c->{after} };
        my $vol = _volatile( $ctx, $c->{model} );
        @f = grep { !$MOVES_ALONE{$_} && !( $vol && $vol->{$_} ) && exists $c->{after}{$_} } @f;
        $want{ $c->{seq} } = [ $c, \@f ];
        $fields{ $c->{model} }{$_} = 1 for @f;
    }
    return () if !%want;
    my %live;
    my $scope = { map { $_ => ['read'] } keys %fields };
    $ctx->guard->with_scope( $scope, 'revert', sub {
        for my $m ( sort keys %fields ) {
            my @ids = map { $_->[0]{id} } grep { $_->[0]{model} eq $m } values %want;
            $live{$m} = { map { $_->{id} => $_ } @{ $ctx->client->model($m)->read( \@ids, [ sort keys %{ $fields{$m} } ] ) } };
        }
    } );
    my %moved;
    for my $seq ( keys %want ) {
        my ( $c, $f ) = @{ $want{$seq} };
        my $now = $live{ $c->{model} }{ $c->{id} };
        if ( !$now ) { $moved{$seq} = { gone => 1 }; next }
        my @d = _diffs( $c->{after}, $now, $f, _volatile( $ctx, $c->{model} ) );
        $moved{$seq} = { diffs => \@d } if @d;
    }
    return %moved;
}

# Stored many2one and many2many fields of other models that target a
# model, and the many2one_reference fields (res_model/res_id pairs: they
# carry no relation in ir.model.fields, so they are found by type and
# counted for the model by name). Models that only keep notes about every
# record (messages, followers, attachments) are left out: Odoo cleans them
# up itself and they would drown the rows that matter.
my %NOISE = map { $_ => 1 } qw(mail.message mail.followers mail.activity ir.attachment ir.model.data mail.mail);

# { refs => { model => { id => [ {model field ttype on_delete count} ] } },
#   unknown => { model => why } }   why: 'access refused' or the fault class
# One ir.model.fields search per model being unlinked, one search_read per
# referencing field for all its ids at once (so the cost is the number of
# referencing fields, not records times fields). A referencing model this
# user cannot read is counted unknown. Rows that are themselves being
# unlinked by this revert are not "others".
sub _inbound ($class, $ctx, $undo_ids) {
    my %out = ( refs => {}, unknown => {} );
    return \%out if !%$undo_ids;
    my $client = $ctx->client;
    my $T      = JSON::PP::true;
    my %fields_of;
    # a user who cannot read ir.model.fields (or a server without it) learns
    # nothing about references; say so rather than stop the revert
    my $looked = eval { $ctx->guard->with_scope( { 'ir.model.fields' => ['search_read'] }, 'revert', sub {
        for my $m ( sort keys %$undo_ids ) {
            my $f = $client->model('ir.model.fields');
            my $rel = $f->search_read(
                [ [ 'relation', '=', $m ], [ 'ttype', 'in', [qw(many2one many2many)] ], [ 'store', '=', $T ] ],
                [qw(model name ttype on_delete)] );
            my $ref = $f->search_read( [ [ 'ttype', '=', 'many2one_reference' ], [ 'store', '=', $T ] ], [qw(model name ttype)] );
            $fields_of{$m} = [ grep { !$NOISE{ $_->{model} } } @$rel, @$ref ];
        }
        1;
    } ) };
    if ( !$looked ) {
        my $e = $@;
        die $e if !( blessed($e) && $e->isa('Odoo::Error') && $e->kind eq 'fault' );
        $out{unknown}{'ir.model.fields'} = $e->is_access_denied ? 'access refused' : ( ( $e->fault_class // 'fault' ) =~ s/.*\.//r );
        return \%out;
    }
    # transient and abstract models hold no stored row that could point here,
    # so they are not walked at all (and never reported as unreadable)
    my %skip = $class->_unstored_models( $ctx, map { $_->{model} } map { @$_ } values %fields_of );
    for my $m ( sort keys %$undo_ids ) {
        my @ids = sort { $a <=> $b } keys %{ $undo_ids->{$m} };
        for my $rf ( grep { !$skip{ $_->{model} } } @{ $fields_of{$m} } ) {
            my ( $rm, $name, $ttype ) = @$rf{qw(model name ttype)};
            my $scope = { $rm => ['search_read'] };
            my @domain = ( [ $name, 'in', \@ids ] );
            my $mfield;
            if ( $ttype eq 'many2one_reference' ) {
                # the field holding the target model's name sits beside res_id
                my $types = eval { $ctx->guard->with_scope( {}, 'revert', sub { $client->model($rm)->fields } ) } // {};
                ($mfield) = grep { ( $types->{$_}{type} // '' ) eq 'char' } qw(res_model model);
                next if !$mfield;
                push @domain, [ $mfield, '=', $m ];
            }
            my $rows = eval {
                $ctx->guard->with_scope( $scope, 'revert', sub {
                    $client->model($rm)->search_read( \@domain, [$name], limit => 5000, context => { active_test => JSON::PP::false } );
                } );
            };
            if ( !$rows ) {
                my $e = $@;
                # a model this user cannot read is unknown, never a reason to stop
                die $e if !( blessed($e) && $e->isa('Odoo::Error') && $e->kind eq 'fault' );
                $out{unknown}{$rm} = $e->is_access_denied ? 'access refused' : ( ( $e->fault_class // 'fault' ) =~ s/.*\.//r );
                next;
            }
            my ( %n, %who );
            for my $row (@$rows) {
                next if $undo_ids->{$rm} && $undo_ids->{$rm}{ $row->{id} };
                my $v = $row->{$name};
                my @targets = ref $v eq 'ARRAY' ? ( @$v == 2 && !ref $v->[0] && defined $v->[1] && $v->[1] !~ /^-?\d+\z/ ? ( $v->[0] ) : @$v ) : ( $v ? ($v) : () );
                for ( grep { $undo_ids->{$m}{$_} } @targets ) { $n{$_}++; push @{ $who{$_} }, $row->{id} }
            }
            for my $id ( keys %n ) {
                push @{ $out{refs}{$m}{$id} }, {
                    model => $rm, field => $name, ttype => $ttype, count => $n{$id}, records => $who{$id},
                    on_delete => ( $rf->{on_delete} || 'set null' ), ( $mfield ? ( model_field => $mfield ) : () ),
                };
            }
        }
    }
    return \%out;
}

# { model => 1 } for the models among those named that are transient or abstract
# (ir.model transient, and abstract where the series has the flag, which 19 does).
# A user who cannot read ir.model, or a server without it, gets an empty answer
# and every model is walked as before.
sub _unstored_models ($class, $ctx, @models) {
    my %uniq = map { $_ => 1 } @models;
    return () if !%uniq;
    my $client = $ctx->client;
    my %skip;
    eval {
        $ctx->guard->with_scope( { 'ir.model' => ['search_read'] }, 'revert', sub {
            my $m     = $client->model('ir.model');
            my $types = $m->fields;
            my @read  = grep { $types->{$_} } qw(model transient abstract);
            my @flags = grep { $_ ne 'model' } @read;
            return if !@flags;
            for my $flag (@flags) {
                my $rows = $m->search_read( [ [ 'model', 'in', [ sort keys %uniq ] ], [ $flag, '=', JSON::PP::true ] ], ['model'] );
                $skip{ $_->{model} } = 1 for @$rows;
            }
        } );
    };
    return %skip;
}

# what a reference means for the person reading the plan
sub _inbound_words ($r) {
    my $n = "$r->{count} $r->{model} row" . ( $r->{count} == 1 ? '' : 's' );
    if ( $r->{ttype} eq 'many2many' ) {
        my @ids = sort { $a <=> $b } @{ $r->{records} // [] };
        my @show = @ids[ 0 .. ( $#ids < 4 ? $#ids : 4 ) ];
        my $names = join( ', ', map { "$r->{model} $_" } @show ) . ( @ids > @show ? ' and ' . ( @ids - @show ) . ' more' : '' );
        return "$names " . ( @ids == 1 ? 'names' : 'name' ) . " this record through $r->{field} (many2many): the links are removed with it";
    }
    return "$n point here ($r->{field}, with $r->{model_field} = this model): Odoo does not clear this pointer: they keep this record's id after it is gone"
        if $r->{ttype} eq 'many2one_reference';
    my %then = (
        'set null' => 'they will keep their other values and lose this link',
        cascade    => 'they will be deleted with it',
        restrict   => 'Odoo will refuse the delete',
    );
    return "$n point here ($r->{field}), ondelete $r->{on_delete}: " . ( $then{ $r->{on_delete} } // 'Odoo decides what becomes of them' );
}

# What the handler of a done custom entry says about undoing it:
# (change) or (undef, reason, class).
sub _undo_custom ($class, $entry) {
    my $h = eval { Odoo::Ops::Registry->new->class_for( $entry->{handler} ) };
    return ( undef, "$entry->{handler} is not a known operation here; its change has no known inverse", undef ) if !$h;
    return ( undef, "$entry->{handler} has no inverse: the operation defines no undo_custom, so oom-ops revert holds its change as irreversible (e.g. a sent email)", $h ) if !$h->can('undo_custom');
    my ( $undo, $why ) = $h->undo_custom($entry);
    return ( $undo, $why, $h );
}

sub _dir_of ($journal_path) { return ( File::Spec->splitpath($journal_path) )[1] }

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
    Odoo::Ops::Runs->refuse_closed( _dir_of($journal_path) );
    my ( $header, $entries ) = Odoo::Ops::Journal->read($journal_path);
    # an administrator may finish another login's revert (undoing is theirs to do); another login's apply stays that login's
    my $other = $class->_journal_owner( $ctx, $header, 'resume', never => ( ( $header->{op} // '' ) ne 'revert' ) );
    my ( $vol, $dirs ) = File::Spec->splitpath($journal_path);
    my $plan_path = File::Spec->catpath( $vol, $dirs, 'plan.json' );
    my $orig = Odoo::Ops::Plan->load($plan_path);
    Odoo::Error->throw(
        kind    => 'refused',
        code    => 'plan',
        message => "$plan_path is not the plan this journal came from",
        fix     => 'resume from the journal.jsonl that sits beside its own plan.json',
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
    my $blobs = $orig->blob_source( _dir_of($journal_path) );
    @carry = map { $blobs->resolve($_) } @carry;
    my $plan = Odoo::Ops::Plan->new(
        blob_min    => $ctx->config->blob_min,

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
    my @stale = $ctx->guard->with_scope( $scope, 'resume', sub { $class->_stale_changes( $ctx->client, \@carry, $ctx ) } );
    my %stale = map { $_ => 1 } @stale;

    for my $c (@carry) {
        if ( $stale{ $c->{seq} } ) {
            $plan->add(
                bucket => 'stale', action => 'hold', model => $c->{model}, id => $c->{id}, key => $c->{key},
                reason => "$c->{model} $c->{id} changed since the plan was made; re-plan this row",
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
    $plan->note( "this run was applied by $other; you resume it as an administrator (" . $ctx->instance->{login} . ')' ) if defined $other;
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
    # Odoo's false is empty: a before-image records it as null, and an old journal
    # holds the number 0 for it, which a char, html or date field must not get back
    return undef if Odoo::Portable::empty_is_false($type) && Odoo::Portable::is_false_value($v);
    return $v;
}

1;
