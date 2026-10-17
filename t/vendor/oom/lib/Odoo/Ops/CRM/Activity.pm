package Odoo::Ops::CRM::Activity;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::CRM::Activity - schedule reviewed to-do activities on leads

=head1 DESCRIPTION

C<crm.activity>: C<file> is JSON lines, one reviewed row per lead. The
default C<action> is C<schedule>:

    {"id": 92, "summary": "Follow up: timesheet integration",
     "note": "Call about the timesheet integration", "due": "2026-10-02",
     "user": "Sam Reddy", "type": "Grant review",
     "brief": "<p>Full background for the lead's Internal Notes...</p>"}

The owner's rule (2026-10-02): an activity carries a one-line C<note>
only - its note vanishes once the activity is done - and the full
C<brief> goes into the lead's Internal Notes (the body field), which
this operation appends in the same plan unless that text is already
there. Chatter notes are for status and events (C<crm.note>).

Three more actions edit what exists, each naming the activity by its
C<activity> id or by the C<summary> of the lead's open activity (held
as C<no-activity> or C<ambiguous> when that does not name exactly one):

    {"id": 92, "action": "edit",   "summary": "Follow up", "set": {"due": "2026-10-09", "note": "Ring after 2pm", "user": "Sam Reddy", "summary": "Follow up (moved)"}}
    {"id": 92, "action": "done",   "summary": "Follow up", "feedback": "Spoke to Jane; sending the quote"}
    {"id": 92, "action": "cancel", "activity": 203}

C<edit> writes the activity with a before-image (revertable); C<done>
marks it done through Odoo's own C<action_feedback> (the feedback
lands in the chatter, the activity goes, and Odoo chains the next one
if the type says so); C<cancel> unlinks it. Odoo lets the creator or
the assignee write or unlink an activity and refuses anyone else; a
refusal is a failed change, by name.

C<type> names an activity type (default: Odoo's To-Do). A type
configured in Odoo to trigger a next activity chains by itself: when
the assignee marks it done, Odoo creates the next one for that type's
default user - how a review hands back to the person who follows up.

The to-do goes to C<user> if given (login or name), otherwise to the
lead's salesperson - the owner's rule is that the person the contact
knows follows up. Held, never scheduled: a lead with no one to assign
(C<no-assignee>), a won lead (C<won>), a lead carrying the C<block_tag>
(default "OCA - do not canvass"). A lead that already has an open
activity with the same summary is C<unchanged>, so re-runs add nothing.

Scheduling goes through the lead's own C<activity_schedule> (Odoo
resolves the model and the To-Do type itself) with
C<mail_activity_quick_update>, so Odoo does not email an "activity
assigned" notice from the configured user - the to-do still appears in
the assignee's activities. Activities are created as not automated, so
Odoo checks the assignee can read the lead and refuses the change if
not (e.g. a salesperson with "Own Documents Only" on someone else's
lead). Held as irreversible by C<revert>; an activity is removed in
Odoo by marking it done or cancelling it.

=cut

sub op_name ($class) { 'crm.activity' }
sub summary ($class) { 'Schedule reviewed to-do activities for each lead\'s salesperson' }
sub pack    ($class) { 'crm' }
# What a plan of this operation sorts rows into (oom-ops describe prints them;
# t/99-declared-buckets.t checks them against what the tests plan).
sub buckets ($class) {
    return [
        { name => 'schedule', meaning => 'a to-do activity is scheduled on the lead; its brief is appended to the lead\'s Internal Notes unless already there' },
        { name => 'brief', meaning => 'the full brief is written to the lead\'s Internal Notes (body)' },
        { name => 'edit', meaning => 'an open activity of the lead is changed (due date, note, user or summary), with a before-image' },
        { name => 'done', meaning => 'an open activity is marked done through Odoo\'s action_feedback' },
        { name => 'cancel', meaning => 'an open activity is removed' },
        { name => 'unchanged', meaning => 'the lead already has an open activity with this summary; nothing to add' },
    ];
}
sub holds ($class) {
    return [
        { name => 'lead-gone', meaning => 'the lead is not readable: it does not exist or this user cannot see it' },
        { name => 'no-assignee', meaning => 'the lead has no salesperson and the row names no user to give the activity to' },
        { name => 'won', meaning => 'the lead is won; no follow-up is scheduled on it' },
        { name => 'blocked', meaning => 'the lead carries the block tag (default "OCA - do not canvass")' },
        { name => 'no-activity', meaning => 'edit, done or cancel names no open activity of the lead' },
        { name => 'ambiguous', meaning => 'edit, done or cancel names more than one open activity of the lead' },
    ];
}

sub params ($class) {
    {   file      => { type => 'path', required => 1, help => 'JSON lines: {id, action?, summary, note, due, user?, type?, brief?} | {id, action: edit|done|cancel, activity|summary, set|feedback}' },
        block_tag => { type => 'str', default => 'OCA - do not canvass', help => 'leads with this tag are never scheduled' },
    };
}
sub read_scope ($class) {
    {   lead            => [qw(search_read read)],
        tag             => [qw(search_read read)],
        stage           => ['search_read'],
        'mail.activity'      => [qw(search_read read)],    # read: the verify read-back
        'mail.activity.type' => ['search_read'],
        'res.users'          => ['search_read'],
    };
}
sub write_scope ($class) { { lead => [qw(activity_schedule write)], 'mail.activity' => [qw(write unlink action_feedback)] } }

sub plan ($self) {
    my $p    = $self->profile;
    my @rows = $self->_read_file( $self->param('file') );
    my ( $sp_f, $tags_f, $stage_f, $notes_f ) = map { $p->field( lead => $_ ) } qw(salesperson tags stage notes);
    my %lead = map { $_->{id} => $_ } @{ $self->model('lead')->read( [ map { 0 + $_->{id} } @rows ], [ $sp_f, $tags_f, $stage_f, $notes_f ] ) };

    my $won = $self->model('stage')->search_read( [ [ $p->field( stage => 'won' ), '=', JSON::PP::true ] ], ['id'] );
    my %won = map { $_->{id} => 1 } @$won;
    my $nf  = $p->field( tag => 'name' );
    my ($block) = map { $_->{id} } @{ $self->model('tag')->search_read( [ [ $nf, '=ilike', $self->param('block_tag') ] ], [$nf] ) };

    # the leads' open activities, with what an edit may touch
    my %open;
    push @{ $open{ $_->{res_id} } }, $_ for @{ $self->model('mail.activity')->search_read(
        [ [ 'res_model', '=', $p->model_name('lead') ], [ 'res_id', 'in', [ map { 0 + $_->{id} } @rows ] ] ],
        [qw(res_id summary note date_deadline user_id activity_type_id)] ) };

    my $plan = $self->new_plan( input_count => scalar @rows );
    for my $r (@rows) {
        my $l      = $lead{ $r->{id} };
        my $key    = "lead:$r->{id}";
        my $action = $r->{action} // 'schedule';
        Odoo::Error->throw( kind => 'usage', message => "lead $r->{id}: unknown action '$action'" )
            if $action !~ /^(schedule|edit|done|cancel)\z/;
        if ( !$l ) { $plan->add( bucket => 'lead-gone', action => 'hold', key => $key, reason => 'lead not readable' ); next }

        if ( $action eq 'schedule' ) {
            $self->_plan_schedule( $plan, $r, $l, $key, \%won, $block, $open{ $r->{id} } // [], $sp_f, $tags_f, $stage_f, $notes_f );
            next;
        }
        my $a = $self->_pick_activity( $plan, $r, $key, $open{ $r->{id} } // [] ) or next;
        my $akey = "$key activity:$a->{id}";
        if ( $action eq 'edit' ) {
            my $set = $r->{set};
            Odoo::Error->throw( kind => 'usage', message => "lead $r->{id}: edit needs a set object" ) if ref $set ne 'HASH';
            my ( %vals, %before );
            for my $k ( sort keys %$set ) {
                my $v = $set->{$k};
                if    ( $k eq 'summary' ) { $vals{summary} = $v;  $before{summary} = $a->{summary} }
                elsif ( $k eq 'note' )    { $vals{note} = $v;     $before{note} = $a->{note} }
                elsif ( $k eq 'due' ) {
                    Odoo::Error->throw( kind => 'usage', message => "lead $r->{id}: due must be YYYY-MM-DD" ) if ( $v // '' ) !~ /^\d{4}-\d\d-\d\d\z/;
                    $vals{date_deadline} = $v; $before{date_deadline} = $a->{date_deadline};
                }
                elsif ( $k eq 'user' ) { $vals{user_id} = 0 + $self->_user_id($v); $before{user_id} = $a->{user_id} }
                else { Odoo::Error->throw( kind => 'usage', message => "lead $r->{id}: edit cannot set '$k' (summary, note, due, user)" ) }
            }
            my @changed = grep { !_same_value( $vals{$_}, $before{$_} ) } keys %vals;
            if ( !@changed ) { $plan->add( bucket => 'unchanged', action => 'skip', id => $a->{id}, key => $akey, reason => 'activity already as requested' ); next }
            $plan->add( bucket => 'edit', action => 'write', model => 'mail.activity', id => $a->{id}, key => $akey,
                vals => { map { $_ => $vals{$_} } @changed }, before => { map { $_ => $before{$_} } @changed } );
        }
        elsif ( $action eq 'done' ) {
            $plan->add( bucket => 'done', action => 'call', model => 'mail.activity', id => $a->{id}, ids => [ 0 + $a->{id} ],
                method => 'action_feedback', key => $akey,
                kwargs => { feedback => $r->{feedback} // '' },
                before => { summary => $a->{summary}, date_deadline => $a->{date_deadline}, user_id => $a->{user_id} },
                reason => 'done: the activity is removed by Odoo and its feedback kept in the chatter' );
        }
        else {    # cancel
            $plan->add( bucket => 'cancel', action => 'unlink', model => 'mail.activity', id => $a->{id}, key => $akey,
                before => { summary => $a->{summary}, note => $a->{note}, date_deadline => $a->{date_deadline}, user_id => $a->{user_id} } );
        }
    }
    return $plan;
}

# the one open activity a row names, or a hold
sub _pick_activity ($self, $plan, $r, $key, $open) {
    my @cand;
    if ( defined $r->{activity} ) {
        @cand = grep { $_->{id} == $r->{activity} } @$open;
    }
    elsif ( defined $r->{summary} ) {
        @cand = grep { lc( $_->{summary} // '' ) eq lc $r->{summary} } @$open;
    }
    else {
        Odoo::Error->throw( kind => 'usage', message => "lead $r->{id}: $r->{action} needs activity (id) or summary" );
    }
    if ( @cand == 1 ) { return $cand[0] }
    $plan->add( bucket => @cand ? 'ambiguous' : 'no-activity', action => 'hold', key => $key,
        reason => @cand ? scalar(@cand) . ' open activities match' : 'no open activity matches' );
    return undef;
}

sub _plan_schedule ($self, $plan, $r, $l, $key, $won, $block, $open, $sp_f, $tags_f, $stage_f, $notes_f) {
    if ( ref $l->{$stage_f} && $won->{ $l->{$stage_f}[0] } ) {
        $plan->add( bucket => 'won', action => 'hold', key => $key, reason => 'won - no re-contact activity' );
        return;
    }
    if ( $block && grep { $_ == $block } @{ $l->{$tags_f} // [] } ) {
        $plan->add( bucket => 'blocked', action => 'hold', key => $key, reason => 'tagged ' . $self->param('block_tag') );
        return;
    }
    Odoo::Error->throw( kind => 'usage', message => "lead $r->{id}: needs summary and due (YYYY-MM-DD)" )
        if !$r->{summary} || ( $r->{due} // '' ) !~ /^\d{4}-\d\d-\d\d\z/;
    my $uid = $r->{user} ? $self->_user_id( $r->{user} ) : ref $l->{$sp_f} ? $l->{$sp_f}[0] : undef;
    if ( !$uid ) { $plan->add( bucket => 'no-assignee', action => 'hold', key => $key, reason => 'no salesperson and no user given' ); return }

    # the brief goes to the lead body, once
    if ( my $b = $r->{brief} ) {
        my $old   = $l->{$notes_f};
        my $old_s = defined $old && !ref $old ? $old : '';
        if ( index( _plain($old_s), _plain($b) ) < 0 ) {
            $plan->add( bucket => 'brief', action => 'write', model => $self->profile->model_name('lead'), id => $l->{id}, support => 1,
                key => "$key brief", vals => { $notes_f => $old_s . $b }, before => { $notes_f => $old },
                context => { mail_auto_subscribe_no_notify => 1 } );
        }
    }
    if ( grep { lc( $_->{summary} // '' ) eq lc $r->{summary} } @$open ) {
        $plan->add( bucket => 'unchanged', action => 'skip', id => $r->{id}, key => $key, reason => 'same open activity exists' );
        return;
    }
    my %type = $r->{type}
        ? ( act_type_xmlid => '', activity_type_id => $self->_type_id( $r->{type} ) )
        : ( act_type_xmlid => 'mail.mail_activity_data_todo' );
    my ( $via, $automated ) = $self->_route;
    $plan->add(
        bucket => 'schedule', action => 'call', model => $self->profile->model_name('lead'), id => $r->{id}, ids => [ 0 + $r->{id} ],
        method => $via, key => $key,
        # read back after the call: the activity Odoo returns must
        # sit on this lead, for this user, on this date
        verify => {
            model  => 'mail.activity',
            fields => {
                res_id        => 0 + $r->{id},
                user_id       => 0 + $uid,
                date_deadline => $r->{due},
                summary       => $r->{summary},
                ( $r->{type} ? ( activity_type_id => $type{activity_type_id} ) : () ),
            },
        },
        kwargs => {
            %type,
            date_deadline  => $r->{due},
            summary        => $r->{summary},
            note           => $r->{note} // '',
            user_id        => 0 + $uid,
            # Not "automated" (the lead's schedule_todo route says so): up
            # to Odoo 16 Odoo then checks the assignee can read the lead
            # and refuses otherwise, rather than leaving someone a to-do
            # they cannot open or mark done.
            automated      => $automated,
            context        => { mail_activity_quick_update => JSON::PP::true },
        },
        before => { $sp_f => $l->{$sp_f}, $tags_f => $l->{$tags_f} },
    );
}

# How a to-do is scheduled is the lead's behaviour (route schedule_todo):
# the method and whether the activity is flagged automated. A lead
# behaviour with no such route gets today's literal.
sub _route ($self) {
    my $lead  = $self->profile->model_name('lead');
    my $route = $self->ctx->behaviour($lead)->route('schedule_todo');
    my $via   = $route ? ( $route->{via} // 'activity_schedule' ) : 'activity_schedule';
    Odoo::Error->throw( kind => 'config',
        message => "behaviour route schedule_todo of $lead names '$via'; crm.activity can only schedule through activity_schedule" )
        if $via ne 'activity_schedule';
    my $auto = $route && ref $route->{args} eq 'HASH' && exists $route->{args}{automated} ? $route->{args}{automated} : 0;
    return ( $via, $auto ? JSON::PP::true : JSON::PP::false );
}

sub _same_value ($a, $b) {
    $b = $b->[0] if ref $b eq 'ARRAY' && @$b == 2;    # many2one read as [id, name]
    return 1 if !defined $a && ( !defined $b || $b eq '' );
    return 0 if !defined $a || !defined $b;
    return "$a" eq "$b";
}

sub _plain ($v) {
    return '' if !defined $v || ref $v;
    my $t = $v =~ s/<[^>]*>/ /gr;
    $t =~ s/&nbsp;/ /g;
    $t =~ s/\s+/ /g;
    return $t =~ s/^ | \z//gr;
}

sub _read_file ($self, $path) {
    open my $fh, '<:raw', $path or Odoo::Error->throw( kind => 'usage', message => "cannot read $path: $!", fix => 'check the path exists and this user can read it' );
    my @rows;
    while ( my $line = <$fh> ) {
        next if $line !~ /\S/;
        my $r = eval { Odoo::Ops::json()->decode($line) }
            // Odoo::Error->throw( kind => 'usage', message => "$path line $.: not JSON", fix => 'correct the file; oom-ops describe <op> shows what it holds' );
        Odoo::Error->throw( kind => 'usage', message => "$path line $.: needs a numeric id", fix => 'correct the file; oom-ops describe <op> shows what it holds' ) if ( $r->{id} // '' ) !~ /^\d+\z/;
        push @rows, $r;
    }
    close $fh;
    return @rows;
}

sub _type_id ($self, $name) {
    my $t = $self->model('mail.activity.type')->search_read( [ [ 'name', '=ilike', $name ] ], [qw(res_model)] );
    Odoo::Error->throw( kind => 'usage', message => "activity type '$name' matches " . scalar(@$t)
            . ' (activity types are created in Odoo Settings by an administrator)' ) if @$t != 1;
    my $m = $t->[0]{res_model};
    Odoo::Error->throw( kind => 'usage', message => "activity type '$name' is for $m, not leads" )
        if $m && $m ne $self->profile->model_name('lead');
    return $t->[0]{id};
}

sub _user_id ($self, $name) {
    my $u = $self->model('res.users')->search_read( [ '|', [ 'login', '=ilike', $name ], [ 'name', '=ilike', $name ] ], ['id'] );
    Odoo::Error->throw( kind => 'usage', message => "user '$name' matches " . scalar(@$u) ) if @$u != 1;
    return $u->[0]{id};
}

1;
