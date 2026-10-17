package Odoo::Ops::Runs;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use File::Basename qw(basename dirname);
use File::Spec;
use Time::Local qw(timegm);

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Journal;
use Odoo::Ops::Plan;
use JSON::PP ();

=head1 NAME

Odoo::Ops::Runs - the runs of a runs_dir as records: listed, approved, found by state

=head1 SYNOPSIS

    my $runs = Odoo::Ops::Runs->new( dir => $runs_dir );
    my @open = $runs->list( state => 'planned' );
    $runs->approve( $id, by => 'sjm', note => 'checked the held rows' );
    my $rec  = $runs->record($id);          # the record plus its file paths

=head1 DESCRIPTION

No database: each run folder (C<< <runs_dir>/<UTC stamp>-<op>/ >>) is
the record, and a small C<run.json> beside C<plan.json> is its index
entry. C<oom-ops run> writes it, approve and apply update it, and a
run folder without one (an older run) is read from the files present
and gets its C<run.json> on first use.

A record:

    id op instance params planned{at,by} fingerprint buckets changes
    state approval{at,by,note,fingerprint} applied{at,by}
    result{ok,counts,stopped_by,journal} expires reverts reverted
    withdrawn{by,at,note} closed{by,at,reason,was} nothing_to_apply

States: C<planned>, C<approved>, C<applied> (every change applied, held or
skipped; C<result.ok> is false only when an invariant broke), C<failed>
(the apply ended with a change failed or not attempted and none applied),
C<partly-applied> (some applied, then one failed or was not attempted;
C<resume> is the way forward), C<nothing> (a plan with nothing to apply,
closed when it was planned: not live, not listed unless asked for),
C<reverted>, C<partly-reverted> (a
revert of it applied some of its changes and held or lost others: the
held ones are on the revert run), C<withdrawn> (a planned or approved
run somebody ended without applying it: C<withdrawn> in the record
holds C<by> and C<at>; apply refuses it by name), C<closed> (a failed,
partly-applied or partly-reverted run the caller ended with a reason:
C<closed> in the record holds C<by>, C<at>, C<reason> and C<was>; apply, resume
and revert refuse it by name); and two that are worked
out when the record is read, never stored: C<expired> (planned or
approved and past C<expires>, 24 hours after planning unless the
config's C<plan_ttl> says otherwise) and C<superseded> (planned or
approved while a later plan of the same op, instance and params
exists). Expiry wins when both hold.

C<now> (a coderef returning epoch seconds) is injectable.

The class methods C<index_plan>, C<approve_plan>, C<check_apply> and
C<record_applied> work on one run folder and are what the command line
and L<Odoo::Ops::Runner> use.

=cut

use constant DEFAULT_TTL => 86400;

sub new ($class, %args) {
    my $dir = $args{dir}
        or Odoo::Error->throw( kind => 'usage', message => 'runs registry needs dir' );
    return bless { dir => $dir, now => $args{now} // sub { time }, ttl => $args{ttl} // DEFAULT_TTL }, $class;
}

sub dir ($self) { $self->{dir} }
sub _now ($self) { $self->{now}->() }

=head2 list(%filter)

Records, newest first. Filters: C<op>, C<state>, C<instance> (the url
or the db), C<since> (a date or ISO time; planned at or after), C<actor>
(who planned or approved it), C<planned_by>, C<approved_by> and C<applied_by>
(one role each) and C<record> (C<model:id>: the run touched that record, see
C<touched>). Runs in state C<nothing> (closed at planning) and C<closed> (see
C<close_run>) are left out unless C<state> names them or C<all> is true. The applier is recorded as the operating-system user that ran the
apply and says nothing about who decided it, so C<actor> leaves it out; ask for
it with C<applied_by>.

=cut

sub list ($self, %f) {
    my @all = $self->_all;
    my @out;
    for my $r (@all) {
        next if defined $f{op}    && $r->{op} ne $f{op};
        next if defined $f{state} && $r->{state} ne $f{state};
        next if !$f{all} && !defined $f{state} && $r->{state} =~ /^(nothing|closed)\z/;
        next if defined $f{instance}
            && $r->{instance}{url} ne $f{instance} && ( $r->{instance}{db} // '' ) ne $f{instance};
        next if defined $f{since} && $r->{planned}{at} lt $f{since};
        my %by = (
            planned  => $r->{planned}  && $r->{planned}{by},
            approved => $r->{approval} && $r->{approval}{by},
            applied  => $r->{applied}  && $r->{applied}{by},
        );
        my $is = sub ($who, @roles) { grep { defined $by{$_} && $by{$_} eq $who } @roles };
        next if defined $f{actor}       && !$is->( $f{actor},       qw(planned approved) );
        next if defined $f{planned_by}  && !$is->( $f{planned_by},  'planned' );
        next if defined $f{approved_by} && !$is->( $f{approved_by}, 'approved' );
        next if defined $f{applied_by}  && !$is->( $f{applied_by},  'applied' );
        next if defined $f{record} && !grep { $_ eq $f{record} } $self->touched($r);
        push @out, $r;
    }
    return @out;
}

=head2 touched($record)

The records a run touched, as C<model:id> strings in the order they were
first met: for an applied run, from its journal (the changes that were
done, so a record made, written or removed); for any other, from the
plan's changes that name a record (a write, unlink, call or custom change;
a create has no id until it is applied). Empty when the run's files are
gone.

=cut

sub touched ($self, $r) {
    my $d = File::Spec->catdir( $self->{dir}, $r->{id} );
    my ( @out, %seen );
    my $add = sub ($c) {
        return if !$c->{model} || !$c->{id} || ref $c->{id};
        my $k = "$c->{model}:$c->{id}";
        push @out, $k if !$seen{$k}++;
    };
    my $jf = File::Spec->catfile( $d, 'journal.jsonl' );
    my $pf = File::Spec->catfile( $d, 'plan.json' );
    if ( -e $jf ) {
        my ( undef, $changes ) = eval { Odoo::Ops::Journal->read($jf) };
        $add->($_) for grep { ( $_->{outcome} // '' ) eq 'done' } @{ $changes // [] };
    }
    elsif ( -e $pf ) {
        my $plan = eval { Odoo::Ops::Plan->load($pf) };
        $add->($_) for grep { $_->{action} =~ /^(write|unlink|call|custom)\z/ } @{ $plan ? $plan->changes : [] };
    }
    return @out;
}

=head2 withdraw($id, by => ..., note => ...)

Closes a C<planned> or C<approved> run (also one that has since been
worked out as C<expired> or C<superseded>) without applying it: state
C<withdrawn>, with C<withdrawn: { by, at, note }>. Refused (C<state>)
for a run already applied, reverted or withdrawn. The folder stays; the
run is not applied and cannot be.

=cut

sub withdraw ($self, $id, %o) {
    my $d   = File::Spec->catdir( $self->{dir}, $id );
    my $idx = -d $d ? $self->_load_dir($d) : undef;
    $idx or Odoo::Error->throw( kind => 'usage', message => "no run '$id' in " . $self->{dir},
        fix => 'oom-ops runs --conf <conf> lists the runs' );
    Odoo::Error->throw( kind => 'refused', code => 'state',
        message => "run $id is $idx->{state}; only a planned or approved run can be withdrawn" . ( $idx->{state} eq 'nothing' ? ' (a run with nothing to apply is closed already)' : '' ),
        fix => $idx->{state} eq 'applied' ? "to undo it, plan the undo: oom-ops revert --conf <conf> --journal $d/journal.jsonl" : 'nothing to do' )
        if $idx->{state} !~ /^(planned|approved)\z/;
    $idx->{state}     = 'withdrawn';
    $idx->{withdrawn} = { by => $o{by} // $ENV{USER} // 'unknown', at => Odoo::Ops::iso_time( $o{now} // $self->_now ), note => $o{note} };
    _write( $d, $idx );
    return $idx;
}

=head2 close_run($id, by => ..., reason => ..., now => ...)

Records that the caller has ended a run OOM cannot finish: state C<closed>,
with C<closed: { by, at, reason, was }>, C<was> being the state it left.
Allowed from C<failed>, C<partly-applied> and C<partly-reverted>. The folder,
the journal and what it touched stay as they are and nothing goes to Odoo.
Refused (C<state>) from any other state: for C<planned> and C<approved> the
fix names C<withdraw>, for C<applied> it names C<revert>. An unknown id and an
empty reason are C<usage>. A closed run is not applied, resumed or reverted
(C<refuse_closed>).

=cut

sub close_run ($self, $id, %o) {
    my $reason = $o{reason};
    Odoo::Error->throw( kind => 'usage', message => 'close: --reason must say why the run is closed', fix => 'oom-ops runs close --help' )
        if !defined $reason || $reason !~ /\S/;
    my $d   = File::Spec->catdir( $self->{dir}, $id );
    my $idx = -d $d ? $self->_load_dir($d) : undef;
    $idx or Odoo::Error->throw( kind => 'usage', message => "no run '$id' in " . $self->{dir},
        fix => 'oom-ops runs --conf <conf> --all lists the runs' );
    my $was = $idx->{state};
    Odoo::Error->throw( kind => 'refused', code => 'state',
        message => "run $id is $was; only a failed, partly-applied or partly-reverted run can be closed",
        fix => $was =~ /^(planned|approved)\z/ ? "it was never applied: oom-ops withdraw --conf <conf> --run $id"
            :  $was eq 'applied'               ? "nothing is outstanding; to undo it: oom-ops revert --conf <conf> --journal $d/journal.jsonl"
            :                                    'nothing to do: the run is closed already' )
        if $was !~ /^(failed|partly-applied|partly-reverted)\z/;
    $idx->{state}  = 'closed';
    $idx->{closed} = { by => $o{by} // $ENV{USER} // 'unknown', at => Odoo::Ops::iso_time( $o{now} // $self->_now ), reason => $reason, was => $was };
    _write( $d, $idx );
    return $idx;
}

=head2 Odoo::Ops::Runs->refuse_closed($dir)

Throws C<refused/closed> when the run in C<$dir> was closed: the apply,
resume and revert of it are the caller's decision already taken.

=cut

sub refuse_closed ($class, $dir) {
    my $idx = $class->_load_dir($dir) or return;
    return if ( $idx->{state} // '' ) ne 'closed';
    Odoo::Error->throw( kind => 'refused', code => 'closed',
        message => "run $idx->{id} was closed by $idx->{closed}{by} at $idx->{closed}{at}: $idx->{closed}{reason}",
        fix => 'a closed run is not applied, resumed or reverted; plan again with oom-ops run ' . ( $idx->{op} // '<op>' ) . ' ... if the change is still wanted' );
}

=head2 find(%filter)

The newest run that matches every filter given, or undef. It is the
lookup a tool uses to answer "was this done?" from the registry, for
example whether a mailing was tested since it was last written:

    my $run = $runs->find(
        op    => 'mailing.test',
        param => { mailing => 7 },                  # every pair must equal the run's parameter
        since => '2026-10-15 12:00:00',             # applied at or after (planned at, if never applied)
        state => 'applied',
    );

Filters: C<op>; C<state> (a name or a list of names; C<applied> also
matches a run that was applied and later reverted, because a revert that
was held undid nothing); C<param> (a hash, compared as text); C<since> (an
epoch, an Odoo datetime C<YYYY-MM-DD HH:MM:SS> in UTC, or an ISO time);
C<instance> (a url or a db, as in C<list>); C<ok> (true: the apply
finished with no failed change). The registry is read as C<list> reads
it, so a run folder that was never indexed is found too.

=cut

sub find ($self, %f) {
    my @states = !defined $f{state} ? () : ref $f{state} eq 'ARRAY' ? @{ $f{state} } : ( $f{state} );
    push @states, 'reverted' if grep { $_ eq 'applied' } @states;
    my %want = map { $_ => 1 } @states;
    my $since = defined $f{since} ? _when( $f{since} ) : undef;
    for my $r ( $self->list( map { defined $f{$_} ? ( $_ => $f{$_} ) : () } qw(op instance) ) ) {
        next if @states && !$want{ $r->{state} };
        next if $f{ok} && !( $r->{result} && $r->{result}{ok} );
        if ( my $pm = $f{param} ) {
            next if grep { !defined $r->{params}{$_} || "$r->{params}{$_}" ne "$pm->{$_}" } keys %$pm;
        }
        if ( defined $since ) {
            my $at = $r->{applied} ? $r->{applied}{at} : $r->{planned}{at};
            next if !defined $at || _epoch($at) < $since;
        }
        return $r;
    }
    return undef;
}

# an epoch, an Odoo datetime or an ISO time as epoch seconds
sub _when ($t) {
    return $t if $t =~ /^\d+\z/;
    my @p = $t =~ /^(\d{4})-(\d\d)-(\d\d)[ T](\d\d):(\d\d):(\d\d)Z?\z/
        or Odoo::Error->throw( kind => 'usage', message => "runs: not a time: $t (epoch seconds, YYYY-MM-DD HH:MM:SS or ISO)" );
    return timegm( $p[5], $p[4], $p[3], $p[2], $p[1] - 1, $p[0] );
}

=head2 peek($id)

The run.json of C<$id> as it is stored (no expiry or supersession worked out,
no scan of the other runs), or undef: what a command that must not read the
whole registry asks first.

=cut

sub peek ($self, $id) {
    my $d = File::Spec->catdir( $self->{dir}, $id );
    return -d $d ? $self->_load_dir($d) : undef;
}

=head2 get($id)

The record, or undef when there is no such run.

=cut

sub get ($self, $id) {
    my ($r) = grep { $_->{id} eq $id } $self->_all;
    return $r;
}

=head2 record($id)

The record plus C<paths> (plan, journal, result, audit). Throws
C<usage> for an unknown run.

=cut

sub record ($self, $id) {
    my $r = $self->get($id)
        or Odoo::Error->throw( kind => 'usage', message => "no run '$id' in " . $self->{dir},
        fix => 'oom-ops runs --conf <conf> lists the runs' );
    my $d = File::Spec->catdir( $self->{dir}, $id );
    $r->{paths} = { map { $_ => File::Spec->catfile( $d, "$_.json" . ( $_ =~ /^(journal|audit)\z/ ? 'l' : '' ) ) }
        qw(plan journal result audit) };
    return $r;
}

=head2 approve($id, by => ..., note => ...)

Records the approval against the plan's fingerprint. Refused
(C<state>) for a run already applied or reverted, and C<expired> for a
run past its time.

=cut

sub approve ($self, $id, %o) {
    my $d = File::Spec->catdir( $self->{dir}, $id );
    my $r = $self->get($id)
        or Odoo::Error->throw( kind => 'usage', message => "no run '$id' in " . $self->{dir},
        fix => 'oom-ops runs --conf <conf> lists the runs' );
    return $self->approve_plan( $d, Odoo::Ops::Plan->load( File::Spec->catfile( $d, 'plan.json' ) ), now => $self->_now, %o );
}

=head2 mark_applied($id, $result)

Records the apply (and, for a revert run, marks the run it undoes).

=cut

sub mark_applied ($self, $id, $result) {
    my $d = File::Spec->catdir( $self->{dir}, $id );
    return ref($self)->record_applied( $d, $result, now => $self->_now );
}

=head2 mark_reverted($id, $by_run)

The run C<$id> is C<reverted> (or, with C<< state => 'partly-reverted' >>,
that), by the run C<$by_run>.

=cut

sub mark_reverted ($self, $id, $by_run, %o) {
    my $d   = File::Spec->catdir( $self->{dir}, $id );
    my $idx = $self->_load_dir($d)
        or Odoo::Error->throw( kind => 'usage', message => "no run '$id' in " . $self->{dir},
        fix => 'oom-ops runs --conf <conf> lists the runs' );
    $idx->{state}    = $o{state} // 'reverted';
    $idx->{reverted} = { by_run => $by_run, at => Odoo::Ops::iso_time( $self->_now ) };
    _write( $d, $idx );
    return $idx;
}

# --- one run folder ------------------------------------------------------------

=head2 Odoo::Ops::Runs->index_plan($dir, $plan, %o)

Writes C<run.json> for a freshly saved plan: C<by> (default the plan's
actor), C<now>, C<ttl>, C<reverts> (the id of the run a revert plan
undoes).

=cut

sub index_plan ($class, $dir, $plan, %o) {
    my $now = $o{now} // time;
    my $ttl = $o{ttl} // DEFAULT_TTL;
    my $h   = $plan->to_hash;
    my $at  = $h->{created} // Odoo::Ops::iso_time($now);
    my %r = (
        id          => basename($dir),
        op          => $h->{op},
        instance    => $h->{instance},
        params      => $h->{params},
        planned     => { at => $at, by => $o{by} // $h->{actor} // $ENV{USER} // 'unknown' },
        fingerprint => $h->{fingerprint},
        buckets     => $h->{buckets},
        changes     => scalar @{ $h->{changes} },
        state       => $plan->summary->{nothing_to_apply} ? 'nothing' : 'planned',
        nothing_to_apply => $plan->summary->{nothing_to_apply},
        approval    => undef,
        applied     => undef,
        result      => undef,
        expires     => Odoo::Ops::iso_time( _epoch($at) + $ttl ),
    );
    # a revert plan names the journal it undoes and a resume plan the one it carries on: the registry follows both
    my $p = $h->{params} // {};
    $r{reverts} = basename( dirname( $p->{reverts} ) ) if $h->{op} eq 'revert' && defined $p->{reverts} && !ref $p->{reverts};
    $r{reverts} = $o{reverts} if defined $o{reverts};
    # an administrator's revert of another login's run says whose it was
    $r{reverted_for} = $p->{reverted_for} if $h->{op} eq 'revert' && defined $p->{reverted_for};
    $r{resumes} = basename( dirname( $p->{resumes} ) ) if defined $p->{resumes} && !ref $p->{resumes};
    _write( $dir, \%r ) if !$o{nowrite};
    return \%r;
}

=head2 Odoo::Ops::Runs->approve_plan($dir, $plan, by => ..., note => ..., now => ...)

Approves the run in C<$dir>, creating its C<run.json> from C<$plan>
when there is none (a program approving a plan it holds in memory).
The approval carries the plan's fingerprint.

=cut

sub approve_plan ($class, $dir, $plan, %o) {
    my $now = $o{now} // time;
    my $idx = $class->_load_dir($dir) // $class->index_plan( $dir, $plan, now => $now, ttl => $o{ttl}, by => $o{by} );
    Odoo::Error->throw(
        kind => 'refused', code => 'fingerprint',
        message => "run $idx->{id}: the plan is not the one that was recorded for this run",
        fix => 'plan again with oom-ops run ' . $idx->{op} . ' ...',
    ) if $idx->{fingerprint} ne $plan->fingerprint;
    Odoo::Error->throw(
        kind => 'refused', code => 'state',
        message => "run $idx->{id} is $idx->{state}; only a planned or approved run can be approved",
        fix => 'plan again with oom-ops run ' . $idx->{op} . ' ...',
    ) if $idx->{state} !~ /^(planned|approved|nothing)\z/;
    Odoo::Error->throw(
        kind => 'refused', code => 'expired',
        message => "run $idx->{id} expired at $idx->{expires}; plan it again",
        fix => 'plan again with oom-ops run ' . $idx->{op} . ' ...',
    ) if $idx->{state} ne 'nothing' && $idx->{expires} && $now > _epoch( $idx->{expires} );
    # a run with nothing to apply stays closed; a program that approves and applies its own plan still can
    $idx->{state}    = 'approved' if $idx->{state} ne 'nothing';
    $idx->{approval} = {
        at          => Odoo::Ops::iso_time($now),
        by          => $o{by} // $ENV{USER} // 'unknown',
        note        => $o{note},
        fingerprint => $plan->fingerprint,
    };
    _write( $dir, $idx );
    return $idx;
}

=head2 Odoo::Ops::Runs->check_apply($dir, $plan, approval => 'required'|'none', now => ...)

The gate in front of an apply. A run that has a record and is past its
C<expires> is refused C<expired> whatever the config says. With
C<approval> C<required> (the default) the run must be approved:
C<unapproved> otherwise (a folder with no record counts), and
C<approval-stale> when the approval or the record names a different
fingerprint than the plan being applied. A C<withdrawn> run is refused
(C<withdrawn>) whatever the config says about approval.

=cut

sub check_apply ($class, $dir, $plan, %o) {
    my $now = $o{now} // time;
    my $idx = $class->_load_dir($dir);
    my $id  = basename($dir);
    Odoo::Error->throw(
        kind => 'refused', code => 'expired',
        message => "run $id expired at $idx->{expires}; plan it again",
        fix => 'plan again with oom-ops run ' . $idx->{op} . ' ...',
    ) if $idx && $idx->{expires} && $idx->{state} =~ /^(planned|approved)\z/ && $now > _epoch( $idx->{expires} );
    Odoo::Error->throw(
        kind => 'refused', code => 'withdrawn',
        message => "run $id was withdrawn by $idx->{withdrawn}{by} at $idx->{withdrawn}{at}; it is not applied",
        fix => 'plan again with oom-ops run ' . $idx->{op} . ' ... if the change is still wanted',
    ) if $idx && ( $idx->{state} // '' ) eq 'withdrawn';
    return $idx if ( $o{approval} // 'required' ) eq 'none';
    Odoo::Error->throw(
        kind => 'refused', code => 'unapproved',
        message => "run $id is not approved (oom-ops approve --plan $dir/plan.json, or Odoo::Ops::Runs->approve_plan)",
        fix => "oom-ops approve --conf <conf> --plan $dir/plan.json",
    ) if !$idx || !$idx->{approval};
    Odoo::Error->throw(
        kind => 'refused', code => 'approval-stale',
        message => "run $id was approved for plan " . substr( $idx->{approval}{fingerprint} // '', 0, 12 )
            . ' but this is plan ' . substr( $plan->fingerprint, 0, 12 ) . '; approve it again',
        fix => "oom-ops approve --conf <conf> --plan $dir/plan.json",
    ) if ( $idx->{approval}{fingerprint} // '' ) ne $plan->fingerprint || $idx->{fingerprint} ne $plan->fingerprint;
    return $idx;
}

=head2 Odoo::Ops::Runs->record_applied($dir, $result, by => ..., now => ..., plan => ...)

State C<applied>, with C<applied> and the result's summary. A revert
(C<reverts>) also records its C<outcome>, from what its changes did:

=over

=item C<reverted> - at least one change applied, none failed, none held;
the run it undoes becomes C<reverted>.

=item C<partly-reverted> - at least one applied and others were held or
failed; the run it undoes becomes C<partly-reverted>, and the revert's
C<held> lists the reasons.

=item C<held> - nothing applied (every change was a hold, such as a sent
email): the run it undoes keeps its state, and the revert's C<held> lists
the reasons. Nothing was undone, so nothing is claimed.

=item C<failed> - the first change failed and nothing applied.

=back

=cut

sub record_applied ($class, $dir, $result, %o) {
    my $h   = ref $result eq 'HASH' ? $result : $result->to_hash;
    my $idx = $class->_load_dir($dir)
        // ( $o{plan} ? $class->index_plan( $dir, $o{plan}, now => $o{now} ) : undef )
        or return undef;
    my $ok = !$h->{counts}{failed} && !$h->{counts}{not_attempted} && !$h->{invariants_failed} ? 1 : 0;
    $idx->{state}   = _apply_state( $h->{counts} );
    $idx->{applied} = { at => $h->{finished} // Odoo::Ops::iso_time( $o{now} // time ), by => $o{by} // $ENV{USER} // 'unknown' };
    $idx->{result}  = {
        ok => $ok ? JSON::PP::true() : JSON::PP::false(), counts => $h->{counts},
        stopped_by => $h->{stopped_by}, journal => $h->{journal},
    };
    my ( $outcome, $prev );
    my $root = dirname($dir);
    if ( defined $idx->{reverts} ) {
        my $c = $h->{counts} // {};
        # a revert that resumes another carries on from it: what the earlier run did and held counts here too
        $prev = $idx->{resumes} ? eval { $class->_load_dir( File::Spec->catdir( $root, $idx->{resumes} ) ) } : undef;
        my @prior = $prev && ref $prev->{held} eq 'ARRAY' ? @{ $prev->{held} } : ();
        my $before_done = $prev ? ( $prev->{done_total} // $prev->{result}{counts}{done} // 0 ) : 0;
        my $did  = ( $c->{done} // 0 ) + $before_done;
        my $held = ( $c->{held} // 0 ) + @prior;
        my $lost = ( $c->{failed} // 0 ) + ( $c->{not_attempted} // 0 );
        $outcome = $did ? ( $ok && !$held ? 'reverted' : 'partly-reverted' )
            : $lost ? 'failed'
            : $held ? 'held'
            :         'nothing';
        $idx->{outcome}    = $outcome;
        $idx->{done_total} = $did;
        my @why = ( @prior, ( $c->{held} ? _held_reasons( $dir, $o{plan} ) : () ) );
        $idx->{held} = \@why if @why;
    }
    _write( $dir, $idx );
    if ( $outcome && $outcome =~ /^(reverted|partly-reverted)\z/ ) {
        eval { $class->new( dir => $root )->mark_reverted( $idx->{reverts}, $idx->{resumes} // $idx->{id}, state => $outcome ) };
    }
    # a resume that left nothing failed finishes the revert run it carried on: that run ends applied
    if ( $prev && $idx->{state} eq 'applied' ) {
        my $at = $idx->{resumes};
        while ( defined $at ) {
            my $d = File::Spec->catdir( $root, $at );
            my $r = eval { $class->_load_dir($d) } or last;
            last if $r->{state} !~ /^(failed|partly-applied)\z/;
            $r->{state}      = 'applied';
            $r->{resumed_by} = $idx->{id};
            _write( $d, $r );
            $at = $r->{resumes};
        }
    }
    return $idx;
}

# the state an apply leaves: applied when no change failed or was left
# unattempted; failed when one did and none was applied; partly-applied
# when some were applied before it stopped
sub _apply_state ($counts) {
    my $c    = $counts // {};
    my $lost = ( $c->{failed} // 0 ) + ( $c->{not_attempted} // 0 );
    return 'applied' if !$lost;
    return ( $c->{done} // 0 ) ? 'partly-applied' : 'failed';
}

# what each held change of a plan says a person must do, from the plan in
# memory or the plan.json beside the run
sub _held_reasons ($dir, $plan) {
    $plan //= eval { Odoo::Ops::Plan->load( File::Spec->catfile( $dir, 'plan.json' ) ) };
    return () if !$plan;
    return map { { key => $_->{key}, model => $_->{model}, id => $_->{id}, bucket => $_->{bucket}, reason => $_->{reason} } }
        grep { $_->{action} eq 'hold' } @{ $plan->changes };
}

# --- reading ---------------------------------------------------------------------

sub _all ($self) {
    my $root = $self->{dir};
    return () if !-d $root;
    opendir my $dh, $root or return ();
    my @recs;
    for my $e ( grep { !/^\./ } readdir $dh ) {
        my $d = File::Spec->catdir( $root, $e );
        next if !-d $d;
        my $r = $self->_load_dir($d) or next;
        push @recs, $r;
    }
    closedir $dh;
    @recs = sort { $b->{planned}{at} cmp $a->{planned}{at} || $b->{id} cmp $a->{id} } @recs;
    my $now = $self->_now;
    my $key = sub ($r) { Odoo::Ops::json()->encode( [ @$r{qw(op instance params)} ] ) };
    for my $r (@recs) {
        next if $r->{state} !~ /^(planned|approved)\z/;
        if ( $r->{expires} && $now > _epoch( $r->{expires} ) ) { $r->{state} = 'expired'; next }
        my $k = $key->($r);
        $r->{state} = 'superseded'
            if grep { $_ != $r && $key->($_) eq $k && ( $_->{planned}{at} cmp $r->{planned}{at} || $_->{id} cmp $r->{id} ) > 0 } @recs;
    }
    return @recs;
}

# run.json, or one rebuilt from the files present (and kept)
sub _load_dir ($self, $dir) {
    my $idx = File::Spec->catfile( $dir, 'run.json' );
    if ( -e $idx ) {
        open my $fh, '<', $idx or Odoo::Error->throw( kind => 'config', message => "cannot read $idx: $!" );
        my $raw = do { local $/; <$fh> };
        close $fh;
        my $rec = eval { Odoo::Ops::json()->decode($raw) }
            // Odoo::Error->throw( kind => 'config', message => "$idx is not valid JSON; delete it and it is rebuilt" );
        # a record written before failed and partly-applied existed: say what the counts say
        $rec->{state} = _apply_state( $rec->{result}{counts} ) if ( $rec->{state} // "" ) eq "applied" && !$rec->{resumed_by} && ref $rec->{result} eq 'HASH';
        return $rec;
    }
    my $pf = File::Spec->catfile( $dir, 'plan.json' );
    return undef if !-e $pf;
    my $plan = eval { Odoo::Ops::Plan->load($pf) } or return undef;
    my $ttl  = ref $self && $self->{ttl} ? $self->{ttl} : DEFAULT_TTL;
    my $h    = $plan->to_hash;
    my $r    = Odoo::Ops::Runs->index_plan( $dir, $plan, ttl => $ttl, now => time, nowrite => 1 );
    $r->{reverts} = basename( dirname( $h->{params}{journal} ) )
        if $h->{op} eq 'revert' && $h->{params}{journal};
    return $r if !eval { _write( $dir, $r ); 1 };    # a read-only runs dir still lists
    # what the apply left: result.json (the command line) or, failing that, the journal itself
    my $rf = File::Spec->catfile( $dir, 'result.json' );
    my $jf = File::Spec->catfile( $dir, 'journal.jsonl' );
    my ( $res, $actor ) = ( undef, $r->{planned}{by} );
    if ( -e $rf && open my $fh, '<', $rf ) {
        $res = eval { Odoo::Ops::json()->decode( do { local $/; <$fh> } ) };
        close $fh;
    }
    if ( -e $jf ) {
        my ( $jh, $jc, $jfoot ) = eval { Odoo::Ops::Journal->read($jf) };
        $actor = $jh->{actor} if $jh && $jh->{actor};
        if ( $jh && !$res ) {
            my %counts;
            $counts{ $_->{outcome} }++ for @$jc;
            my ($failed) = grep { ( $_->{outcome} // '' ) eq 'failed' } @$jc;
            $res = {
                counts => $jfoot ? $jfoot->{counts} : { %counts, not_attempted => 1 },    # no footer: it did not finish
                finished => $jfoot ? $jfoot->{finished} : undef, journal => $jf,
                stopped_by => $failed ? $failed->{seq} : undef,
                invariants_failed => $jfoot ? $jfoot->{invariants_failed} : 0,
            };
        }
    }
    $r = Odoo::Ops::Runs->record_applied( $dir, $res, by => $actor ) // $r if $res;
    return $r;
}

sub _write ($dir, $rec) {
    my $path = File::Spec->catfile( $dir, 'run.json' );
    my $tmp  = "$path.tmp$$";
    open my $fh, '>', $tmp or Odoo::Error->throw( kind => 'config', message => "cannot write $tmp: $!" );
    print {$fh} JSON::PP->new->utf8->canonical->pretty->encode($rec);
    close $fh or Odoo::Error->throw( kind => 'config', message => "cannot write $tmp: $!" );
    rename $tmp, $path or Odoo::Error->throw( kind => 'config', message => "cannot write $path: $!" );
    return $path;
}

sub _epoch ($iso) {
    my @p = $iso =~ /^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)Z\z/
        or Odoo::Error->throw( kind => 'config', message => "not an ISO time: $iso" );
    return timegm( $p[5], $p[4], $p[3], $p[2], $p[1] - 1, $p[0] );
}

1;
