package Odoo::Tools::Mailshot;

use strict;
use warnings;
use feature qw(signatures say);
no warnings 'experimental::signatures';

use File::Basename qw(basename);
use Fcntl qw(:flock);
use File::Spec;
use HTTP::Tiny;
use JSON::PP ();
use Odoo::JSON ();
use Scalar::Util qw(blessed);
use Time::HiRes ();

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Config;
use Odoo::Ops::Context;
use Odoo::Ops::Journal;
use Odoo::Ops::Mailing::Common ();
use Odoo::Ops::Plan;
use Odoo::Ops::PlanPrint;
use Odoo::Ops::Registry;
use Odoo::Ops::Runner;
use Odoo::Ops::Runs;

our $VERSION = '0.42';

=head1 NAME

Odoo::Tools::Mailshot - a mailing from contacts to progress, composed from the mailing operations

=head1 SYNOPSIS

    my $m = Odoo::Tools::Mailshot->new( conf => 'ops.conf', yes => 1 );
    $m->prepare( list => 'Newsletter', contacts => 'people.csv', subject => 'Autumn news', body => 'news.html' );
    $m->test( mailing => 24, to => 'me@example.com' );
    $m->send( mailing => 24, now => 1 );
    $m->watch( mailing => 24, until => 'done' );

=head1 DESCRIPTION

The library behind C<oom-mailshot>. OOM's C<mailing.*> operations are
primitives: each plans one thing, and a person or a program decides the
order. This module is that decision for a mailshot: the order of the steps,
the rule that a mailing is tested before it is sent, what a person is
shown at each, and the one call that plans, approves and applies a step
when the config allows it. Every write is still a plan of an operation, a
run folder, an approval line, a journal and a read-back, exactly as
C<oom-ops> makes them; nothing here writes to Odoo any other way.

Each command method prints for a person (or, with C<json>, prints one
object for a program) and returns the exit status: 0 ok, 1 refused,
failed, held or timed out, 3 a change failed part-way. A refusal is an
L<Odoo::Error> with a C<fix> line, thrown to the caller.

=head2 Approval

A step is approved and applied in the same call when C<yes> is passed
(C<--yes>) or the ops config says C<approval = self> (or C<none>, which has
no gate to pass). The approval is recorded in the run folder as the config's
actor, with a note that names the command, so the registry shows who allowed
what. With neither, the tool stops after planning and prints the
C<oom-ops approve> and C<oom-ops apply> lines for a person; a command that
needs a planned step to have happened first (C<prepare> makes the list
before the mailing) says so and stops there. C<cleanup> applies several plans
in one call: without approval it prints what it would do (the listing C<check>
gives) and refuses C<needs-approval>.

=head2 Errors

What an operation refuses is passed on in the tool's words: the message
names the command that ran (C<test: no mailing 999999>), not the primitive
(C<mailing.status>); a missing mailing is C<refused/unknown-mailing> and an
archived one C<refused/archived> (fix: C<status --archived>), whichever way the
operation said it (C<usage> until the primitive refuses them itself). The
refusals the tool raises on its own are C<untested>, C<needs-approval>,
C<sent-before>, C<not-recipient>, C<no-mail>, C<no-tracking-image>,
C<no-tracked-link> and C<transport/click-failed>; the agent guide's error table
has a row for each, and C<t/47> fails when a code has none.

=head2 new(%args)

C<conf> (an ops config path) or C<config>; C<yes>; C<json>; C<out> and
C<err> (handles); C<context> (a code ref returning a fresh
L<Odoo::Ops::Context>, for a test); C<http> (an object with C<get($url)>
that reads the mail catcher; default L<HTTP::Tiny>); C<instance_http> (the
same, for the instance's own web address, used by C<open_check> and C<click_check>); C<sleep>
and C<clock> (code refs, so a test can advance time without waiting).

=cut

sub new ($class, %a) {
    my $config = $a{config} // ( defined $a{conf} ? Odoo::Ops::Config->load( $a{conf} )
        : Odoo::Error->throw( kind => 'usage', message => 'oom-mailshot needs the ops config (--conf C)', fix => 'oom-mailshot --help' ) );
    Odoo::Ops::Registry->use_config($config);
    my $runs_dir = $config->get('runs_dir')
        or Odoo::Error->throw( kind => 'config', message => 'the config has no runs_dir', fix => 'add runs_dir = /path to the ops config' );
    return bless {
        config   => $config,
        conf     => $a{conf} // $config->path // '<conf>',
        yes      => $a{yes},
        json     => $a{json},
        out      => $a{out} // \*STDOUT,
        err      => $a{err} // \*STDERR,
        context  => $a{context} // sub { Odoo::Ops::Context->new( config => $config ) },
        http     => $a{http},
        instance_http => $a{instance_http},
        sleep    => $a{sleep} // sub ($s) { Time::HiRes::sleep($s) },
        clock    => $a{clock} // sub { time },
        reg      => Odoo::Ops::Registry->new,
        runs     => Odoo::Ops::Runs->new( dir => $runs_dir, ttl => $config->plan_ttl, ( $a{now} ? ( now => $a{now} ) : () ) ),
        steps    => [],
    }, $class;
}

# --- plumbing -------------------------------------------------------------------------------

sub _p ($self, @lines) {
    return if $self->{json};
    my $fh = $self->{out};
    print {$fh} "$_\n" for @lines;
    return;
}

sub _ctx ($self) { $self->{context}->() }

sub _auto ($self) {
    return 1 if $self->{yes};
    return $self->{config}->approval =~ /^(?:self|none)\z/ ? 1 : 0;
}

# a report of a read operation
sub _read ($self, $op, %params) {
    my $class = $self->{reg}->class_for($op);
    my $r = eval { my $p = $class->check_params( \%params ); $class->new( ctx => $self->_ctx, params => $p )->run };
    die $self->_own( $@, mailing => $params{mailing} ) if !defined $r;
    return $r;
}

# What an operation said, in the tool's words: the command that failed, not the primitive that was asked (item 2),
# a missing mailing as refused/unknown-mailing (exit 1: nothing is wrong with the command line), an archived one as
# refused/archived with the flag that reads it (item 16). The primitive says both as a usage error until
# docs/specs/primitives-3.md lands; this maps either wording, so the tool behaves the same before and after.
sub _own ($self, $e, %o) {
    return $e if !blessed($e) || !$e->isa('Odoo::Error');
    my $cmd = $self->{cmd} // 'oom-mailshot';
    my ( $kind, $code, $fix, $msg ) = ( $e->kind, $e->code, $e->fix, $e->message // '' );
    my $named = $msg =~ s/\A[a-z]+\.[a-z]+: //;
    $msg = "$cmd: $msg" if $named && $msg !~ /\A\Q$cmd\E: /;
    my $conf = $self->{conf};
    if ( $msg =~ /\bno mailing (\d+)\b/ ) {
        ( $kind, $code ) = ( 'refused', 'unknown-mailing' );
        $fix //= "oom-ops run mailing.status --conf <conf> lists the mailings";
    }
    elsif ( $msg =~ /\bmailing (\d+) is archived\b/ ) {
        my $n = $1;
        ( $kind, $code ) = ( 'refused', 'archived' );
        $msg = $cmd eq 'status'
            ? "status: mailing $n is archived; pass --archived to read it"
            : "$cmd: mailing $n is archived; oom-mailshot status --archived reads it";
        $fix = "oom-mailshot status --conf $conf --mailing $n --archived";
    }
    $fix =~ s/<conf>/$conf/g if defined $fix;
    return Odoo::Error->new( kind => $kind, code => $code, message => $msg, fix => $fix, fault_class => $e->fault_class );
}

sub _fix_for ($self, $e, %o) {
    return $e if !blessed($e) || !$e->isa('Odoo::Error');
    my $conf = $self->{conf};
    # an operation's own fix names <conf>; the tool knows which config it runs with
    if ( defined $e->fix && length $e->fix ) { $e->{fix} =~ s/<conf>/$conf/g; return $e }
    my %fix = (
        'not-draft'     => "oom-mailshot status --conf $conf --mailing $o{mailing}; a queued mailing goes back to draft with oom-ops run mailing.cancel",
        'no-recipients' => "oom-mailshot audience --conf $conf --list <name>: nobody on the lists can be mailed",
        'over-max'      => 'raise the limit deliberately: oom-mailshot send ... --max N',
        'not-testable'  => "oom-mailshot status --conf $conf --mailing $o{mailing}: only a draft or queued mailing is tested",
    );
    $e->{fix} = $fix{ $e->code // '' } if $e->code && $fix{ $e->code };
    $e->{fix} //= "oom-ops run mailing.status --conf $conf lists the mailings" if $e->kind eq 'usage' && ( $e->message // '' ) =~ /no mailing/;
    return $e;
}

sub _bucket_list ($b) { join '  ', map { "$_: $b->{$_}" } sort keys %$b }

# what oom-ops run prints: will write / skip / hold, notes, held rows
sub _print_summary ($self, $plan, $run_id) {
    my $s    = $plan->summary;
    my $inst = $plan->instance->{db} // $plan->instance->{url};
    $self->_p( 'plan ' . ( $run_id // '(not recorded)' ) . '  (' . $plan->op . " on $inst)" );
    my $row = sub ( $label, $n, $text ) { my $l = sprintf( '  %-12s%-5s%s', $label, $n, $text // '' ); $l =~ s/\s+\z//; $self->_p($l) };
    $row->( 'will write', $s->{will_write}, _bucket_list( $s->{by_group}{will_write} ) );
    $row->( 'skip',       $s->{skip},       _bucket_list( $s->{by_group}{skip} ) );
    $row->( 'hold',       $s->{hold},       _bucket_list( $s->{by_group}{hold} ) );
    if ( @{ $s->{notes} } ) {
        $self->_p('notes:');
        for my $n ( @{ $s->{notes} } ) {
            $self->_p("  $n");
            # the standing effects, one line each, as oom-ops run prints them (the same printer)
            if ( $n =~ /^side effects: / ) { $self->_p($_) for Odoo::Ops::PlanPrint::standing_lines($plan) }
        }
    }
    if ( @{ $s->{held} } ) {
        $self->_p('held:');
        my @h = @{ $s->{held} };
        for my $h ( @h[ 0 .. ( @h > 10 ? 9 : $#h ) ] ) {
            $self->_p( "  $h->{bucket}" . ( defined $h->{key} ? " [$h->{key}]" : '' ) . ': ' . ( $h->{reason} // '' ) );
        }
        $self->_p( '  and ' . ( @h - 10 ) . ' more (--json lists them all)' ) if @h > 10;
    }
    return $s;
}

=head2 A step

Every write goes through one private routine: plan the operation, show the
plan, and when nothing is to be written say so (no run folder is made for a
plan that is all holds and skips, so the registry holds no orphans); else
record the run, approve it as the actor when the tool may, apply through
L<Odoo::Ops::Runner>, save C<result.json> and report what was made. The
step it returns is a hash: C<op>, C<run_id>, C<plan>, C<buckets>, C<notes>,
C<held>, C<nothing_to_apply>, and when applied C<applied>, C<ok>, C<created>,
C<written>, C<custom>, C<verified>.

=cut

sub _step ($self, $label, $op, $params, %o) {
    my $class = $self->{reg}->class_for($op);
    my $ctx   = $self->_ctx;
    my $plan  = eval { my $p = $class->check_params($params); $class->new( ctx => $ctx, params => $p )->run } // do { die $self->_fix_for( $self->_own( $@, mailing => $params->{mailing} ), mailing => $params->{mailing} ) };
    $self->_p("== $label ($op)");
    my $s = $plan->summary;
    my %step = (
        label => $label, op => $op, buckets => $s->{buckets}, notes => $s->{notes}, held => $s->{held},
        will_write => $s->{will_write}, skip => $s->{skip}, hold => $s->{hold}, nothing_to_apply => $s->{nothing_to_apply} ? 1 : 0,
    );
    $o{collect}->( $plan, \%step ) if $o{collect};
    push @{ $self->{steps} }, \%step;
    if ( $s->{nothing_to_apply} ) {
        $self->_print_summary( $plan, undef );
        $self->_p('   nothing to apply');
        return \%step;
    }
    # a rule of the tool that stops an unattended apply: say it before a run is recorded, so none is left planned
    if ( $o{refuse} && $self->_auto && ( my $stop = $o{refuse}->($s) ) ) {
        $self->_print_summary( $plan, undef );
        die $stop;
    }
    my $dir  = $ctx->run_dir($op);
    my $path = $plan->save( File::Spec->catfile( $dir, 'plan.json' ) );
    Odoo::Ops::Runs->index_plan( $dir, $plan, now => $ctx->now, ttl => $ctx->plan_ttl, by => $ctx->actor );
    $step{run_id} = basename($dir);
    $step{plan}   = $path;
    $self->_print_summary( $plan, $step{run_id} );

    if ( !$self->_auto ) {
        $step{pending} = 1;
        $step{approve} = "oom-ops approve --conf $self->{conf} --plan $path";
        $step{apply}   = "oom-ops apply   --conf $self->{conf} --plan $path";
        # the command's _finish prints the then: lines once; printing them here too showed them twice
        return \%step;
    }
    Odoo::Ops::Runs->approve_plan( $dir, $plan, by => $ctx->actor, note => $o{note} // "oom-mailshot $label", ttl => $ctx->plan_ttl, now => $ctx->now )
        if $ctx->approval ne 'none';
    my $result = Odoo::Ops::Runner->apply( $ctx, $plan, dir => $dir );
    $result->save( File::Spec->catfile( $dir, 'result.json' ) );
    my $h = $result->to_hash;
    @step{qw(applied ok verified not_verified created written unlinked custom journal result)} =
        ( 1, $result->ok ? 1 : 0, @$h{qw(verified not_verified created written unlinked custom journal)}, File::Spec->catfile( $dir, 'result.json' ) );
    my $c = $h->{counts};
    $self->_p( "applied $step{run_id}: done $c->{done}, verified $h->{verified}, not verified $h->{not_verified}"
        . ( $c->{failed} ? ", FAILED $c->{failed}" : '' ) . ( $c->{unknown} ? ", UNKNOWN $c->{unknown} (sent, no answer: look in Odoo before sending again)" : '' ) . ( $c->{not_attempted} ? ", not attempted $c->{not_attempted}" : '' ) );
    for my $sect (qw(created written unlinked)) {
        my $m = $h->{$sect} // {};
        $self->_p("   $sect $_: " . join( ' ', @{ $m->{$_} } ) ) for sort keys %$m;
    }
    if ( !$result->ok ) {
        my ( undef, $changes ) = Odoo::Ops::Journal->read( $h->{journal} );
        for my $ch ( grep { $_->{error} } @$changes ) {
            my $msg = ref $ch->{error} ? $ch->{error}{message} : $ch->{error};
            $self->_p( "   FAILED $ch->{bucket} " . ( $ch->{key} // '' ) . ": $msg" );
            push @{ $step{failures} }, $msg;
        }
        # what oom-ops apply says after a failure: the fix, and the way on
        my @fix = Odoo::Ops::PlanPrint::fix_lines( $h, $self->{conf}, lead => '   ' );
        $self->_p($_) for @fix;
        $step{fix}    = [ map { s/^\s+//r } @fix ];
        $step{resume} = "oom-ops resume --conf $self->{conf} --journal $h->{journal}";
    }
    # a change that was applied and says something (a push Odoo refused, say) is told, not left in the journal
    for my $x ( @{ $h->{custom} // [] } ) {
        next if ref $x->{returned} ne 'HASH' || !defined $x->{returned}{note};
        $self->_p("   note: $x->{returned}{note}");
        push @{ $step{applied_notes} }, $x->{returned}{note};
    }
    return \%step;
}

# the id a created-hash holds for a model, first one
sub _created ($step, $model) { $step->{created} && $step->{created}{$model} ? $step->{created}{$model} : [] }

sub _finish ($self, $command, $res, $status) {
    $res->{command} = $command;
    $res->{ok}      = $status == 0 ? 1 : 0;
    # a change failed part-way: the way on is the one oom-ops apply prints (a command's own `then` stands)
    if ( $status == 3 && !@{ $res->{then} // [] } ) {
        my ($failed) = grep { $_->{resume} } reverse @{ $self->{steps} };
        $res->{then} = [ $failed->{resume} ] if $failed;
    }
    $res->{steps}  = [ map { +{ %$_ } } @{ $self->{steps} } ];
    if ( $self->{json} ) {
        my $fh = $self->{out};
        print {$fh} Odoo::JSON->new( pretty => 1 )->encode($res);
    }
    else {
        $self->_p( 'then: ' . ( $res->{then}[0] ), map { '      ' . $_ } @{$res->{then}}[ 1 .. $#{ $res->{then} } ] ) if @{ $res->{then} // [] };
    }
    $self->{steps} = [];
    $self->{result} = $res;
    return $status;
}

=head2 result

The object the last command built (the one C<json> prints), for a program
using the module.

=cut

sub result ($self) { $self->{result} }

sub _step_status ($step) { !$step->{applied} ? 0 : $step->{ok} ? 0 : 3 }

# --- audience ---------------------------------------------------------------------------------

=head2 audience(list => $name_or_id, limit => N)

C<mailing.lists> and C<mailing.contacts> for one list: the counts, then a
table of name, email and state (subscribed, opted out, blacklisted).

=cut

sub audience ($self, %a) {
    $self->{cmd} = 'audience';
    my $ref = $a{list} // Odoo::Error->throw( kind => 'usage', message => 'audience needs --list', fix => 'oom-mailshot audience --conf C --list <name|id>' );
    my $row = $self->_list_row($ref);
    my $c   = $self->_read( 'mailing.contacts', list => $row->{id}, ( $a{limit} ? ( limit => $a{limit} ) : () ) );
    my @people = map {
        my $x  = $_;
        my ($sub) = grep { $_->{name} eq $row->{name} } @{ $x->{lists} };
        +{ id => $x->{id}, name => $x->{name}, email => $x->{email},
           state => $x->{blacklisted} ? 'blacklisted' : $sub && $sub->{opt_out} ? 'opted out' : 'subscribed' };
    } @{ $c->{rows} };
    my %res = (
        list => { map { $_ => $row->{$_} } qw(id name contacts subscribed opted_out blacklisted reachable mailings) },
        people => \@people, matching => $c->{matching}, shown => $c->{shown},
        then => [ "oom-mailshot prepare --conf $self->{conf} --list " . _q( $row->{name} ) . ' --subject <subject> --body <file.html> [--contacts <file.csv>]' ],
    );
    # A list a mailing already used leads to that mailing's record, not to a second draft (item 8).
    my $used = $row->{mailings} ? $self->_newest_mailing_of($row) : undef;
    if ($used) {
        $res{used_by} = { id => $used->{id}, state => $used->{state}, subject => $used->{subject} };
        $res{then} = [ "oom-mailshot status --conf $self->{conf} --mailing $used->{id}" ];
    }
    $self->_p(
        "list $row->{id}: $row->{name}",
        "  subscriptions $row->{contacts}, subscribed $row->{subscribed}, opted out $row->{opted_out}, blacklisted $row->{blacklisted}, reachable $row->{reachable} (the addresses a send would mail), used by $row->{mailings} mailing(s)",
    );
    $self->_table( [qw(name email state)], [ map { [ @$_{qw(name email state)} ] } @people ] );
    $self->_p("  showing $c->{shown} of $c->{matching}; --limit N shows more") if $c->{matching} > $c->{shown};
    $self->_p("this list is used by mailing $used->{id} ($used->{state}); a new prepare with a subject makes a new draft, not a change to it") if $used;
    return $self->_finish( 'audience', \%res, 0 );
}

# The newest mailing (archived ones too) whose lists include this list, from the
# twenty newest mailings that mailing.status reads; undef when none is among them.
sub _newest_mailing_of ($self, $row) {
    my $rep = $self->_read( 'mailing.status', archived => 1 );
    my ($hit) = sort { $b->{id} <=> $a->{id} } grep { my $m = $_; grep { $_ eq $row->{name} } @{ $m->{lists} } } @{ $rep->{rows} };
    return $hit;
}

# What the held rows of a step come to, one entry per kind: { kind, count, addresses, text, rows }. The text is the
# kind with its count and addresses, then each reason as the hold wrote it. The address is the first one the reason
# names, else the row's key.
sub _held_groups ($held) {
    my ( %by, @order );
    for my $h (@$held) {
        my $k = $h->{bucket} // 'held';
        push @order, $k if !$by{$k};
        push @{ $by{$k} }, $h;
    }
    return [ map {
        my $k    = $_;
        my @rows = @{ $by{$k} };
        my @addr = map { ( $_->{reason} // '' ) =~ /([^\s'";,]+@[^\s'";,]+)/ ? $1 : $_->{key} // '?' } @rows;
        my @shown = @rows[ 0 .. ( @rows > 10 ? 9 : $#rows ) ];
        +{ kind => $k, count => 0 + @rows, addresses => \@addr, rows => \@rows,
           text => join "\n", "held: " . @rows . " $k (" . join( ', ', @addr ) . ')', ( map { "  $_->{reason}" } @shown ),
               ( @rows > @shown ? '  and ' . ( @rows - @shown ) . ' more (--json lists them all)' : () ) };
    } @order ];
}

sub _q ($s) { $s =~ /^[\w.@-]+\z/ ? $s : q(') . ( $s =~ s/'/'\\''/gr ) . q(') }

sub _list_row ($self, $ref) {
    my $rep = $self->_read( 'mailing.lists', ( $ref =~ /^\d+\z/ ? () : ( name => $ref ) ) );
    my @hit = $ref =~ /^\d+\z/ ? grep { $_->{id} == $ref } @{ $rep->{rows} } : @{ $rep->{rows} };
    my @exact = grep { lc $_->{name} eq lc $ref } @hit;
    @hit = @exact if @exact;
    Odoo::Error->throw( kind => 'usage', message => "no list '$ref'", fix => "oom-ops run mailing.lists --conf $self->{conf} shows the lists" ) if !@hit;
    Odoo::Error->throw( kind => 'usage', message => "'$ref' names " . scalar(@hit) . ' lists (ids ' . join( ', ', map { $_->{id} } @hit ) . ')', fix => 'give the id with --list' ) if @hit > 1;
    return $hit[0];
}

sub _table ($self, $head, $rows) {
    return if $self->{json};
    my @w = map { length } @$head;
    for my $r (@$rows) { for my $i ( 0 .. $#$r ) { my $l = length( $r->[$i] // '' ); $w[$i] = $l if $l > $w[$i] } }
    my $fmt = join( '  ', map { "%-${_}s" } @w[ 0 .. $#w - 1 ] ) . "  %s";
    $self->_p( '  ' . sprintf( $fmt, @$head ) =~ s/\s+\z//r );
    $self->_p( '  ' . sprintf( $fmt, map { $_ // '' } @$_ ) =~ s/\s+\z//r ) for @$rows;
    return;
}

# --- prepare ----------------------------------------------------------------------------------

=head2 prepare(list, contacts, subject, body, from, reply_to, schedule, new_draft, country_in, country_not_in, parts, part)

C<mailing.subscribe> then C<mailing.create>, each planned and (when the
tool may) approved and applied. Prints the ids made (list, contacts,
mailing) and the reachable audience; the contacts the file named that were
subscribed by an earlier call are named too (C<contacts 172 173 (already
subscribed)>). A second call with the same subject and list finds the draft
the C<exists> hold names and updates it (C<mailing=ID>), saying so.

When the create plan carries the C<sent before:> note (a mailing of this
subject and these lists has gone out) and the tool is to approve the step
(C<yes> or C<approval = self>), the mailing step is not applied: the call
refuses C<refused/sent-before>, naming the mailing and the fix, so a script
run twice does not make a draft each time. C<new_draft> (C<--new-draft>)
is the deliberate second mailing. Without approval the plan is shown with
the note. The contacts and list steps are not affected.

C<country_in> or C<country_not_in> (comma-separated ISO codes), or C<parts> (a
JSON parts file) with C<part> (a name in it), make the mailing one region of
its lists (see L<Odoo::Ops::Mailing::Create>); C<list> may then name several
lists, comma-separated, but not with C<contacts>. With C<parts> the parts are
read first through C<mailing.partition> and the call is C<refused/not-a-partition>
unless they cover the lists' contacts once. The audience printed is Odoo's count
for the mailing's domain, and the domain, not the lists' own counts.

C<slices> (C<--slices N>) with C<first> and C<every> (C<--first "YYYY-MM-DD
HH:MM:SS" --every MINUTES>) cuts the part into slices of at most N contacts,
each its own draft scheduled in Odoo's queue; see L</Slices of a part>. C<max>
(C<--max>) is the limit per slice.

A row whose tags column names a tag that does not exist is held
C<tag-not-allowed> at plan time when Odoo says this user may not create
partner tags: the list and the other rows are made, the held row makes no
contact, and nothing fails after the list is made. The C<held:> lines before
C<ids:> give each kind with its count and addresses, then each reason as the
hold wrote it. A failed change in any step prints C<FAILED ...>, the C<fix:> line
C<oom-ops apply> prints, and a C<then: oom-ops resume --conf C --journal J> line.

=cut

sub prepare ($self, %a) {
    $self->{cmd} = 'prepare';
    for my $need (qw(list subject body)) {
        Odoo::Error->throw( kind => 'usage', message => "prepare needs --$need", fix => 'oom-mailshot prepare --help' ) if !defined $a{$need};
    }
    return $self->_prepare_slices(%a) if grep { defined $a{$_} } qw(slices first every max);
    my %ids = ( list => undef, contacts => [], contacts_already => [], mailing => undef );
    my %res = ( ids => \%ids, then => [] );
    my $status = 0;

    # a part of a message: a country filter on the lists. --parts FILE --part NAME takes the filter from the file's
    # part of that name and first reads that the file's parts cover the lists' contacts once
    my %filter = map { defined $a{$_} ? ( $_ => $a{$_} ) : () } qw(country_in country_not_in);
    Odoo::Error->throw( kind => 'usage', message => 'prepare: give --country-in or --country-not-in, not both', fix => 'oom-mailshot prepare --help' ) if keys %filter > 1;
    Odoo::Error->throw( kind => 'usage', message => 'prepare: --parts and --part go together', fix => 'oom-mailshot prepare ... --parts parts.json --part NAME' )
        if ( defined $a{parts} ? 1 : 0 ) != ( defined $a{part} ? 1 : 0 );
    Odoo::Error->throw( kind => 'usage', message => 'prepare: --parts takes the filter from the part; do not give --country-in or --country-not-in as well', fix => 'oom-mailshot prepare --help' )
        if defined $a{parts} && %filter;
    my $multi = $a{list} =~ /,/ ? 1 : 0;
    Odoo::Error->throw( kind => 'usage', message => 'prepare: --contacts goes with one list; this names several', fix => 'subscribe the contacts to each list first, then prepare with --list A,B' )
        if $multi && defined $a{contacts};
    if ( defined $a{parts} ) {
        my $rep = $self->_partition( $a{list}, $a{parts}, refuse => 1 );
        my ($part) = grep { $_->{name} eq $a{part} } @{ $rep->{parts} };
        Odoo::Error->throw( kind => 'usage', message => "prepare: the parts file has no part '$a{part}' (it has " . join( ', ', map { "'$_->{name}'" } @{ $rep->{parts} } ) . ')', fix => 'give --part one of those names' ) if !$part;
        %filter = $part->{country_in} ? ( country_in => join( ',', @{ $part->{country_in} } ) ) : ( country_not_in => join( ',', @{ $part->{country_not_in} } ) );
        $res{partition} = $rep;
    }

    if ( defined $a{contacts} ) {
        # a contact subscribed by an earlier call is a skipped row: its id is in the row's reason
        my $already = sub ( $plan, $step ) {
            $step->{already_contacts} = [ map { /\bcontact (\d+) is on the list\b/ ? 0 + $1 : () }
                map { $_->{reason} // '' } grep { $_->{action} eq 'skip' && $_->{bucket} eq 'already-subscribed' } @{ $plan->changes } ];
        };
        my $s = $self->_step( 'contacts', 'mailing.subscribe', { list => $a{list}, rows => $a{contacts} }, note => 'oom-mailshot prepare: contacts', collect => $already );
        $status = _step_status($s);
        my %fresh = map { $_ => 1 } @{ _created( $s, 'mailing.contact' ) }, @{ $s->{written} && $s->{written}{'mailing.contact'} || [] };
        push @{ $ids{contacts} }, sort { $a <=> $b } keys %fresh;
        push @{ $ids{contacts_already} }, sort { $a <=> $b } grep { !$fresh{$_} } @{ $s->{already_contacts} // [] };
        $ids{contacts} = [ sort { $a <=> $b } @{ $ids{contacts} }, @{ $ids{contacts_already} } ];
        $ids{list} = _created( $s, 'mailing.list' )->[0];
        $res{held} = _held_groups( $s->{held} ) if @{ $s->{held} };
        if ( $s->{pending} ) {
            $res{pending} = 1;
            $res{then} = [ $s->{approve}, $s->{apply}, "oom-mailshot prepare ... again once it is applied: the mailing needs the list to exist" ];
            return $self->_finish( 'prepare', \%res, 0 );
        }
        return $self->_finish( 'prepare', \%res, $status ) if $status;
    }

    my %create = ( subject => $a{subject}, lists => $a{list}, body_file => $a{body}, %filter,
        map { defined $a{$_} ? ( $_ => $a{$_} ) : () } qw(from reply_to schedule) );
    my $sent_before = sub ($sum) {
        return if $a{new_draft};
        my ($note) = grep { /^sent before:/ } @{ $sum->{notes} // [] };
        return if !$note;
        my ($n) = $note =~ /mailing (\d+)/;
        return Odoo::Error->new( kind => 'refused', code => 'sent-before', message => "prepare: $note",
            fix => "pass --new-draft to make another mailing under this subject, or oom-mailshot status --conf $self->{conf} --mailing $n" );
    };
    my $s = $self->_step( 'mailing', 'mailing.create', \%create, note => 'oom-mailshot prepare: mailing', refuse => $sent_before );
    if ( !$s->{applied} && !$s->{pending} ) {
        my ($ex) = grep { $_->{bucket} eq 'exists' } @{ $s->{held} };
        if ($ex) {
            my ($id) = $ex->{reason} =~ /mailing (\d+)/;
            $self->_p("   the draft already exists: mailing $id; updating it in place (mailing=$id)");
            $res{existing} = 0 + $id;
            $s = $self->_step( 'mailing (update)', 'mailing.create', { %create, mailing => $id }, note => "oom-mailshot prepare: update of mailing $id" );
            $ids{mailing} = 0 + $id;
            $self->_p("   mailing $id already reads as asked") if $s->{nothing_to_apply};
        }
        else {
            $res{held} = [ @{ $res{held} // [] }, @{ _held_groups( $s->{held} ) } ];
            $self->_p('   the mailing was not made: see held above');
            return $self->_finish( 'prepare', \%res, 1 );
        }
    }
    $status ||= _step_status($s);
    $ids{mailing} //= _created( $s, 'mailing.mailing' )->[0];
    $ids{mailing} //= $s->{written} && $s->{written}{'mailing.mailing'} ? $s->{written}{'mailing.mailing'}[0] : undef;
    if ( $s->{pending} ) {
        $res{pending} = 1;
        $res{then} = [ $s->{approve}, $s->{apply} ];
        return $self->_finish( 'prepare', \%res, $status );
    }
    return $self->_finish( 'prepare', \%res, $status ) if $status;

    if ( $multi || %filter ) {
        # several lists, or one region of them: the lists' own counts are not what this mailing reaches; Odoo's total for its domain is
        my $m = $self->_mailing_row( $ids{mailing} );
        $res{audience} = { recipients => $m->{recipients}, lists => $m->{lists}, domain => $m->{domain} };
        $self->_p( $_->{text} ) for @{ $res{held} // [] };
        $self->_p(
            "ids: mailing $ids{mailing}",
            "audience: Odoo counts $m->{recipients} contact(s) for the mailing's domain (lists " . join( ', ', @{ $m->{lists} } ) . ')'
                . ( %filter ? '; ' . ( exists $filter{country_in} ? "country in $filter{country_in}" : "country not in $filter{country_not_in}, or none" ) : '' ),
            "domain: $m->{domain}",
        );
        my @sent = grep { /^sent before:/ } @{ $s->{notes} // [] };
        if (@sent) { $res{sent_before} = \@sent; $self->_p(@sent) }
        $res{then} = [ "oom-mailshot test --conf $self->{conf} --mailing $ids{mailing} --to <your address>" ];
        return $self->_finish( 'prepare', \%res, 0 );
    }
    my $row = $self->_list_row( $ids{list} // $a{list} );
    $ids{list} //= $row->{id};
    $res{audience} = { map { $_ => $row->{$_} } qw(contacts subscribed opted_out blacklisted reachable) };
    my %was = map { $_ => 1 } @{ $ids{contacts_already} };
    my @new = grep { !$was{$_} } @{ $ids{contacts} };
    my @contact_words = ( ( @new ? 'contacts ' . join( ' ', @new ) : () ), ( %was ? 'contacts ' . join( ' ', sort { $a <=> $b } keys %was ) . ' (already subscribed)' : () ) );
    # a held row is not a failure (exit 0), but the list is short by it: say so before the ids
    $self->_p( $_->{text} ) for @{ $res{held} // [] };
    $self->_p(
        'ids: list ' . $ids{list} . ( @contact_words ? ', ' . join( ', ', @contact_words ) : '' ) . ', mailing ' . ( $ids{mailing} // '(none)' ),
        "audience: $row->{reachable} reachable address(es) of $row->{contacts} subscription(s); $row->{opted_out} opted out, $row->{blacklisted} blacklisted",
    );
    my @sent = grep { /^sent before:/ } @{ $s->{notes} // [] };
    if (@sent) {
        $res{sent_before} = \@sent;
        $self->_p(@sent);
    }
    $res{then} = [ "oom-mailshot test --conf $self->{conf} --mailing $ids{mailing} --to <your address>" ] if $ids{mailing};
    return $self->_finish( 'prepare', \%res, 0 );
}

# --- partition ----------------------------------------------------------------------------------

=head2 partition(list, parts, check, slices)

C<mailing.partition>: whether the country-filtered parts in the file C<parts>
(a JSON list of C<< { name, country_in | country_not_in } >>) cover every
contact of the lists once. Prints each part's contacts (Odoo's own count for
its domain) and the lists' totals, and the addresses of the contacts in no
part or in two. With C<check> a problem is C<refused/not-a-partition> (exit
1). C<prepare> with C<parts> and C<part> runs it first and refuses the same
way; the C<--parts> file is the one place the parts are written.

With C<slices> (C<--slices N>) each part is also cut into slices of at most N
contacts by contact id, and each slice is printed with its first and last
address; the first slice has no lower bound and the last no upper, and the
note under a part gives the last slice's headroom. An address held by contacts
in two slices counts, as across parts, as a problem. C<parts> may then be left
out: the whole of the lists is one part, named C<all>.

=cut

sub _partition ($self, $lists, $parts_file, %o) {
    my %with = ( ( defined $parts_file ? ( parts_file => $parts_file ) : () ), ( defined $o{slices} ? ( slices => $o{slices} ) : () ) );
    my $rep = $self->_read( 'mailing.partition', lists => $lists, %with );
    $self->_p("== partition (mailing.partition)");
    $self->_p( '  lists: ' . join( ', ', map { $_->{name} } @{ $rep->{lists} } ) );
    for my $pt ( @{ $rep->{parts} } ) {
        $self->_p( "  part $pt->{name}: $pt->{contacts} contact(s) ($pt->{filter}), $pt->{blacklisted} blacklisted, $pt->{recipients} recipient(s)" );
        next if !$pt->{slices};
        my $m = @{ $pt->{slices} };
        $self->_p( '    ' . _slice_line( $_, $m ) ) for @{ $pt->{slices} };
        $self->_p( "    $pt->{slices_note}" );
    }
    my $w = $rep->{whole};
    $self->_p( "  whole: $w->{contacts} contact(s) of the lists, $w->{blacklisted} blacklisted, $w->{recipients} recipient(s)"
        . ( $w->{without_address} ? ", $w->{without_address} without an address" : '' )
        . "; in no part $w->{in_no_part}{count}; in more than one part $w->{in_several_parts}{count}; addresses in different parts $w->{addresses_in_several_parts}{count}" );
    for my $k ( [ in_no_part => 'in no part' ], [ in_several_parts => 'in more than one part' ], [ addresses_in_several_parts => 'in different parts' ] ) {
        my $h = $w->{ $k->[0] };
        $self->_p( "    $k->[1]: " . join( ', ', @{ $h->{emails} } ) . ( $h->{count} > @{ $h->{emails} } ? ', ...' : '' ) ) if $h->{count};
    }
    if ( $rep->{ok} ) { $self->_p("  the parts cover every contact of the lists once") }
    elsif ( $o{refuse} ) {
        my $e = eval { $self->_read( 'mailing.partition', lists => $lists, %with, check => 1 ); 1 } ? undef : $@;
        die $self->_fix_for( $e, mailing => undef ) if $e;
    }
    return $rep;
}

sub partition ($self, %a) {
    $self->{cmd} = 'partition';
    for my $need (qw(list parts)) {
        Odoo::Error->throw( kind => 'usage', message => "partition needs --$need" . ( $need eq 'parts' ? ' (or --slices, for the whole of the lists as one part)' : '' ), fix => 'oom-mailshot partition --help' )
            if !defined $a{$need} && !( $need eq 'parts' && defined $a{slices} );
    }
    Odoo::Error->throw( kind => 'usage', message => "partition: --slices must be a whole number of at least 1, not '$a{slices}'", fix => 'oom-mailshot partition --help' )
        if defined $a{slices} && ( $a{slices} !~ /\A\d+\z/ || $a{slices} < 1 );
    my $rep = $self->_partition( $a{list}, $a{parts}, refuse => $a{check}, slices => $a{slices} );
    return $self->_finish( 'partition', { partition => $rep, then => [ $rep->{ok} ? "oom-mailshot prepare --conf $self->{conf} --list <lists> --subject <subject> --body <file.html> "
      . ( defined $a{parts} ? '--parts ' . _q( $a{parts} ) . ' --part <name>' : '' )
      . ( defined $a{slices} ? ' --slices ' . ( 0 + $a{slices} ) . ' --first "YYYY-MM-DD HH:MM:SS" --every <minutes>' : '' ) : () ] }, 0 );
}

# --- slices of a part ---------------------------------------------------------------------------

=head2 Slices of a part

C<prepare> with C<slices> (N), C<first> (a UTC time, C<YYYY-MM-DD HH:MM:SS>) and
C<every> (minutes) cuts one message, or one part of it (C<parts> and C<part>;
without them the whole of the lists), into slices of at most N contacts, for a
part too big to leave in one mailing. The rule it keeps: every mail leaves from
Odoo's own queue at a time set in advance; nothing here runs later.

It runs C<mailing.partition> with C<slices> first and is
C<refused/not-a-partition> unless the parts cover the lists once (and no
address lies in two slices). Each slice is its own draft: the same subject,
lists, body and country filter, a C<slice> clause (C<mailing.create>: a contact
id range, the first slice with no lower bound and the last with no upper) and
its own schedule, C<first> plus C<every> minutes for each slice before it. The
subject the recipient sees is unchanged; the slice is named C<SUBJECT [part
NAME, slice k of m]> in the tool's own record (the step and the approval note),
and a draft is told apart in Odoo by its domain. One plan is printed for all of
them, before anything is written: each slice's clause in words, Odoo's contact
count, the addresses it would mail, and its schedule; C<max> (default 500)
applies to each slice, and with C<yes> a slice over it refuses C<over-max> before
any draft is made.

The drafts follow the usual approval (C<yes>, or C<approval = self>; otherwise
the C<oom-ops approve> and C<apply> lines are printed for each). With C<yes> each
slice is then queued with C<mailing.send> (no C<now>) and Odoo's cron sends it at
its schedule date; the approval note says it was not tested. Without C<yes> the
C<then:> lines are C<mailing.send> for each slice (C<oom-mailshot test> first for
one of them: the slices share a body). A draft that exists already with the same
subject, lists and range is updated in place, as for any C<prepare>.

=cut

sub _slice_line ($sl, $m) {
    my $range = !defined $sl->{from_id} && !defined $sl->{before_id} ? 'the whole part' : Odoo::Ops::Mailing::Common::slice_words( $sl->{from_id}, $sl->{before_id} );
    return "slice $sl->{n} of $m: " . Odoo::Ops::Mailing::Common::commas( $sl->{count} ) . " contact(s), $range"
        . ( defined $sl->{first_email} && length $sl->{first_email} ? " ($sl->{first_email} .. $sl->{last_email})" : '' );
}

# a plan of an operation and nothing else: no run folder, no approval
sub _plan_of ($self, $op, $params) {
    my $class = $self->{reg}->class_for($op);
    return eval { my $p = $class->check_params($params); $class->new( ctx => $self->_ctx, params => $p )->run } // do { die $self->_fix_for( $self->_own( $@, mailing => $params->{mailing} ), mailing => $params->{mailing} ) };
}

sub _prepare_slices ($self, %a) {
    $self->{cmd} = 'prepare';
    my $usage = sub ($m, $fix = 'oom-mailshot prepare ... --parts parts.json --part NAME --slices N --first "YYYY-MM-DD HH:MM:SS" --every MINUTES') {
        Odoo::Error->throw( kind => 'usage', message => "prepare: $m", fix => $fix );
    };
    $usage->('--first, --every and --max go with --slices') if !defined $a{slices};
    $usage->("--slices must be a whole number of at least 1, not '$a{slices}'") if $a{slices} !~ /\A\d+\z/ || $a{slices} < 1;
    $usage->('--slices needs --first: the UTC time of the first slice, YYYY-MM-DD HH:MM:SS') if !defined $a{first};
    $usage->('--slices needs --every: the minutes between two slices') if !defined $a{every};
    $usage->("--first must be a UTC datetime, YYYY-MM-DD HH:MM:SS, not '$a{first}'") if $a{first} !~ /\A\d{4}-\d\d-\d\d[ T]\d\d:\d\d:\d\d\z/;
    $usage->("--every must be a number of minutes above 0, not '$a{every}'") if $a{every} !~ /\A\d+(?:\.\d+)?\z/ || $a{every} <= 0;
    my $max = $a{max} // 500;
    $usage->("--max must be a whole number of at least 1, not '$max'") if $max !~ /\A\d+\z/ || $max < 1;
    $usage->('--schedule is each slice\'s own time: give --first and --every') if defined $a{schedule};
    $usage->('--contacts goes with one draft: subscribe the contacts first, then prepare the slices') if defined $a{contacts};
    $usage->('--slices takes the filter from --parts and --part; do not give --country-in or --country-not-in') if defined $a{country_in} || defined $a{country_not_in};
    $usage->('--parts and --part go together') if ( defined $a{parts} ? 1 : 0 ) != ( defined $a{part} ? 1 : 0 );
    $a{first} =~ s/T/ /;
    my $t0 = Odoo::Ops::Mailing::Common::epoch( $a{first} );

    # the parts cover the lists once, and where the slices are cut
    my $rep = $self->_partition( $a{list}, $a{parts}, refuse => 1, slices => 0 + $a{slices} );
    my ($part) = defined $a{parts} ? grep { $_->{name} eq $a{part} } @{ $rep->{parts} } : $rep->{parts}[0];
    $usage->( "the parts file has no part '$a{part}' (it has " . join( ', ', map { "'$_->{name}'" } @{ $rep->{parts} } ) . ')', 'give --part one of those names' ) if !$part;
    my %filter = $part->{country_in} ? ( country_in => join( ',', @{ $part->{country_in} } ) ) : $part->{country_not_in} ? ( country_not_in => join( ',', @{ $part->{country_not_in} } ) ) : ();
    my @sl = @{ $part->{slices} };
    my $m  = @sl;
    my %res = ( ids => { mailing => [] }, partition => $rep, then => [], slices => [] );

    # one plan for all the slices, before anything is written
    my @work;
    for my $sl (@sl) {
        my $when = Odoo::Ops::Mailing::Common::odoo_time( $t0 + int( ( $sl->{n} - 1 ) * $a{every} * 60 + 0.5 ) );
        my $label = "[part $part->{name}, slice $sl->{n} of $m]";
        my %create = ( subject => $a{subject}, lists => $a{list}, body_file => $a{body}, %filter, schedule => $when,
            # a part that fits in one slice has no range to write: it is the part's own filter
            ( defined $sl->{from_id} || defined $sl->{before_id} ? ( slice => { map { defined $sl->{$_} ? ( $_ => $sl->{$_} ) : () } qw(from_id before_id) } ) : () ),
            map { defined $a{$_} ? ( $_ => $a{$_} ) : () } qw(from reply_to) );
        my $sum = $self->_plan_of( 'mailing.create', \%create )->summary;
        my ($reach) = map { /audience now[^:]*: (\d+) reachable/ ? $1 : () } @{ $sum->{notes} };
        my ($held) = @{ $sum->{held} };
        push @work, { sl => $sl, label => $label, create => \%create, when => $when, reachable => $reach, held => $held, notes => $sum->{notes} };
        push @{ $res{slices} }, { n => $sl->{n}, from_id => $sl->{from_id}, before_id => $sl->{before_id}, count => $sl->{count}, reachable => $reach, schedule => $when };
    }
    $self->_p( "== slices of part $part->{name} (mailing.create, $m draft(s))",
        "  subject '$a{subject}', " . Odoo::Ops::Mailing::Common::commas( $part->{contacts} ) . " contact(s) of the part cut into $m slice(s) of at most $a{slices}; the first goes at $a{first} UTC, then one every $a{every} minute(s); max $max per slice" );
    my $now = Odoo::Ops::Mailing::Common::odoo_time( $self->{clock}->() );
    for my $w (@work) {
        my $sl = $w->{sl};
        my $over = defined $w->{reachable} && $w->{reachable} > $max;
        $self->_p( '  ' . _slice_line( $sl, $m ) . ( defined $w->{reachable} ? "; mails $w->{reachable} address(es)" : '' ) . "; at $w->{when}"
            . ( $over ? "; OVER max=$max" : '' ) . ( $w->{when} lt $now ? '; in the past, so Odoo sends it as soon as it is queued' : '' )
            . ( $w->{held} ? "; held $w->{held}{bucket}: $w->{held}{reason}" : '' ) );
        if ( $over && $self->{yes} ) {
            Odoo::Error->throw( kind => 'refused', code => 'over-max',
                message => "prepare: slice $sl->{n} of $m would mail $w->{reachable} addresses, over max=$max; no draft was made",
                fix => 'raise --max deliberately, or cut the part smaller: --slices N' );
        }
    }

    # the drafts, then (with --yes) the queue
    my $status = 0;
    my @pending;
    for my $w (@work) {
        my ( $sl, $label ) = @$w{qw(sl label)};
        my $note = "oom-mailshot prepare: mailing $a{subject} $label";
        my $sent_before = sub ($sum) {
            return if $a{new_draft};
            my ($sb) = grep { /^sent before:/ } @{ $sum->{notes} // [] };
            return if !$sb;
            my ($n) = $sb =~ /mailing (\d+)/;
            return Odoo::Error->new( kind => 'refused', code => 'sent-before', message => "prepare: $sb",
                fix => "pass --new-draft to make another mailing under this subject, or oom-mailshot status --conf $self->{conf} --mailing $n" );
        };
        my $s = $self->_step( "mailing $label", 'mailing.create', $w->{create}, note => $note, refuse => $sent_before );
        if ( !$s->{applied} && !$s->{pending} ) {
            my ($ex) = grep { $_->{bucket} eq 'exists' } @{ $s->{held} };
            if ($ex) {
                my ($id) = $ex->{reason} =~ /mailing (\d+)/;
                $self->_p("   the draft already exists: mailing $id; updating it in place (mailing=$id)");
                $w->{existing} = 0 + $id;
                $s = $self->_step( "mailing $label (update)", 'mailing.create', { %{ $w->{create} }, mailing => $id }, note => "oom-mailshot prepare: update of mailing $id $label" );
                $w->{id} = 0 + $id;
            }
            else {
                $res{held} = [ @{ $res{held} // [] }, @{ _held_groups( $s->{held} ) } ];
                $self->_p("   slice $sl->{n} was not made: see held above");
                return $self->_finish( 'prepare', \%res, 1 );
            }
        }
        if ( $s->{pending} ) { push @pending, $s->{approve}, $s->{apply}; next }
        $status ||= _step_status($s);
        $w->{id} //= _created( $s, 'mailing.mailing' )->[0] // ( $s->{written} && $s->{written}{'mailing.mailing'} ? $s->{written}{'mailing.mailing'}[0] : undef );
        return $self->_finish( 'prepare', \%res, $status ) if $status;
    }
    if (@pending) {
        $res{pending} = 1;
        $res{then} = \@pending;
        return $self->_finish( 'prepare', \%res, 0 );
    }
    for my $i ( 0 .. $#work ) {
        $res{slices}[$i]{mailing} = $work[$i]{id};
        $res{slices}[$i]{existing} = 1 if $work[$i]{existing};
    }
    $res{ids}{mailing} = [ map { $_->{id} } @work ];
    $self->_p( 'ids: mailing ' . join( ', ', map { $_->{id} // '(none)' } @work ) );
    for my $w (@work) { $self->_p( @{ $w->{notes} }[ grep { $w->{notes}[$_] =~ /^sent before:/ } 0 .. $#{ $w->{notes} } ] ) }

    if ( $self->{yes} ) {
        my $failed = 0;
        for my $w (@work) {
            my $mid = $w->{id} or next;
            my $s = eval { $self->_step( "send slice $w->{sl}{n} of $m", 'mailing.send', { mailing => $mid, max => 0 + $max },
                note => "oom-mailshot prepare --slices --yes: slice $w->{sl}{n} of $m of part $part->{name} queued for $w->{when}; not tested (its body is the first slice's)" ) };
            if ( !$s ) {
                my $e = $@;
                $self->_p( "   slice $w->{sl}{n} (mailing $mid) was not queued: " . ( blessed($e) && $e->can('message') ? $e->message : "$e" ) );
                $res{slices}[ $w->{sl}{n} - 1 ]{queued} = 0;
                $failed++;
                next;
            }
            $res{slices}[ $w->{sl}{n} - 1 ]{queued} = _step_status($s) ? 0 : 1;
            $failed++ if _step_status($s);
        }
        $status = $failed ? 1 : 0;
        $res{then} = [ "oom-mailshot status --conf $self->{conf} --mailing $work[0]{id}", "oom-ops run mailing.cancel --conf $self->{conf} --set mailing=<id> returns a queued slice to draft" ];
    }
    else {
        $res{then} = [ "oom-mailshot test --conf $self->{conf} --mailing $work[0]{id} --to <your address>  (the slices share a body)",
            map { "oom-ops run mailing.send --conf $self->{conf} --set mailing=$_->{id} --set max=$max   (slice $_->{sl}{n} of $m, at $_->{when})" } grep { $_->{id} } @work ];
    }
    return $self->_finish( 'prepare', \%res, $status );
}

# --- test ---------------------------------------------------------------------------------------

=head2 test(mailing, to)

C<mailing.test>, then the mail itself: from the catcher when the config
names one (C<mailcatcher>), else C<mailing.preview>'s rendering (Odoo 18 renders no preview: the tool says so). Says which.

The address is always named: without C<to> the call is a C<usage> error whose
fix names C<--to E<lt>addressE<gt>> and C<--to me>. C<me> sends to the
connected user's own address, on purpose, and the line printed says
C<to E<lt>addressE<gt> (the connected user)>: a mailbox that may be shared is
never mailed by an omission.

=cut

sub test ($self, %a) {
    my $id = $self->_mailing_id( \%a, 'test' );
    Odoo::Error->throw( kind => 'usage', message => 'test: --to is required: name the address the test mail goes to',
        fix => "oom-mailshot test --conf $self->{conf} --mailing $id --to <address>, or --to me for the connected user's own address" )
        if !defined $a{to} || $a{to} !~ /\S/;
    my $me  = lc( $a{to} =~ s/\s+//gr ) eq 'me';
    my $row = $self->_mailing_row($id);
    my $s = $self->_step( 'test', 'mailing.test', { mailing => $id, ( $me ? () : ( to => $a{to} ) ) }, note => 'oom-mailshot test' );
    my %res = ( mailing => $id, then => [] );
    # the operation names the address it chose in its plan note
    my ($mine) = map { / to (\S+?); it goes at once/ ? $1 : () } grep { /^test of mailing / } @{ $s->{notes} // [] };
    if ($me) {
        $res{to} = $mine;
        $res{to_connected_user} = 1;
        $self->_p( '   to ' . ( $mine // 'the connected user' ) . ' (the connected user)' );
    }
    if ( $s->{pending} ) {
        $res{pending} = 1;
        $res{then} = [ $s->{approve}, $s->{apply} ];
        return $self->_finish( 'test', \%res, 0 );
    }
    my $status = _step_status($s);
    return $self->_finish( 'test', \%res, $status ) if $status || !$s->{applied};

    my ($first) = $me ? ($mine) : split /\s*,\s*/, $a{to};
    my $mail = $self->_catcher ? $self->_caught( $row->{subject}, $first ) : undef;
    if ($mail) {
        $res{mail} = { %$mail, source => 'catcher' };
        $self->_p( "the mail, as the catcher at $self->{config}{mailcatcher} holds it (a delivered test, read back):" );
    }
    elsif ( $self->_catcher ) {
        $self->_p("the catcher at $self->{config}{mailcatcher} has no mail for '$row->{subject}' to $first yet; mailing.preview's rendering instead (not the delivered mail):");
    }
    else {
        $self->_p( Odoo::Ops::Config->no_catcher_sentence . '; what follows is what Odoo renders for the first reachable recipient, not a delivered mail (add the key to the config you were given and run test again to see the caught copy):' );
    }
    if ( !$mail ) {
        my $pv = eval { $self->_read( 'mailing.preview', mailing => $id ) };
        if ( $pv && ( $pv->{rendered_by} // '' ) eq 'none' ) {
            $self->_p('   no preview either: this Odoo has no public renderer for a mass mail, so only the delivered test mail shows what recipients get (set mailcatcher in the config to read it)');
            $res{mail} = { source => 'none' };
        }
        elsif ($pv) {
            $res{mail} = { source => 'preview', subject => $pv->{subject}, from => $pv->{from}, text_head => _head( $pv->{text} ),
                unsubscribe_link => _no_token( $pv->{unsubscribe_url} ) };
            $mail = $res{mail};
        }
        else { $self->_p("   no preview either: $@") ; $res{mail} = { source => 'none' } }
    }
    if ( $mail && $mail->{subject} ) {
        $self->_p( "   subject: $mail->{subject}", '   from:    ' . ( $mail->{from} // '' ), '   text:' );
        $self->_p("     $_") for @{ $mail->{text_head} };
        $self->_p( '   unsubscribe link: ' . ( $mail->{unsubscribe_link}
            // ( $mail->{unsubscribe_placeholder} ? "$mail->{unsubscribe_placeholder} (Odoo's generic link: a test mail carries no recipient's own, which a sent mail does)" : 'NOT FOUND: the mail carries no way to opt out' ) ) );
    }
    # mailing.test read the mail back from the catcher as well: the text part's links, and the header a mail program shows
    my $rb = ( $s->{custom} && $s->{custom}[0] && ref $s->{custom}[0]{returned} eq 'HASH' ) ? $s->{custom}[0]{returned}{read_back} : undef;
    if ( $rb && $rb->{made} ) {
        my ($got) = grep { $_->{caught} && lc( $_->{to} // '' ) eq lc( $first // '' ) } @{ $rb->{mails} // [] };
        if ($got) {
            $res{mail} = { %{ $res{mail} // {} }, text_links => $got->{text_links}, list_unsubscribe => $got->{list_unsubscribe}, list_unsubscribe_post => $got->{list_unsubscribe_post} };
            $self->_p( '   text part links: ' . join( '; ', map { "[$_->{n}] $_->{verdict}" } @{ $got->{text_links} } ) ) if @{ $got->{text_links} };
            $self->_p( '   List-Unsubscribe: ' . _no_token( $got->{list_unsubscribe} ) ) if defined $got->{list_unsubscribe};
        }
    }
    $res{then} = [ "oom-mailshot send --conf $self->{conf} --mailing $id" ];
    $self->_p('send --now pushes the mails left in Odoo\'s queue, which reads mail.mail; without --now Odoo\'s cron worker sends the mailing');
    return $self->_finish( 'test', \%res, 0 );
}

sub _head ($text) {
    my @l = grep { length } map { s/^\s+|\s+$//gr } split /\n/, $text // '';
    return [ @l[ 0 .. ( $#l > 7 ? 7 : $#l ) ] ];
}

sub _no_token ($url) { defined $url ? $url =~ s/(token=)[^&"\s]+/$1<signed>/gr : undef }

sub _mailing_id ($self, $a, $cmd) {
    $self->{cmd} = $cmd;
    my $id = $a->{mailing};
    Odoo::Error->throw( kind => 'usage', message => "$cmd needs --mailing", fix => "oom-mailshot $cmd --help" ) if !defined $id;
    Odoo::Error->throw( kind => 'usage', message => "--mailing must be an id, not '$id'", fix => "oom-ops run mailing.status --conf $self->{conf} lists the mailings" ) if $id !~ /^\d+\z/;
    return 0 + $id;
}

sub _mailing_row ($self, $id, %o) {
    my $rep = eval { $self->_read( 'mailing.status', mailing => $id, %o ) } // do { die $self->_fix_for( $@, mailing => $id ) };
    return $rep->{rows}[0];
}

# --- the catcher ----------------------------------------------------------------------------------

sub _catcher ($self) { $self->{config}->get('mailcatcher') }

sub _http ($self) { $self->{http} //= HTTP::Tiny->new( timeout => 15 ) }

sub _urlenc ($s) { $s =~ s/([^A-Za-z0-9_.~-])/sprintf '%%%02X', ord $1/ger }

# the newest caught message for a subject (and recipient), or undef
sub _caught ($self, $subject, $to) {
    my $base = $self->_catcher =~ s{/+\z}{}r;
    my $q = qq(subject:"$subject") . ( $to ? qq( to:"$to") : '' );
    my $hit;
    for my $try ( 1 .. 8 ) {
        my $r = $self->_http->get( "$base/api/v1/search?query=" . _urlenc($q) );
        if ( $r->{success} ) {
            my $d = eval { Odoo::JSON::decode( $r->{content} ) } // {};
            $hit = ( $d->{messages} // [] )->[0];
            last if $hit;
        }
        $self->{sleep}->(0.5);
    }
    return undef if !$hit;
    my $r = $self->_http->get("$base/api/v1/message/$hit->{ID}");
    return undef if !$r->{success};
    my $m = eval { Odoo::JSON::decode( $r->{content} ) } or return undef;
    my $html = $m->{HTML} // '';
    my ($unsub) = $html =~ m{href="([^"]*confirm_unsubscribe[^"]*)"};
    my ($track) = $html =~ m{src="(https?://[^"]*/mail/track/[^"]+/blank\.gif)"};
    # Odoo 18 leaves the anchor as the generic placeholder in a test mail (it signs a link per recipient at send only)
    my ($generic) = $unsub ? () : $html =~ m{href="([^"]*/unsubscribe_from_list[^"]*)"};
    $unsub =~ s/&amp;/&/g if $unsub;
    return {
        id => $hit->{ID}, subject => $m->{Subject}, from => ( ref $m->{From} ? $m->{From}{Address} : $m->{From} ),
        text_head => _head( $m->{Text} ), unsubscribe_link => _no_token($unsub),
        ( $generic ? ( unsubscribe_placeholder => $generic ) : () ),
        ( $track ? ( tracking_image => 1 ) : () ), _track_url => $track,
    };
}

# --- send -----------------------------------------------------------------------------------------

=head2 send(mailing, now, max, force_untested)

The rule lives here. Refuses C<untested> unless the run registry holds an
applied C<mailing.test> run for this mailing since the mailing was last
written; C<force_untested> overrides and the approval note records that it
did. C<mailing.send> then refuses C<over-max> and the rest by name. The
plan's notes (the audience) are printed before anything is applied.

C<now> pushes the mails Odoo left outgoing, which reads C<mail.mail>. For a user Odoo refuses that read, the
change is then applied, not failed, with one line C<note: ...> naming
C<mail.mail> and the groups Odoo's text lists, and the run counts it not
verified. C<test> always names C<send>.

=cut

sub send ($self, %a) {
    my $id  = $self->_mailing_id( \%a, 'send' );
    my $row = $self->_mailing_row($id);
    my %res = ( mailing => $id, then => [] );
    my $test = $self->_test_run($id);
    my $note;
    if ($test) {
        $res{tested_by} = $test->{id};
        $self->_p("tested by run $test->{id} at $test->{applied}{at}");
        $note = "oom-mailshot send: tested by run $test->{id}";
    }
    elsif ( $a{force_untested} ) {
        $res{tested_by} = undef;
        $res{forced_untested} = 1;
        $self->_p('NOT TESTED: sending anyway because of --force-untested');
        $note = 'oom-mailshot send --force-untested: sent with no applied mailing.test since the mailing was last written';
    }
    else {
        Odoo::Error->throw( kind => 'refused', code => 'untested',
            message => "mailing $id has no applied mailing.test run in this registry since it was last written ($self->{_written})",
            fix => "oom-mailshot test --conf $self->{conf} --mailing $id --to <your address>, then send again; --force-untested overrides" );
    }
    my $s = $self->_step( 'send', 'mailing.send',
        { mailing => $id, ( $a{now} ? ( now => 1 ) : () ), ( defined $a{max} ? ( max => $a{max} ) : () ) }, note => $note );
    if ( $s->{pending} ) {
        $res{pending} = 1;
        $res{then} = [ $s->{approve}, $s->{apply} ];
        return $self->_finish( 'send', \%res, 0 );
    }
    my $status = _step_status($s);
    return $self->_finish( 'send', \%res, $status ) if !$s->{applied};
    my $after = $self->_mailing_row($id);
    $res{status} = $after;
    $self->_p( _counters_line($after) );
    # a change that failed has its own way on (the resume line _finish adds); the mailing's state is not the next step
    return $self->_finish( 'send', \%res, $status ) if $status;
    $res{then} = $a{now} && $after->{state} eq 'done'
        ? [ "oom-mailshot status --conf $self->{conf} --mailing $id --traces", "oom-mailshot open-check --conf $self->{conf} --mailing $id --email <a recipient>" ]
        : [ "oom-mailshot watch --conf $self->{conf} --mailing $id --until done" ];
    return $self->_finish( 'send', \%res, $status );
}

# the newest applied, ok test run of this mailing since the mailing was last written
sub _test_run ($self, $id) {
    # write_date is a column of the status read, so the tool needs no scope of its own on the model
    my $written = $self->_mailing_row($id)->{write_date};
    Odoo::Error->throw( kind => 'usage', message => "mailing $id has no write date to compare a test with", fix => "oom-mailshot status --conf $self->{conf} --mailing $id" ) if !defined $written;
    $self->{_written} = $written;
    return $self->{runs}->find( op => 'mailing.test', param => { mailing => $id }, since => $written, state => 'applied', ok => 1 );
}

sub _counters_line ($r) {
    my $line = "mailing $r->{id}: $r->{state}; recipients $r->{recipients}, expected $r->{expected}, sent $r->{sent}, delivered $r->{delivered}, opened $r->{opened}, clicked $r->{clicked}, bounced $r->{bounced}, cancelled $r->{canceled}, failed $r->{failed}";
    # Odoo's done is every recipient having a trace: a mail still to go is part of the line
    my $s = $r->{still_to_go};
    $line .= '; still to go: ' . join( ', ', map { "$s->{$_}{count} $_" } grep { $s->{$_} && $s->{$_}{count} } qw(outgoing error exception) )
        if $s && grep { $s->{$_} && $s->{$_}{count} } qw(outgoing error exception);
    return $line;
}

# The words under a done mailing's counters when mail is still to go: the first addresses of each kind and what moves it.
sub _still_lines ($r) {
    my $s = $r->{still_to_go} or return ();
    return () if !grep { $s->{$_} && $s->{$_}{count} } qw(outgoing error exception);
    my @l;
    for my $k (qw(outgoing error exception)) {
        next if !$s->{$k} || !$s->{$k}{count};
        push @l, "  $k $s->{$k}{count}: " . join( ', ', @{ $s->{$k}{emails} } ) . ( $s->{$k}{count} > @{ $s->{$k}{emails} } ? ', ...' : '' )
            . ( $k eq 'error' && $s->{$k}{failure_types} ? ' (' . join( ', ', map { "$_ $s->{$k}{failure_types}{$_}" } sort keys %{ $s->{$k}{failure_types} } ) . ')' : '' );
    }
    push @l, "  exception: $s->{exception_note}" if defined $s->{exception_note};
    push @l, "  $s->{note}" if defined $s->{note};
    return @l;
}

# --- watch ----------------------------------------------------------------------------------------

=head2 watch(mailing, until, timeout, interval)

Polls C<mailing.status> until the state is reached, printing each change of
counters. C<until> is C<done> (the state is done and no trace is outgoing:
Odoo calls a mailing done once every recipient has a trace, with mail possibly
still to go) or C<sent> (some mail has gone and none is still waiting). When
the time ends on a done mailing with traces outgoing, it says so, names the
first addresses and C<mailing.process>, and exits 1; traces in error and mail
in exception are told on reaching and do not change the exit status. Exit 0 when reached, 1 on timeout with the
last status. It reads once before it waits: a mailing that already holds the
condition prints C<mailing N: done; ... (already)> and C<reached: done>, with
no C<[+Ns]> prefix that would suggest a wait.

=cut

sub watch ($self, %a) {
    my $id = $self->_mailing_id( \%a, 'watch' );
    my $until = $a{until} // 'done';
    Odoo::Error->throw( kind => 'usage', message => "--until must be done or sent, not '$until'", fix => 'oom-mailshot watch --help' ) if $until !~ /^(?:done|sent)\z/;
    my ( $timeout, $every ) = ( $a{timeout} // 300, $a{interval} // 3 );
    my $t0 = $self->{clock}->();
    my ( $last_key, $row, $reached, $already ) = ('');
    while (1) {
        $row = $self->_mailing_row($id);
        my $key = join '|', map { $row->{$_} // '' } qw(state expected scheduled sent delivered opened clicked bounced canceled failed);
        # Odoo's done is every recipient having a trace, not every mail having gone: done waits for no trace to be outgoing
        $reached = $until eq 'done' ? $row->{state} eq 'done' && !( $row->{still_to_go} && $row->{still_to_go}{outgoing}{count} ) : ( $row->{sent} > 0 && !$row->{scheduled} );
        # the first read already holds the condition: nothing was waited for, so no [+Ns] that implies a wait (item 13)
        if ( $reached && $last_key eq '' ) { $already = 1; $self->_p( _counters_line($row) . ' (already)' ) }
        elsif ( $key ne $last_key ) { $self->_p( sprintf '[+%ds] %s', $self->{clock}->() - $t0, _counters_line($row) ) }
        $last_key = $key;
        last if $reached || $self->{clock}->() - $t0 >= $timeout;
        $self->{sleep}->($every);
    }
    my %res = ( mailing => $id, until => $until, reached => $reached ? 1 : 0, already => $already ? 1 : 0, status => $row, then => [] );
    if ($reached) {
        $self->_p("reached: $until");
        # mail that failed is a fact for the caller, not a wait: told, and the exit stays 0
        $self->_p( _still_lines($row) );
        $res{then} = ["oom-mailshot status --conf $self->{conf} --mailing $id --traces"];
        return $self->_finish( 'watch', \%res, 0 );
    }
    # Odoo calls it done and its mail is still outgoing: the wait ended on the clock, and the reason is the mail
    if ( $until eq 'done' && $row->{state} eq 'done' ) {
        $self->_p( "timed out after ${timeout}s: Odoo calls mailing $id done, but $row->{still_to_go}{outgoing}{count} trace(s) are still outgoing", _still_lines($row) );
        $res{then} = ["oom-ops run mailing.process --conf $self->{conf} --set mailing=$id"];
        return $self->_finish( 'watch', \%res, 1 );
    }
    # a schedule that lies ahead is not a stuck queue: say so instead of pointing at mailing.process
    my $now_odoo = Odoo::Ops::iso_time( $self->{clock}->() );
    $now_odoo =~ s/T/ /;
    $now_odoo =~ s/Z\z//;
    my $ahead = $row->{state} eq q(in_queue) && $row->{schedule_date} && $row->{schedule_date} gt $now_odoo;
    $self->_p( "timed out after ${timeout}s, still $row->{state}"
        . ( $ahead ? ": scheduled for $row->{schedule_date} (UTC); wait, or oom-ops run mailing.cancel puts it back to draft"
          : $row->{state} eq 'in_queue' ? ': Odoo\'s queue has not taken it; oom-ops run mailing.process pushes it from here' : '' ) );
    $res{then} = $ahead ? ["oom-ops run mailing.cancel --conf $self->{conf} --set mailing=$id"]
        : $row->{state} eq 'in_queue' ? ["oom-ops run mailing.process --conf $self->{conf} --set mailing=$id"] : [];
    return $self->_finish( 'watch', \%res, 1 );
}

# --- drip -----------------------------------------------------------------------------------------

=head2 drip(mailing, chunk, every, once, until, max, force_untested, despite_outgoing)

Sends a mailing in chunks of C<chunk> recipients, never two closer together
than C<every> minutes, until no recipient remains: a mail server that allows
so many mails an hour is kept under its limit. Each chunk is
C<mailing.send> with C<chunk> (planned, approved and applied as C<send> is),
so it sends the next recipients of the mailing's remaining set and reads the
new traces back. Odoo ends every send in state C<done>, so the mailing is
C<done> between chunks and its queue job (which takes C<in_queue> and
C<sending> only) never sends the rest; C<remaining> in the status says how many
are left. The rule of C<send> holds for the first chunk: a draft is sent only
once a C<mailing.test> of it has been applied (C<untested>; C<force_untested>
overrides).

C<once> sends one chunk and exits, for a caller's own timer (a cron line or a
systemd timer, see C<docs/use-cases/mailshot.md>); without it the call waits
C<every> minutes between chunks and ends when none remain. C<until> is C<done>,
the one value. The tool keeps a lock and the time of the last chunk of each
mailing in C<drip/> under the config's C<runs_dir>: a second C<drip> of the
same mailing while one runs is refused C<drip-busy>, and a call earlier than
C<every> after the last chunk sends nothing (C<once> says when the next is due and exits 0; without C<once> it
waits). The spacing is kept by that record, so it holds across calls and
processes.

Before each chunk it reads the status: a mailing in C<in_queue> or
C<sending> is refused C<queued> (Odoo's queue job would race the chunk); a done mailing with no
recipient left is finished; a done mailing with traces still C<outgoing> (a mail
server dropped the connection and Odoo left the rest of the last chunk in its
queue, Odoo 16) stops the drip with the C<still_to_go> lines, exit 1, and
sends nothing until they have gone (C<mailing.process> pushes them) or a person
passes C<despite_outgoing>. Traces in error do not stop it. The tool needs an
approval that needs no person (C<--yes>, or C<approval = self>), else it plans
the first chunk and prints the approval lines.

=cut

sub drip ($self, %a) {
    my $id = $self->_mailing_id( \%a, 'drip' );
    my ( $n, $every ) = @a{qw(chunk every)};
    Odoo::Error->throw( kind => 'usage', message => 'drip needs --chunk: how many recipients to send in each', fix => 'oom-mailshot drip --help' )
        if !defined $n || $n !~ /\A\d+\z/ || $n < 1;
    Odoo::Error->throw( kind => 'usage', message => 'drip needs --every: the minutes to keep between two chunks', fix => 'oom-mailshot drip --help' )
        if !defined $every || $every !~ /\A\d+(?:\.\d+)?\z/ || $every <= 0;
    my $until = $a{until} // 'done';
    Odoo::Error->throw( kind => 'usage', message => "--until must be done, not '$until'", fix => 'oom-mailshot drip --help' ) if $until ne 'done';
    my $lock = $self->_drip_lock($id);
    my %res = ( mailing => $id, chunk => 0 + $n, every => 0 + $every, once => $a{once} ? 1 : 0, chunks => [], finished => 0, then => [] );
    my $k = 0;
    while (1) {
        my $row = $self->_mailing_row( $id, remaining => 1 );
        Odoo::Error->throw( kind => 'refused', code => 'queued',
            message => "mailing $id is $row->{state}: Odoo's queue job sends every recipient that remains of a mailing in that state, so a chunk would race it",
            fix => "oom-ops run mailing.cancel --conf $self->{conf} --set mailing=$id returns it to draft; then drip again" )
            if $row->{state} =~ /^(?:in_queue|sending)\z/;
        if ( $row->{state} eq 'done' && defined $row->{remaining} && !$row->{remaining} ) {
            $res{finished} = 1;
            $self->_p( _counters_line($row), "mailing $id: no recipient remains" );
            $res{status} = $row;
            $res{then} = ["oom-mailshot status --conf $self->{conf} --mailing $id --traces"];
            return $self->_finish( 'drip', \%res, 0 );
        }
        my $out = $row->{still_to_go} && $row->{still_to_go}{outgoing} ? $row->{still_to_go}{outgoing}{count} : 0;
        if ( $out && !$a{despite_outgoing} ) {
            $res{stopped} = 'outgoing';
            $res{status}  = $row;
            $self->_p( "stopped: $out trace(s) of mailing $id are still outgoing, so the last chunk has not all gone; no chunk is sent until it has", _still_lines($row) );
            $res{then} = [ "oom-ops run mailing.process --conf $self->{conf} --set mailing=$id", "oom-mailshot drip --conf $self->{conf} --mailing $id --chunk $n --every $every" . ( $a{once} ? ' --once' : '' ) . ' (--despite-outgoing goes on regardless)' ];
            return $self->_finish( 'drip', \%res, 1 );
        }
        # never closer than every minutes to the last chunk, whoever sent it
        my $last = $self->_drip_last($id);
        my $now  = $self->{clock}->();
        if ( $last && defined $last->{at} && $now < $last->{at} + $every * 60 ) {
            my $due = $last->{at} + $every * 60;
            if ( $a{once} ) {
                $res{not_due} = { last => Odoo::Ops::iso_time( $last->{at} ), next => Odoo::Ops::iso_time($due) };
                $self->_p( 'not due: the last chunk of mailing ' . $id . ' went at ' . Odoo::Ops::iso_time( $last->{at} ) . ', the next is due at ' . Odoo::Ops::iso_time($due) . ' (every ' . $every . ' minutes); nothing sent' );
                $res{then} = ["oom-mailshot drip --conf $self->{conf} --mailing $id --chunk $n --every $every --once"];
                return $self->_finish( 'drip', \%res, 0 );
            }
            $self->_p( sprintf 'waiting %d s: the last chunk went at %s', $due - $now, Odoo::Ops::iso_time( $last->{at} ) );
            $self->{sleep}->( $due - $now );
            next;
        }
        my $note = "oom-mailshot drip: chunk of $n";
        if ( $row->{state} eq 'draft' ) {
            my $test = $self->_test_run($id);
            if ($test) { $res{tested_by} = $test->{id}; $note .= ", tested by run $test->{id}" }
            elsif ( $a{force_untested} ) {
                $res{forced_untested} = 1;
                $self->_p('NOT TESTED: sending anyway because of --force-untested');
                $note = 'oom-mailshot drip --force-untested: sent with no applied mailing.test since the mailing was last written';
            }
            else {
                Odoo::Error->throw( kind => 'refused', code => 'untested',
                    message => "mailing $id has no applied mailing.test run in this registry since it was last written ($self->{_written})",
                    fix => "oom-mailshot test --conf $self->{conf} --mailing $id --to <your address>, then drip again; --force-untested overrides" );
            }
        }
        my $s = $self->_step( 'drip', 'mailing.send', { mailing => $id, chunk => 0 + $n, ( defined $a{max} ? ( max => $a{max} ) : () ) }, note => $note );
        if ( $s->{pending} ) {
            $res{pending} = 1;
            $res{then} = [ $s->{approve}, $s->{apply} ];
            return $self->_finish( 'drip', \%res, 0 );
        }
        my $status = _step_status($s);
        return $self->_finish( 'drip', \%res, $status ) if !$s->{applied} || $status;
        $self->_drip_record( $id, { at => $self->{clock}->(), chunk => 0 + $n } );
        my $ret = ( $s->{custom} && $s->{custom}[0] ? $s->{custom}[0]{returned} : undef ) // {};
        my $after = $self->_mailing_row( $id, remaining => 1 );
        $k++;
        push @{ $res{chunks} }, { traces_made => $ret->{traces_made}, traces_by_status => $ret->{traces_by_status}, remaining => $after->{remaining}, at => Odoo::Ops::iso_time( $self->{clock}->() ) };
        $self->_p( "chunk $k: " . ( $ret->{traces_made} // '?' ) . ' traces made' . ( $ret->{traces_by_status} ? ' (' . join( ', ', map { "$ret->{traces_by_status}{$_} $_" } sort keys %{ $ret->{traces_by_status} } ) . ')' : '' )
            . '; ' . ( defined $after->{remaining} ? "$after->{remaining} recipient(s) remain" : 'what remains is not worked out' ), _counters_line($after) );
        $res{status} = $after;
        if ( defined $after->{remaining} && !$after->{remaining} ) {
            $res{finished} = 1;
            $self->_p("mailing $id: no recipient remains");
            $res{then} = ["oom-mailshot status --conf $self->{conf} --mailing $id --traces"];
            return $self->_finish( 'drip', \%res, 0 );
        }
        if ( $a{once} ) {
            $res{then} = ["oom-mailshot drip --conf $self->{conf} --mailing $id --chunk $n --every $every --once (again after $every minutes)"];
            return $self->_finish( 'drip', \%res, 0 );
        }
    }
}

# The drip state of a mailing sits in drip/ under the runs_dir (a folder without a plan.json is not a run, so the
# registry skips it): mailing-<id>.lock, held for as long as one drip of the mailing runs, and mailing-<id>.json,
# the time of the last chunk.
sub _drip_dir ($self) {
    my $dir = File::Spec->catdir( $self->{config}->get('runs_dir'), 'drip' );
    mkdir $dir if !-d $dir;
    Odoo::Error->throw( kind => 'config', message => "cannot make $dir: $!", fix => 'the config\'s runs_dir must be writable' ) if !-d $dir;
    return $dir;
}

sub _drip_lock ($self, $id) {
    my $path = File::Spec->catfile( $self->_drip_dir, "mailing-$id.lock" );
    open my $fh, '>>', $path or Odoo::Error->throw( kind => 'config', message => "cannot open $path: $!" );
    flock( $fh, LOCK_EX | LOCK_NB )
        or Odoo::Error->throw( kind => 'refused', code => 'drip-busy',
            message => "another drip of mailing $id is running (it holds $path); two never run at once, so the chunks stay apart",
            fix => 'wait for it, or stop it; a cron or timer call that finds it running can simply try again at its next time' );
    return $fh;
}

sub _drip_record_path ($self, $id) { File::Spec->catfile( $self->_drip_dir, "mailing-$id.json" ) }

sub _drip_last ($self, $id) {
    my $path = $self->_drip_record_path($id);
    return undef if !-e $path;
    open my $fh, '<', $path or return undef;
    my $raw = do { local $/; <$fh> };
    close $fh;
    return eval { Odoo::JSON::decode($raw) };
}

sub _drip_record ($self, $id, $rec) {
    my $path = $self->_drip_record_path($id);
    open my $fh, '>', "$path.new" or Odoo::Error->throw( kind => 'config', message => "cannot write $path.new: $!" );
    print {$fh} Odoo::JSON->new( pretty => 1 )->encode($rec);
    close $fh or Odoo::Error->throw( kind => 'config', message => "cannot write $path.new: $!" );
    rename "$path.new", $path or Odoo::Error->throw( kind => 'config', message => "cannot replace $path: $!" );
    return;
}

# --- status ---------------------------------------------------------------------------------------

=head2 status(mailing, traces, queue, archived)

C<mailing.status> as a table; C<traces> adds one line per recipient and
C<queue> the mail still waiting in Odoo's mail queue. A mailing that is a
slice of a part (its domain holds a contact id range, see L</Slices of a part>)
is shown with the other slices of the part, found in Odoo as the mailings of
the same subject and lists whose domains differ only in the range: each with its
state, schedule, recipients and what is sent or still to go, and a line when the
ranges do not meet end to end. An archived mailing
(a cleanup archives a sent one) is read with C<archived> (C<--archived>);
without it the read is refused C<refused/archived> and the fix names the flag.

=cut

sub status ($self, %a) {
    my $id = $self->_mailing_id( \%a, 'status' );
    my $r = $self->_mailing_row( $id, remaining => 1, ( $a{traces} ? ( traces => 1 ) : () ), ( $a{queue} ? ( queue => 1 ) : () ), ( $a{archived} ? ( archived => 1 ) : () ) );
    my %res = ( mailing => $r, then => [] );
    $self->_p( _counters_line($r), "  subject: $r->{subject}", '  lists: ' . join( ', ', @{ $r->{lists} } ) );
    $self->_p( "  domain: $r->{domain}" ) if length( $r->{domain} // '' ) && $r->{domain} !~ /\A\[\('list_ids', 'in', \[[\d, ]+\]\)\]\z/;
    $self->_p( _still_lines($r) );
    my $group = $self->_slice_group( $r, archived => $a{archived} );
    if ($group) {
        $res{part} = $group;
        $self->_p( '  part: this mailing is ' . ( defined $group->{this} ? "slice $group->{this} of " . scalar @{ $group->{slices} } : 'not among the ' . scalar @{ $group->{slices} } . ' slices read' ) . ' of one message (same subject, lists and filter; each its own contact id range)' );
        for my $g ( @{ $group->{slices} } ) {
            $self->_p( sprintf '    slice %d  mailing %d  %s%s  recipients %s  sent %s%s%s', $g->{n}, $g->{mailing}, $g->{state},
                ( $g->{schedule_date} ? "  scheduled for $g->{schedule_date}" : '' ), $g->{recipients} // '-', $g->{sent} // 0,
                ( $g->{still_to_go} ? "  still to go $g->{still_to_go}" : '' ), ( $g->{mailing} == $r->{id} ? '  (this one)' : '' ) );
        }
        $self->_p("  $_") for @{ $group->{gaps} };
        $self->_p("  $group->{note}") if $group->{note};
    }
    $self->_p( "  remaining: $r->{remaining} recipient(s) have no trace yet (a mailing sent in chunks is done between them; oom-mailshot drip sends the rest)" )
        if $r->{state} eq 'done' && $r->{remaining};
    $self->_p( "  scheduled for $r->{schedule_date}" ) if $r->{schedule_date};
    $self->_p( "  sent on $r->{sent_date}" ) if $r->{sent_date};
    if ( $a{traces} ) {
        $self->_table( [qw(trace email status sent opened clicked)],
            [ map { [ $_->{id}, $_->{email}, $_->{status} . ( $_->{failure_type} ? " ($_->{failure_type})" : '' ), $_->{sent} // '-', $_->{opened} // '-', $_->{clicked} // '-' ] } @{ $r->{traces} } ] );
        $self->_p( '  ' . $r->{traces_note} ) if $r->{traces_note};
    }
    if ( $a{queue} ) {
        $self->_p( defined $r->{queue_note} ? "  mail queue: $r->{queue_note}" : @{ $r->{queue} } ? ( '  mail queue: ' . join( '; ', map { "$_->{state} $_->{count}" . ( $_->{failure_reason} ? " ($_->{failure_reason})" : '' ) } @{ $r->{queue} } ) ) : '  mail queue: empty' );
    }
    if    ( $r->{state} eq 'draft' )    { $res{then} = [ "oom-mailshot test --conf $self->{conf} --mailing $id --to <your address>" ] }
    elsif ( $r->{state} eq 'in_queue' ) { $res{then} = [ "oom-mailshot watch --conf $self->{conf} --mailing $id --until done" ] }
    elsif ( !$a{traces} )               { $res{then} = [ "oom-mailshot status --conf $self->{conf} --mailing $id --traces" . ( $a{archived} ? ' --archived' : '' ) ] }
    return $self->_finish( 'status', \%res, 0 );
}

# The contact id range a slice's domain holds, and the rest of the domain (the lists and any filter) with the range left out
sub _slice_range ($domain) {
    return undef if !defined $domain;
    my ($from)   = $domain =~ /\(\s*'id',\s*'>=',\s*(\d+)\s*\)/;
    my ($before) = $domain =~ /\(\s*'id',\s*'<',\s*(\d+)\s*\)/;
    return undef if !defined $from && !defined $before;
    ( my $base = $domain ) =~ s/,\s*\(\s*'id',\s*'(?:>=|<)',\s*\d+\s*\)//g;
    return { from => $from, before => $before, base => $base =~ s/\s+//gr };
}

# The slices of the part this mailing is one of: the mailings of its subject, lists and filter that differ in the range
# only, as Odoo holds them (nothing is kept here). Undef when the mailing is not a slice.
our $SLICE_READ_LIMIT = 5000;

sub _slice_group ($self, $row, %o) {
    my $me = _slice_range( $row->{domain} ) or return undef;
    # a limit above what one subject can meet; a read the limit still cut says so in the group's note
    my $rep = $self->_read( 'mailing.status', subject => $row->{subject}, limit => $SLICE_READ_LIMIT, ( $o{archived} ? ( archived => 1 ) : () ) );
    my $lists = join "\0", sort @{ $row->{lists} };
    my @all = sort { ( $a->{r}{from} // 0 ) <=> ( $b->{r}{from} // 0 ) || $a->{row}{id} <=> $b->{row}{id} }
        grep { $_->{r} && $_->{r}{base} eq $me->{base} }
        map { +{ row => $_, r => ( $_->{subject} eq $row->{subject} && join( "\0", sort @{ $_->{lists} } ) eq $lists ? _slice_range( $_->{domain} ) : undef ) } } @{ $rep->{rows} };
    my ( $n, @slices, @gaps ) = (0);
    for my $g (@all) {
        my $x = $g->{row};
        $n++;
        my $s = $x->{still_to_go};
        my $go = $s ? join( ', ', map { "$s->{$_}{count} $_" } grep { $s->{$_} && $s->{$_}{count} } qw(outgoing error exception) ) : '';
        push @slices, { n => $n, mailing => $x->{id}, state => $x->{state}, schedule_date => $x->{schedule_date}, recipients => $x->{recipients}, recipients_now => $x->{recipients_now},
            sent => $x->{sent}, still_to_go => $go, from_id => $g->{r}{from}, before_id => $g->{r}{before} };
    }
    return undef if !@slices;
    push @gaps, "the first slice has a lower bound (id >= $slices[0]{from_id}): contacts below it are in no slice" if defined $slices[0]{from_id};
    push @gaps, "the last slice has an upper bound (id < $slices[-1]{before_id}): contacts above it, and any made later, are in no slice" if defined $slices[-1]{before_id};
    for my $i ( 1 .. $#slices ) {
        my ( $p, $q ) = @slices[ $i - 1, $i ];
        next if defined $p->{before_id} && defined $q->{from_id} && $p->{before_id} == $q->{from_id};
        push @gaps, "slices $p->{n} and $q->{n} do not meet: slice $p->{n} ends before id " . ( $p->{before_id} // 'no end' ) . ", slice $q->{n} starts at id " . ( $q->{from_id} // 'no start' );
    }
    my ($mine) = grep { $_->{mailing} == $row->{id} } @slices;
    return { this => $mine ? $mine->{n} : undef, slices => \@slices, gaps => \@gaps, ( $rep->{limit_note} ? ( note => "the group was read from the newest $SLICE_READ_LIMIT mailings of this subject and more may exist: slices of older mailings can be missing" ) : () ) };
}

# --- open-check -----------------------------------------------------------------------------------

=head2 open_check(mailing, email)

Finds the recipient's caught mail, fetches its tracking image through the
instance (the config's C<url> and C<ssl_ca_file>) and reads the status back,
so a tester sees C<opened> move without reading the HTML by hand. Needs the
config's C<mailcatcher>.

Before it looks in the catcher it reads the mailing's traces, so the reason
there is no mail is the right one: an address with no trace is
C<refused/not-recipient>, one whose trace is C<cancel> (opted out,
blacklisted, a repeat address) is C<refused/no-mail> saying so, and only an
address that was mailed and has no caught mail is C<refused/no-mail> naming
the catcher.

=cut

# Why an address may have no mail (item 14), from the traces: ( its trace, the status row read with traces ).
# A refusal when it was never a recipient, or its trace says no mail was made. The traces read stops short on a
# very large mailing; an address not among them is then not judged here.
sub _recipient_trace ($self, $id, $email) {
    my $row = $self->_mailing_row( $id, traces => 1 );
    my ($tr) = grep { lc( $_->{email} // '' ) eq lc $email } @{ $row->{traces} // [] };
    if ( !$tr ) {
        Odoo::Error->throw( kind => 'refused', code => 'not-recipient',
            message => "$email is not a recipient of mailing $id: no trace",
            fix => "oom-mailshot status --conf $self->{conf} --mailing $id --traces shows who was mailed" ) if !$row->{traces_note};
        return ( undef, $row );
    }
    if ( ( $tr->{status} // '' ) eq 'cancel' ) {
        my %why = ( mail_optout => 'opted out', mail_bl => 'blacklisted', mail_dup => 'a repeat address' );
        my $why = $why{ $tr->{failure_type} // '' } // 'opted out, blacklisted or a repeat address';
        Odoo::Error->throw( kind => 'refused', code => 'no-mail',
            message => "mailing $id made no mail for $email: its trace is cancel ($why)",
            fix => "oom-mailshot status --conf $self->{conf} --mailing $id --traces shows each recipient's trace" );
    }
    return ( $tr, $row );
}

# the instance's own web address, through the config's CA: what the tracking GETs go through
sub _instance_http ($self) {
    my $cfg = $self->{config};
    return $self->{instance_http} //= HTTP::Tiny->new( timeout => 30, max_redirect => 0,
        verify_SSL => ( $cfg->get('ssl_verify') // 1 ) ? 1 : 0,
        ( $cfg->get('ssl_ca_file') ? ( SSL_options => { SSL_ca_file => $cfg->get('ssl_ca_file') } ) : () ) );
}

sub _instance_base ($self) { ( my $base = $self->{config}->get('url') ) =~ s{/+\z}{}; $base }

sub open_check ($self, %a) {
    my $id = $self->_mailing_id( \%a, 'open-check' );
    my $email = $a{email} // Odoo::Error->throw( kind => 'usage', message => 'open-check needs --email', fix => 'oom-mailshot open-check --help' );
    Odoo::Error->throw( kind => 'config', message => 'open-check reads the tracking image out of the delivered mail, and the config names no mail catcher',
        fix => 'add mailcatcher = http://127.0.0.1:8025 to the ops config (a development catcher behind the instance\'s outgoing mail)' ) if !$self->_catcher;
    my ( undef, $before ) = $self->_recipient_trace( $id, $email );
    my $mail = $self->_caught( $before->{subject}, $email )
        // Odoo::Error->throw( kind => 'refused', code => 'no-mail',
            message => "$email is a recipient of mailing $id, but the catcher holds no mail for '$before->{subject}' to $email",
            fix => "oom-mailshot status --conf $self->{conf} --mailing $id --traces shows the recipient's trace; the catcher at $self->{config}{mailcatcher} may have been emptied" );
    my $track = $mail->{_track_url}
        // Odoo::Error->throw( kind => 'refused', code => 'no-tracking-image', message => "the mail to $email carries no tracking image",
            fix => 'a test mail has none; open-check is for a recipient of a send' );
    ( my $path = $track ) =~ s{^https?://[^/]+}{};
    $path =~ s/&amp;/&/g;
    my $base = $self->_instance_base;
    my $r = $self->_instance_http->get( $base . $path );
    $self->_p("fetched the tracking image of the mail to $email through $base: HTTP $r->{status}");
    my $after = $self->_mailing_row( $id, traces => 1 );
    my ($tr) = grep { lc( $_->{email} // '' ) eq lc $email } @{ $after->{traces} };
    $self->_p( "opened: $before->{opened} -> $after->{opened}", ( $tr ? "that recipient's trace: $tr->{status}" . ( $tr->{opened} ? ", opened $tr->{opened}" : '' ) : () ) );
    my %res = ( mailing => $id, email => $email, http_status => $r->{status}, opened_before => $before->{opened}, opened_after => $after->{opened},
        trace => $tr, then => [] );
    my $ok = $r->{status} == 200 && $after->{opened} > $before->{opened} ? 0 : 1;
    $self->_p('the counter did not move (an address that was already counted as opened does not count twice)') if $ok;
    return $self->_finish( 'open-check', \%res, $ok );
}

=head2 click_check(mailing, email, link)

What C<open_check> is for an open, for a click. Finds the recipient's trace
(the same refusals: C<not-recipient>, C<no-mail> for a cancelled trace),
reads the mailing's tracked links from C<mailing.preview> (the first, or the
one C<link> names by its address or its short address), GETs C<< <short_url>/m/<trace id> >>
through the instance (the config's C<url> and C<ssl_ca_file>) and reads the
status back, printing C<clicked: 0 -> 1> and the trace. A click also marks the
trace opened, and the output says so when C<opened> moved. Refuses
C<refused/no-tracked-link> when the mailing has none (Odoo shortens links at
send, so a draft has none) and C<transport/click-failed> naming the HTTP
status when the GET fails (the CA is the config's C<ssl_ca_file>). It needs no
catcher: the trace id and the link come from Odoo.

=cut

sub click_check ($self, %a) {
    my $id = $self->_mailing_id( \%a, 'click-check' );
    my $email = $a{email} // Odoo::Error->throw( kind => 'usage', message => 'click-check needs --email', fix => 'oom-mailshot click-check --help' );
    my ( $tr, $before ) = $self->_recipient_trace( $id, $email );
    Odoo::Error->throw( kind => 'refused', code => 'not-recipient',
        message => "no trace of $email among the traces read ($before->{traces_note}), so no click can be made for it",
        fix => "oom-mailshot status --conf $self->{conf} --mailing $id --traces shows who was mailed" ) if !$tr;
    my $pv    = $self->_read( 'mailing.preview', mailing => $id );
    my @links = @{ $pv->{tracked_links} // [] };
    Odoo::Error->throw( kind => 'refused', code => 'no-tracked-link',
        message => "mailing $id has no tracked link: Odoo shortens the links of a body when it sends, and links the body does not carry are not tracked",
        fix => "oom-mailshot status --conf $self->{conf} --mailing $id says whether it was sent; a body needs a link besides the unsubscribe anchor" ) if !@links;
    if ( defined $a{link} ) {
        my @hit = grep { ( $_->{url} // '' ) eq $a{link} || ( $_->{short_url} // '' ) eq $a{link} } @links;
        Odoo::Error->throw( kind => 'refused', code => 'no-tracked-link',
            message => "mailing $id has no tracked link $a{link} (it has: " . join( ', ', map { $_->{url} } @links ) . ')',
            fix => "oom-mailshot click-check --conf $self->{conf} --mailing $id --email $email --link <one of those>" ) if !@hit;
        @links = @hit;
    }
    my $link = $links[0];
    ( my $path = $link->{short_url} // '' ) =~ s{^https?://[^/]+}{};
    my $base = $self->_instance_base;
    my $url  = "$base$path/m/$tr->{id}";
    my $r    = $self->_instance_http->get($url);
    my $st   = $r->{status} // 0;
    if ( $st < 200 || $st >= 400 ) {
        my $why = ( $r->{content} // '' ) =~ s/\s+/ /gr =~ s/\A\s+|\s+\z//gr;
        $why = substr( $why, 0, 160 ) if length $why > 160;
        Odoo::Error->throw( kind => 'transport', code => 'click-failed',
            message => "click-check: GET $url failed: HTTP $st" . ( length $why ? " ($why)" : '' ),
            fix => 'the GET goes to the config\'s url and trusts the CA in its ssl_ca_file: oom-ops doctor --conf ' . $self->{conf} . ' checks both' );
    }
    $self->_p("followed the tracked link $link->{url} for the trace of $email (trace $tr->{id}) through $base: HTTP $st");
    my $after = $self->_mailing_row( $id, traces => 1 );
    my ($tr2) = grep { $_->{id} == $tr->{id} } @{ $after->{traces} // [] };
    $self->_p( "clicked: $before->{clicked} -> $after->{clicked}",
        ( $tr2 ? "that recipient's trace: $tr2->{status}" . ( $tr2->{clicked} ? ", clicked $tr2->{clicked}" : '' ) . ( $tr2->{opened} ? ", opened $tr2->{opened}" : '' ) : () ) );
    $self->_p("a click also marks the trace opened: opened $before->{opened} -> $after->{opened}") if $after->{opened} > $before->{opened};
    my %res = ( mailing => $id, email => $email, link => $link->{url}, trace_id => $tr->{id}, http_status => $st,
        clicked_before => $before->{clicked}, clicked_after => $after->{clicked}, opened_before => $before->{opened}, opened_after => $after->{opened},
        also_opened => $after->{opened} > $before->{opened} ? 1 : 0, trace => $tr2, then => [] );
    my $moved = $after->{clicked} > $before->{clicked};
    $self->_p('the counter did not move (an address that was already counted as clicked does not count twice)') if !$moved;
    return $self->_finish( 'click-check', \%res, $moved ? 0 : 1 );
}

# --- cleanup --------------------------------------------------------------------------------------

=head2 cleanup(stamp, keep_sent, keep_mail, check)

Removes what a stamp made: drafts (C<mailing.delete>), blacklist rows
(C<mailing.blacklisted> finds them, with or without a contact, and
C<mailing.blacklist> remove takes them off), the lists and contacts a
C<mailing.subscribe> run of this registry made (C<revert> of the run), and
then whatever still carries the stamp that no run of this registry made,
deleted outright by C<mailing.delete> (contacts by address, lists by id). The
report names what was deleted outright. A sent mailing is archived
(C<mailing.archive>), or left live with C<keep_sent>; it is the record of what
went out, and the report says what stayed and why. Needs a tool that may
approve (C<--yes> or C<approval = self>), since it applies several plans,
unless there is nothing to do: then it prints C<would do nothing>, offers no
C<then:> line and exits 0.

Where the runner or an operation refuses a step (a revert of a run another
login made, a list a mailing still names), cleanup prints the refusal with its
C<fix:> line under C<stayed:>, carries on with the rest, and exits 1 when
anything was refused. A change that failed part-way exits 3.

C<check> (C<--check>) lists what a cleanup would plan and records and changes
nothing: each draft deleted, each sent mailing archived, each blacklist row
taken off, each revert with the records it would undo (the lists, contacts and
tags of the run's journal, by id and name; one the run made that carries no
stamp is marked C<(made by this run)>), what would be deleted outright, what
would stay and why, and, when the config names a C<mailcatcher>, the mails in
it that match the stamp (count and subjects). Without approval, C<cleanup> prints
that same listing and then stops with the C<needs-approval> refusal, so what is
at stake is seen before C<--yes> is passed.

A subscribe run is found by the run registry's record index: a run of
C<mailing.subscribe> whose journal holds a stamped list or contact, in any state
that wrote something, and a run that carries the stamp in its parameters.

The applied run's C<removed:> block names the records of each revert the same
way (C<list 59 "T3-1705 List">, C<contacts 172 173>, C<tags 46 "t3-1705" 47
"trade" (made by this run)>). With a catcher in the config it also deletes the
catcher's mails that match the stamp (by id, found by subject and by recipient)
and reports C<catcher: removed N>; C<keep_mail> (C<--keep-mail>) leaves them and
says C<catcher: kept N>. Without a catcher it says nothing of one.

=cut

# What a mailing carrying the stamp needs: the steps (verb, operation) and, when it stays, why.
sub _mailing_plan ($m, $keep_sent) {
    my ( @steps, $why );
    if    ( $m->{state} eq 'draft' )    { @steps = ( [ delete => 'mailing.delete' ] ) }
    elsif ( $m->{state} eq 'in_queue' ) { @steps = ( [ cancel => 'mailing.cancel' ], [ delete => 'mailing.delete' ] ) }
    elsif ( $keep_sent )                { $why = "$m->{state}: the record of what went out, kept live (--keep-sent)" }
    elsif ( !$m->{active} )             { $why = "$m->{state}: the record of what went out, already archived; its traces are kept" }
    elsif ( $m->{state} eq 'done' )     { @steps = ( [ archive => 'mailing.archive' ] ); $why = 'done: the record of what went out, archived and kept with its traces' }
    else                                { $why = "$m->{state}: Odoo is still sending it; cleanup again when it is done" }
    return ( \@steps, $why );
}

# The subscribe runs of this registry that wrote something carrying the stamp, newest first, with a journal to revert:
# the run registry's record index (a run that touched a stamped list or contact, whatever name it gave the list) and the
# stamp in the run's parameters. A run that wrote nothing has nothing to revert; a reverted run is done.
sub _subscribe_runs ($self, $stamp) {
    my ( $lists, $contacts ) = ( $self->_read( 'mailing.lists', name => $stamp, archived => 1 ), $self->_read( 'mailing.contacts', email => $stamp, limit => 5000 ) );
    my %mine = ( ( map { ( "mailing.list:$_->{id}" => 1 ) } @{ $lists->{rows} } ), ( map { ( "mailing.contact:$_->{id}" => 1 ) } @{ $contacts->{rows} } ) );
    return grep {
        my $r = $_;
        my @touched = $self->{runs}->touched($r);
        @touched && $r->{state} ne 'reverted'
            && -e File::Spec->catfile( $self->{runs}->dir, $r->{id}, 'journal.jsonl' )
            && ( index( lc( $r->{params}{list} // '' ), lc $stamp ) >= 0 || grep { $mine{$_} } @touched )
    } $self->{runs}->list( op => 'mailing.subscribe' );
}

# what a delete of a stamped list outright says it is
sub _list_text ($l) { "delete list $l->{id} ($l->{name}) outright (no revert of this cleanup undoes it)" }
sub _contacts_text ($addr) { 'delete ' . join( ', ', map { "contact $_" } @$addr ) . ' outright (no revert of this cleanup undoes ' . ( @$addr > 1 ? 'them' : 'it' ) . ')' }

# a refusal the runner raised, as a "stayed" entry: its message and its fix, so the caller can act on them
sub _refusal ($self, $what, $e) {
    die $e if !( blessed($e) && $e->isa('Odoo::Error') && $e->is_refused );
    my $fix = $e->fix;
    $fix =~ s/<conf>/$self->{conf}/g if defined $fix;
    return { what => $what, why => $e->message, ( defined $fix ? ( fix => $fix ) : () ), refused => 1 };
}

sub _revert_of ($self, $run) {
    my $ctx  = $self->_ctx;
    my $plan = $ctx->guard->with_scope( {}, 'revert', sub { Odoo::Ops::Runner->revert_plan( $ctx, File::Spec->catfile( $self->{runs}->dir, $run->{id}, 'journal.jsonl' ) ) } );
    return ( $ctx, $plan );
}

# the records a revert plan would unlink: [ { model, id, name, stamped } ], from the journal's read-back images
sub _revert_records ( $plan, $stamp ) {
    my @r;
    for my $c ( grep { $_->{bucket} eq 'undo-create' } @{ $plan->changes } ) {
        my $b    = $c->{before} // {};
        # not a slice: grep aliases its list, and that would add the missing keys to the plan's before-image
        my $text = lc join ' ', grep { defined } map { $b->{$_} } qw(name email);
        push @r, { model => $c->{model}, id => $c->{id}, name => $c->{model} eq 'mailing.contact' ? $b->{email} // $b->{name} : $b->{name} // $b->{email} // $b->{display_name},
            stamped => index( $text, lc $stamp ) >= 0 ? 1 : 0 };
    }
    return \@r;
}

# the records as lines, one per model: list 59 "T3-1705 List" / contacts 172 173 / tags 46 "t3-1705" 47 "trade" (made by this run)
sub _record_lines ($recs) {
    my %label = ( 'mailing.list' => [ 'list', 'lists' ], 'mailing.contact' => [ 'contact', 'contacts' ], 'res.partner.category' => [ 'tag', 'tags' ] );
    my @order = ( 'mailing.list', 'mailing.contact', 'res.partner.category' );
    my %by;
    push @{ $by{ $_->{model} } }, $_ for @$recs;
    my %known = map { $_ => 1 } @order;
    my @lines;
    for my $model ( @order, sort grep { !$known{$_} } keys %by ) {
        my @r = sort { $a->{id} <=> $b->{id} } @{ $by{$model} // [] } or next;
        my ( $one, $many ) = @{ $label{$model} // [ $model, $model ] };
        my @tok = map {
            my $x = $_;
            $model eq 'mailing.contact' && $x->{stamped} ? $x->{id}
                : join( ' ', $x->{id}, ( defined $x->{name} ? qq("$x->{name}") : () ), ( $x->{stamped} ? () : '(made by this run)' ) )
        } @r;
        push @lines, ( @r == 1 ? $one : $many ) . ' ' . join( ' ', @tok );
    }
    return \@lines;
}

# --- the catcher's mails of a stamp ---------------------------------------------------------------

# { mails => [ { id, subject } ] } of the catcher's mail whose subject or recipient carries the stamp, or { error }
sub _catcher_mails ($self, $stamp) {
    my $base = $self->_catcher =~ s{/+\z}{}r;
    my ( %seen, @mails );
    for my $q ( qq(subject:"$stamp"), qq(to:"$stamp") ) {
        my $r = $self->_http->get( "$base/api/v1/search?query=" . _urlenc($q) . '&limit=500' );
        return { error => "the catcher at $base answered HTTP " . ( $r->{status} // 0 ) } if !$r->{success};
        my $d = eval { Odoo::JSON::decode( $r->{content} ) } // {};
        for my $m ( @{ $d->{messages} // [] } ) {
            next if $seen{ $m->{ID} }++;
            push @mails, { id => $m->{ID}, subject => $m->{Subject} // '' };
        }
    }
    return { mails => \@mails };
}

sub _catcher_subjects ($mails) {
    my %n;
    $n{ $_->{subject} }++ for @$mails;
    return [ map { +{ subject => $_, count => $n{$_} } } sort keys %n ];
}

# what a cleanup does with the catcher: nothing said without one; with one, removes the stamp's mails (by id) or, with keep, leaves them
sub _cleanup_catcher ($self, $stamp, %o) {
    return undef if !$self->_catcher;
    my $c = $self->_catcher_mails($stamp);
    if ( $c->{error} ) { $self->_p("catcher: not read ($c->{error})"); return { error => $c->{error} } }
    my $n = @{ $c->{mails} };
    if ( $o{keep} || $o{failed} ) {
        $self->_p( "catcher: kept $n" . ( $o{failed} && !$o{keep} ? ' (a change failed; run cleanup again once it is put right)' : '' ) );
        return { kept => $n, subjects => _catcher_subjects( $c->{mails} ) };
    }
    if ($n) {
        my $base = $self->_catcher =~ s{/+\z}{}r;
        my $r = $self->_http->request( 'DELETE', "$base/api/v1/messages",
            { headers => { 'Content-Type' => 'application/json' }, content => Odoo::JSON::encode( { IDs => [ map { $_->{id} } @{ $c->{mails} } ] } ) } );
        if ( !$r->{success} ) { $self->_p( "catcher: kept $n (the delete answered HTTP " . ( $r->{status} // 0 ) . ')'); return { kept => $n, error => "HTTP " . ( $r->{status} // 0 ) } }
    }
    $self->_p("catcher: removed $n");
    return { removed => $n, subjects => _catcher_subjects( $c->{mails} ) };
}

# --- what a cleanup would do ------------------------------------------------------------------------

# Reads only. { would => [ { text, lines, records } ], kept => [ { what, why } ], catcher => { mails } | { error } | undef }
sub _cleanup_listing ($self, $stamp, %a) {
    my ( @would, @kept, %gone );
    my $ms = $self->_read( 'mailing.status', subject => $stamp, archived => 1 );
    for my $m ( grep { index( lc $_->{subject}, lc $stamp ) >= 0 } @{ $ms->{rows} } ) {
        my $what = "mailing $m->{id} ($m->{subject})";
        my ( $steps, $why ) = _mailing_plan( $m, $a{keep_sent} );
        push @would, { text => "$_->[0] $what" } for @$steps;
        push @kept, { what => $what, why => $why } if defined $why;
    }
    my $bl = $self->_read( 'mailing.blacklisted', contains => $stamp, limit => 5000 );
    push @would, { text => "unblacklist $_->{email}" } for @{ $bl->{rows} };
    for my $r ( $self->_subscribe_runs($stamp) ) {
        my ( undef, $plan ) = eval { $self->_revert_of($r) };
        if ( !$plan ) { push @kept, $self->_refusal( "revert $r->{id}", $@ ); next }
        my $s = $plan->summary;
        push @kept, { what => "revert $r->{id}", why => join( '; ', map { "$_->{bucket}: $_->{reason}" } @{ $s->{held} } ), refused => 1 } if @{ $s->{held} };
        next if $s->{nothing_to_apply};
        my $recs = _revert_records( $plan, $stamp );
        $gone{ $_->{model} }{ $_->{id} } = 1 for @$recs;
        push @would, { text => "revert $r->{id} (mailing.subscribe)", lines => _record_lines($recs), records => $recs };
    }
    my $own_c = $self->_read( 'mailing.contacts', email => $stamp, limit => 5000 );
    my @left_c = grep { !$gone{'mailing.contact'}{ $_->{id} } } @{ $own_c->{rows} };
    my @addr = map { $_->{email} } grep { length $_->{email} } @left_c;
    my @ids  = map { $_->{id} } grep { !length $_->{email} } @left_c;
    push @would, { text => _contacts_text(\@addr) } if @addr;
    push @would, { text => 'delete contact ' . join( ', ', @ids ) . ' outright' } if @ids;
    my $own_l = $self->_read( 'mailing.lists', name => $stamp, archived => 1 );
    push @would, { text => _list_text($_) } for grep { !$gone{'mailing.list'}{ $_->{id} } } @{ $own_l->{rows} };
    return { would => \@would, kept => \@kept, catcher => ( $self->_catcher ? $self->_catcher_mails($stamp) : undef ) };
}

sub _print_listing ($self, $stamp, $l, $check) {
    $self->_p( "cleanup " . ( $check ? '--check' : '(not approved)' ) . ": what a cleanup of the stamp '$stamp' would do; nothing is changed or recorded" );
    for my $w ( @{ $l->{would} } ) {
        $self->_p("  would $w->{text}");
        $self->_p("      $_") for @{ $w->{lines} // [] };
    }
    $self->_p('  would do nothing') if !@{ $l->{would} };
    for ( @{ $l->{kept} } ) {
        $self->_p("  would keep $_->{what}: $_->{why}");
        $self->_p("      fix: $_->{fix}") if defined $_->{fix};
    }
    if ( my $c = $l->{catcher} ) {
        if ( $c->{error} ) { $self->_p("  catcher: not read ($c->{error})") }
        else {
            my $n = @{ $c->{mails} };
            $self->_p( "  catcher at $self->{config}{mailcatcher}: would remove $n mail(s) whose subject or recipient carries '$stamp'" . ( $n ? ':' : '' ) );
            $self->_p( sprintf '    %-4d %s', $_->{count}, $_->{subject} ) for @{ _catcher_subjects( $c->{mails} ) };
        }
    }
    return;
}

sub cleanup ($self, %a) {
    $self->{cmd} = 'cleanup';
    my $stamp = $a{stamp} // Odoo::Error->throw( kind => 'usage', message => 'cleanup needs --stamp', fix => 'oom-mailshot cleanup --help' );
    Odoo::Error->throw( kind => 'usage', message => "a stamp of fewer than 4 characters would match too much ('$stamp')", fix => 'use the token the stamped records carry' ) if length $stamp < 4;
    if ( $a{check} || !$self->_auto ) {
        my $l = $self->_cleanup_listing( $stamp, %a );
        $self->_print_listing( $stamp, $l, $a{check} );
        # nothing to remove (and no catcher mail to purge): the listing says so, no `then:` offers a --yes that would do
        # nothing, and the plain form is not a refusal because there is nothing for the approval to cover
        my $nothing = !@{ $l->{would} } && !( $l->{catcher} && !$l->{catcher}{error} && @{ $l->{catcher}{mails} } );
        if ( $a{check} || $nothing ) {
            my %res = (
                stamp => $stamp, check => ( $a{check} ? 1 : 0 ), would => [ map { +{ text => $_->{text}, ( $_->{records} ? ( records => $_->{records} ) : () ) } } @{ $l->{would} } ],
                stayed => $l->{kept}, then => ( $nothing ? [] : [ "oom-mailshot cleanup --conf $self->{conf} --stamp " . _q($stamp) . ' --yes' ] ),
            );
            $res{catcher} = $l->{catcher}{error} ? { error => $l->{catcher}{error} } : { would_remove => scalar @{ $l->{catcher}{mails} }, subjects => _catcher_subjects( $l->{catcher}{mails} ) } if $l->{catcher};
            return $self->_finish( 'cleanup', \%res, 0 );
        }
        Odoo::Error->throw( kind => 'refused', code => 'needs-approval',
            message => 'cleanup applies several plans in one call and the tool is not allowed to approve them (the listing above is what it would do)',
            fix => 'pass --yes, or put approval = self in the ops config' );
    }
    my ( @removed, @kept, $failed );
    my $do = sub ( $what, $op, $params ) {
        my $s = $self->_step( $what, $op, $params, note => "oom-mailshot cleanup --stamp $stamp: $what" );
        if ( $s->{applied} && !$s->{ok} ) { $failed = 1; push @kept, { what => $what, why => 'the apply failed: ' . join( '; ', @{ $s->{failures} // [] } ) }; return }
        push @removed, { what => $what } if $s->{applied};
        push @kept, { what => $what, why => join( '; ', map { "$_->{bucket}: $_->{reason}" } @{ $s->{held} } ), refused => 1 } if @{ $s->{held} };
        return $s;
    };

    my $ms = $self->_read( 'mailing.status', subject => $stamp, archived => 1 );
    my @stamped = grep { index( lc $_->{subject}, lc $stamp ) >= 0 } @{ $ms->{rows} };
    for my $m (@stamped) {
        my $what = "mailing $m->{id} ($m->{subject})";
        my ( $steps, $why ) = _mailing_plan( $m, $a{keep_sent} );
        $do->( "$_->[0] $what", $_->[1], { mailing => $m->{id} } ) for @$steps;
        push @kept, { what => $what, why => $why } if defined $why;
    }

    # the blacklist is read as itself, so a stamped row with no contact is found too
    my $bl = $self->_read( 'mailing.blacklisted', contains => $stamp, limit => 5000 );
    for my $b ( @{ $bl->{rows} } ) {
        $do->( "unblacklist $b->{email}", 'mailing.blacklist', { email => $b->{email}, mode => 'remove' } );
    }

    # the lists and contacts a subscribe run of this registry made, newest first
    for my $r ( $self->_subscribe_runs($stamp) ) {
        my $what = "revert $r->{id}";
        $self->_p("== $what (mailing.subscribe)");
        my ( $ctx, $plan ) = eval { $self->_revert_of($r) };
        if ( !$plan ) {
            my $k = $self->_refusal( $what, $@ );
            $self->_p( "   refused: $k->{why}", ( defined $k->{fix} ? "   fix: $k->{fix}" : () ) );
            push @kept, $k;
            next;
        }
        my $s = $plan->summary;
        my %step = ( label => $what, op => 'revert', buckets => $s->{buckets}, held => $s->{held} );
        if ( $s->{nothing_to_apply} ) {
            $self->_print_summary( $plan, undef );
            push @kept, { what => $what, why => join( '; ', map { "$_->{bucket}: $_->{reason}" } @{ $s->{held} } ), refused => 1 };
            push @{ $self->{steps} }, \%step;
            next;
        }
        my $recs = _revert_records( $plan, $stamp );
        my $dir = $ctx->run_dir('revert');
        $self->_print_summary( $plan, basename($dir) );
        $plan->save( File::Spec->catfile( $dir, 'plan.json' ) );
        Odoo::Ops::Runs->index_plan( $dir, $plan, now => $ctx->now, ttl => $ctx->plan_ttl, by => $ctx->actor, reverts => $r->{id} );
        Odoo::Ops::Runs->approve_plan( $dir, $plan, by => $ctx->actor, note => "oom-mailshot cleanup --stamp $stamp: $what", ttl => $ctx->plan_ttl, now => $ctx->now )
            if $ctx->approval ne 'none';
        my $result = Odoo::Ops::Runner->apply( $ctx, $plan, dir => $dir );
        $result->save( File::Spec->catfile( $dir, 'result.json' ) );
        @step{qw(run_id applied ok)} = ( basename($dir), 1, $result->ok ? 1 : 0 );
        push @{ $self->{steps} }, \%step;
        # the same counts a delete prints, so a revert is not the one write of a cleanup without a verified count
        my $h = $result->to_hash;
        my $undone = join ', ', map { "$_ $h->{by_bucket}{$_}{done}" } grep { $h->{by_bucket}{$_}{done} } sort keys %{ $h->{by_bucket} // {} };
        @step{qw(verified not_verified)} = @$h{qw(verified not_verified)};
        $self->_p( "applied $step{run_id}: " . ( $result->ok ? 'ok' : 'FAILED' ) . ", undone $h->{counts}{done}, verified $h->{verified}, not verified $h->{not_verified}"
            . ( length $undone ? " ($undone)" : '' )
            . ( $h->{counts}{failed} ? ", FAILED $h->{counts}{failed}" : '' ) . ( $h->{counts}{unknown} ? ", UNKNOWN $h->{counts}{unknown} (sent, no answer: look in Odoo before sending again)" : '' ) . ( $h->{counts}{not_attempted} ? ", not attempted $h->{counts}{not_attempted}" : '' ) );
        if ( $result->ok ) { push @removed, { what => $what, lines => _record_lines($recs), records => $recs } } else { $failed = 1; push @kept, { what => $what, why => 'the revert failed' } }
        push @kept, { what => $what, why => join( '; ', map { "$_->{bucket}: $_->{reason}" } @{ $s->{held} } ), refused => 1 } if @{ $s->{held} };
    }

    # whatever still carries the stamp and no run of this registry made it is deleted outright, by what it
    # is called: its address or its name. Where mailing.delete holds one (a list a mailing still names is in-use),
    # the hold is reported and the rest goes on.
    my $own_c = $self->_read( 'mailing.contacts', email => $stamp, limit => 5000 );
    if ( @{ $own_c->{rows} } ) {
        my @addr = map { $_->{email} } grep { length $_->{email} } @{ $own_c->{rows} };
        my @ids = map { $_->{id} } grep { !length $_->{email} } @{ $own_c->{rows} };
        $do->( _contacts_text(\@addr), 'mailing.delete', { email => join( ',', @addr ) } ) if @addr;
        $do->( 'delete contact ' . join( ', ', @ids ) . ' outright', 'mailing.delete', { contact => join( ',', @ids ) } ) if @ids;
    }
    my $own_l = $self->_read( 'mailing.lists', name => $stamp, archived => 1 );
    $do->( _list_text($_), 'mailing.delete', { list => $_->{id} } ) for @{ $own_l->{rows} };

    $self->_p( 'removed:', ( @removed ? ( map { ( "  $_->{what}", map { "    $_" } @{ $_->{lines} // [] } ) } @removed ) : '  nothing' ) );
    $self->_p( 'stayed:',  ( @kept ? ( map { ( "  $_->{what}: $_->{why}", ( defined $_->{fix} ? "      fix: $_->{fix}" : () ) ) } @kept ) : '  nothing' ) );
    my $catcher = $self->_cleanup_catcher( $stamp, keep => $a{keep_mail}, failed => $failed );
    return $self->_finish( 'cleanup', { stamp => $stamp, removed => [ map { $_->{what} } @removed ],
        removed_records => [ map { +{ what => $_->{what}, records => $_->{records} } } grep { $_->{records} } @removed ],
        stayed => \@kept, ( $catcher ? ( catcher => $catcher ) : () ), then => [] }, $failed ? 3 : ( grep { $_->{refused} } @kept ) ? 1 : 0 );
}

1;

__END__

=head1 SEE ALSO

L<oom-mailshot>, L<Odoo::Ops::Mailing::Create>, L<Odoo::Ops::Mailing::Send>,
L<Odoo::Ops::Runs>, F<docs/use-cases/mailshot.md>.

=cut
