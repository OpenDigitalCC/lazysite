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

States: C<planned>, C<approved>, C<applied> (C<result.ok> false with
C<stopped_by> is a failed run), C<reverted>; and two that are worked
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
or the db), C<since> (a date or ISO time; planned at or after).

=cut

sub list ($self, %f) {
    my @all = $self->_all;
    my @out;
    for my $r (@all) {
        next if defined $f{op}    && $r->{op} ne $f{op};
        next if defined $f{state} && $r->{state} ne $f{state};
        next if defined $f{instance}
            && $r->{instance}{url} ne $f{instance} && ( $r->{instance}{db} // '' ) ne $f{instance};
        next if defined $f{since} && $r->{planned}{at} lt $f{since};
        push @out, $r;
    }
    return @out;
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
        or Odoo::Error->throw( kind => 'usage', message => "no run '$id' in " . $self->{dir} );
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
        or Odoo::Error->throw( kind => 'usage', message => "no run '$id' in " . $self->{dir} );
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

The run C<$id> is C<reverted>, by the run C<$by_run>.

=cut

sub mark_reverted ($self, $id, $by_run) {
    my $d   = File::Spec->catdir( $self->{dir}, $id );
    my $idx = $self->_load_dir($d)
        or Odoo::Error->throw( kind => 'usage', message => "no run '$id' in " . $self->{dir} );
    $idx->{state}    = 'reverted';
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
        state       => 'planned',
        approval    => undef,
        applied     => undef,
        result      => undef,
        expires     => Odoo::Ops::iso_time( _epoch($at) + $ttl ),
    );
    $r{reverts} = $o{reverts} if defined $o{reverts};
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
    ) if $idx->{fingerprint} ne $plan->fingerprint;
    Odoo::Error->throw(
        kind => 'refused', code => 'state',
        message => "run $idx->{id} is $idx->{state}; only a planned or approved run can be approved",
    ) if $idx->{state} !~ /^(planned|approved)\z/;
    Odoo::Error->throw(
        kind => 'refused', code => 'expired',
        message => "run $idx->{id} expired at $idx->{expires}; plan it again",
    ) if $idx->{expires} && $now > _epoch( $idx->{expires} );
    $idx->{state}    = 'approved';
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
fingerprint than the plan being applied.

=cut

sub check_apply ($class, $dir, $plan, %o) {
    my $now = $o{now} // time;
    my $idx = $class->_load_dir($dir);
    my $id  = basename($dir);
    Odoo::Error->throw(
        kind => 'refused', code => 'expired',
        message => "run $id expired at $idx->{expires}; plan it again",
    ) if $idx && $idx->{expires} && $idx->{state} =~ /^(planned|approved)\z/ && $now > _epoch( $idx->{expires} );
    return $idx if ( $o{approval} // 'required' ) eq 'none';
    Odoo::Error->throw(
        kind => 'refused', code => 'unapproved',
        message => "run $id is not approved (oom-ops approve --plan $dir/plan.json, or Odoo::Ops::Runs->approve_plan)",
    ) if !$idx || !$idx->{approval};
    Odoo::Error->throw(
        kind => 'refused', code => 'approval-stale',
        message => "run $id was approved for plan " . substr( $idx->{approval}{fingerprint} // '', 0, 12 )
            . ' but this is plan ' . substr( $plan->fingerprint, 0, 12 ) . '; approve it again',
    ) if ( $idx->{approval}{fingerprint} // '' ) ne $plan->fingerprint || $idx->{fingerprint} ne $plan->fingerprint;
    return $idx;
}

=head2 Odoo::Ops::Runs->record_applied($dir, $result, by => ..., now => ..., plan => ...)

State C<applied>, with C<applied> and the result's summary. When the
run is a revert (C<reverts>) that finished ok, the run it undoes
becomes C<reverted>.

=cut

sub record_applied ($class, $dir, $result, %o) {
    my $h   = ref $result eq 'HASH' ? $result : $result->to_hash;
    my $idx = $class->_load_dir($dir)
        // ( $o{plan} ? $class->index_plan( $dir, $o{plan}, now => $o{now} ) : undef )
        or return undef;
    my $ok = !$h->{counts}{failed} && !$h->{counts}{not_attempted} && !$h->{invariants_failed} ? 1 : 0;
    $idx->{state}   = 'applied';
    $idx->{applied} = { at => $h->{finished} // Odoo::Ops::iso_time( $o{now} // time ), by => $o{by} // $ENV{USER} // 'unknown' };
    $idx->{result}  = {
        ok => $ok ? JSON::PP::true() : JSON::PP::false(), counts => $h->{counts},
        stopped_by => $h->{stopped_by}, journal => $h->{journal},
    };
    _write( $dir, $idx );
    if ( $ok && defined $idx->{reverts} ) {
        eval { $class->new( dir => dirname($dir) )->mark_reverted( $idx->{reverts}, $idx->{id} ) };
    }
    return $idx;
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
        return eval { Odoo::Ops::json()->decode($raw) }
            // Odoo::Error->throw( kind => 'config', message => "$idx is not valid JSON; delete it and it is rebuilt" );
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
