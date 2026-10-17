package Odoo::Ops::Mailing::Create;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Encode ();
use JSON::PP ();

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Mailing::Common;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Mailing::Create - make a mailshot as a draft, or change a draft

=head1 SYNOPSIS

    oom-ops run mailing.create --conf ops.conf --set subject="October news" \
        --set lists=Newsletter --set body_file=docs/examples/mailing/newsletter.html
    oom-ops run mailing.create --conf ops.conf --set mailing=7 --set subject="October news, corrected"

=head1 DESCRIPTION

C<mailing.create> plans one draft C<mailing.mailing> to the lists in
C<lists> (names or ids, comma-separated; at least one) with the body
from C<body_file> (a path to HTML) or C<body> (a string) - exactly one
of the two. Nothing is sent: a draft is sent by C<mailing.send>, after
C<mailing.test>.

Optional: C<from> (C<email_from>; absent leaves Odoo's default, which
is the creating user's formatted email, so that user must have one),
C<reply_to>, and C<schedule> (a UTC datetime, C<YYYY-MM-DD HH:MM:SS>,
which makes the mailing a scheduled one; it still waits for
C<mailing.send>). The body is kept both as Odoo sends it (C<body_html>)
and as its editor keeps it (C<body_arch>).

One row, one bucket:

    mailing-create    the draft is made; the plan note counts who would receive it now
    mailing-update    C<mailing=ID>: that draft changes, with before-images
    unchanged         C<mailing=ID>: nothing differs
    unknown-list      held: a list does not exist (named)
    exists            held: a draft with this subject and these lists is there already
                      (its id is in the reason; pass mailing=ID to change it instead)
    no-unsubscribe-link  held: the body has no anchor whose href is /unsubscribe_from_list,
                      the path Odoo rewrites to the recipient's own link at send time;
                      allow_no_unsubscribe=1 lets it through and the plan says so

The plan notes that the unsubscribe anchor is rewritten in the HTML part
only: Odoo derives the plain-text part from the HTML at send time and the
raw C</unsubscribe_from_list> URL stays in it (16.0, proved by the
try-out of 2026-10-15). It is a note and not a hold, because nothing the
author can do in the body changes it.

A mailing that is not a draft refuses by name (C<not-draft>). The read
back after apply includes C<total>, Odoo's count of the lists' contacts
in the lists; it counts opted-out and blacklisted ones, so the number
that will receive it is the plan's note (distinct addresses,
subscribed to some list, not blacklisted). Odoo's
C<expected> is 0 until a send makes traces.

Series: written for Odoo 16; another series is refused by name until its
profile is probed.

=cut

sub op_name ($class) { 'mailing.create' }
sub summary ($class) { 'Plan a mailshot as a draft to mailing lists, or change a draft (nothing is sent)' }
sub pack    ($class) { 'mailing' }
# What a plan of this operation sorts rows into (oom-ops describe prints them;
# t/99-declared-buckets.t checks them against what the tests plan).
sub buckets ($class) {
    return [
        { name => 'mailing-create', meaning => 'a draft mailing is made; the plan note counts who would receive it now' },
        { name => 'mailing-update', meaning => 'mailing=ID: that draft is changed, with before-images' },
        { name => 'unchanged', meaning => 'mailing=ID: nothing differs' },
    ];
}
sub holds ($class) {
    return [
        { name => 'unknown-list', meaning => 'a list does not exist' },
        { name => 'exists', meaning => 'a draft with this subject and these lists is there already; pass mailing=ID to change it' },
        { name => 'no-unsubscribe-link', meaning => 'the body has no anchor to /unsubscribe_from_list, the path Odoo rewrites for each recipient (allow_no_unsubscribe=1 lets it through)' },
    ];
}

sub params ($class) {
    {   subject  => { type => 'str',  help => 'the subject (required to create)' },
        lists    => { type => 'list', help => 'the lists, names or ids, comma-separated' },
        body_file => { type => 'path', help => 'a file of HTML, with an /unsubscribe_from_list anchor' },
        body     => { type => 'str',  help => 'the HTML as a string (instead of body_file)' },
        from     => { type => 'str',  help => 'email_from; absent leaves Odoo\'s default' },
        reply_to => { type => 'str',  help => 'reply-to address' },
        schedule => { type => 'str',  help => 'UTC datetime to send, YYYY-MM-DD HH:MM:SS' },
        mailing  => { type => 'int',  help => 'change this draft instead of making one' },
        allow_no_unsubscribe => { type => 'bool', default => 0, help => 'allow a body with no unsubscribe link' },
    };
}
sub read_scope ($class) {
    {   mailing      => [qw(search_read read)],
        list         => ['search_read'],
        subscription => ['search_read'],
        contact      => ['search_read'],
        'ir.model'   => ['search_read'],
    };
}
sub write_scope ($class) { { mailing => [qw(create write read)] } }

sub scope_for ($self, $phase) { Odoo::Ops::Mailing::Common::scope( $self, $phase, $self->SUPER::scope_for($phase) ) }

sub plan ($self) {
    my $p = Odoo::Ops::Mailing::Common::ready($self);
    my $f = sub ($lf) { $p->field( mailing => $lf ) };
    my $upd = $self->param('mailing');

    my $body = $self->_body;
    my $plan = $self->new_plan( input_count => 1 );
    my $key  = defined $upd ? "mailing:$upd" : 'mailing:' . ( $self->param('subject') // '' );
    my $hold = sub ($bucket, $reason) { $plan->add( bucket => $bucket, action => 'hold', key => $key, reason => $reason ); return $plan };

    if ( !defined $upd ) {
        Odoo::Error->throw( kind => 'usage', message => 'mailing.create: parameter subject is required' )
            if !defined $self->param('subject') || $self->param('subject') !~ /\S/;
        Odoo::Error->throw( kind => 'usage', message => 'mailing.create: give a body (body_file or body)' ) if !defined $body;
        Odoo::Error->throw( kind => 'usage', message => 'mailing.create: give at least one list (lists)' ) if !@{ $self->param('lists') // [] };
    }
    my $current;
    if ( defined $upd ) {
        $current = $self->model('mailing')->read( [$upd], [ map { $f->($_) } qw(subject state lists body_html body_arch email_from reply_to schedule_date schedule_type) ] )->[0]
            or Odoo::Error->throw( kind => 'refused', code => 'unknown-mailing', message => "mailing.create: no mailing $upd",
            fix => q(oom-ops run mailing.status --conf <conf> lists the mailings) );
        Odoo::Error->throw( kind => 'refused', code => 'not-draft',
            message => "mailing $upd is $current->{ $f->('state') }, not draft: only a draft can be changed" )
            if $current->{ $f->('state') } ne 'draft';
    }

    # lists: every name or id must exist (archived ones are not offered to a mailing)
    my ( @ids, @unknown );
    for my $ref ( @{ $self->param('lists') // [] } ) {
        my $found = Odoo::Ops::Mailing::Common::lists_by( $self, $ref );
        if    ( !@$found )    { push @unknown, $ref }
        elsif ( @$found > 1 ) { push @unknown, "$ref (names " . scalar(@$found) . ' lists; give the id)' }
        else                  { push @ids, $found->[0]{id} }
    }
    return $hold->( 'unknown-list', 'no list ' . join( ', ', map { "'$_'" } @unknown ) . ' (mailing.lists shows them)' ) if @unknown;

    my @problems;
    my $href = $p->action('unsubscribe_href');
    if ( defined $body && !Odoo::Ops::Mailing::Common::has_unsubscribe( $body, $href ) ) {
        if ( $self->param('allow_no_unsubscribe') ) {
            $plan->note("the body has no unsubscribe link ($href); allowed by allow_no_unsubscribe: recipients will have no way to opt out");
        }
        else {
            push @problems, [ 'no-unsubscribe-link',
                "the body has no anchor whose href is $href, so recipients would have no way to opt out; add one (docs/examples/mailing/newsletter.html), or allow_no_unsubscribe=1" ];
        }
    }
    if ( !defined $upd && @ids ) {
        my %want = map { $_ => 1 } @ids;
        my $drafts = $self->model('mailing')->all( [ [ $f->('state'), '=', 'draft' ], [ $f->('subject'), '=', $self->param('subject') ] ],
            [ $f->('subject'), $f->('lists') ] );
        for my $d (@$drafts) {
            my %have = map { $_ => 1 } @{ $d->{ $f->('lists') } // [] };
            next if keys %have != keys %want || grep { !$have{$_} } keys %want;
            unshift @problems, [ 'exists', "a draft with this subject and these lists exists: mailing $d->{id}; pass mailing=$d->{id} to change it" ];
            last;
        }
    }
    if (@problems) {
        return $hold->( $problems[0][0], join( '; ', map { $_->[1] } @problems ) );
    }

    # A repeat after a send makes a new draft under the same subject; the reviewer
    # sees the earlier mailing before approving, not after (second try-out, item 3).
    my @sent_before = !defined $upd && @ids ? $self->_sent_before( \@ids ) : ();

    my $aud = @ids ? Odoo::Ops::Mailing::Common::audience( $self, \@ids ) : undef;
    my $note = sub () {
        return () if !$aud;
        return sprintf 'audience now: %d reachable address(es) of %d subscription(s); %d opted out, %d blacklisted, %d without an address', @$aud{qw(reachable subscriptions opted_out blacklisted no_email)};
    };

    # proved on 16 by the try-out of 2026-10-15: nothing the author can do in the body, so a note and not a hold
    my $text_part = sub () {
        return "the unsubscribe anchor is rewritten to the recipient's own link in the HTML part only; Odoo derives the plain-text part from the HTML at send time and its $href link stays as written (a text-only reader gets a link that does not unsubscribe)";
    };

    if ( defined $upd ) {
        my ( %set, %before );
        my $same = sub ($old, $new) { Odoo::Ops::Mailing::Common::text($old) eq $new };
        my $want = sub ($fld, $val) { if ( !$same->( $current->{$fld}, $val ) ) { $set{$fld} = $val; $before{$fld} = $current->{$fld} } };
        $want->( $f->('subject'), $self->param('subject') ) if defined $self->param('subject');
        if ( defined $body ) { $want->( $f->('body_html'), $body ); $want->( $f->('body_arch'), $body ) }
        $want->( $f->('email_from'), $self->param('from') ) if defined $self->param('from');
        $want->( $f->('reply_to'), $self->param('reply_to') ) if defined $self->param('reply_to');
        if ( defined $self->param('schedule') ) {
            my $when = Odoo::Ops::Mailing::Common::datetime( 'mailing.create', 'schedule', $self->param('schedule') );
            $want->( $f->('schedule_date'), $when );
            if ( ( $current->{ $f->('schedule_type') } // '' ) ne 'scheduled' ) { $set{ $f->('schedule_type') } = 'scheduled'; $before{ $f->('schedule_type') } = $current->{ $f->('schedule_type') } }
        }
        if (@ids) {
            my %have = map { $_ => 1 } @{ $current->{ $f->('lists') } // [] };
            if ( keys %have != @ids || grep { !$have{$_} } @ids ) {
                $set{ $f->('lists') } = [ [ 6, 0, \@ids ] ];
                $before{ $f->('lists') } = $current->{ $f->('lists') };
            }
        }
        if ( !%set ) {
            $plan->add( bucket => 'unchanged', action => 'skip', key => $key, id => $upd, reason => "mailing $upd already reads as asked" );
            return $plan;
        }
        $plan->note( $note->() ) if @ids;
        $plan->note( $text_part->() ) if defined $body;
        $plan->add( bucket => 'mailing-update', action => 'write', model => $p->model_name('mailing'), id => $upd, key => $key,
            vals => \%set, before => \%before, reason => 'changes ' . join( ', ', sort keys %set ) );
        return $plan;
    }

    my $ir = $self->client->model('ir.model')->search_read( [ [ 'model', '=', $p->model_name('list') ] ], ['id'], limit => 1 )->[0]
        or Odoo::Error->throw( kind => 'config', message => 'ir.model has no ' . $p->model_name('list') . ': mass_mailing is not installed' );
    my %vals = (
        $f->('subject')   => $self->param('subject'),
        $f->('body_html') => $body,
        $f->('body_arch') => $body,
        $f->('model')     => $ir->{id},
        $f->('lists')     => [ [ 6, 0, \@ids ] ],
        ( defined $self->param('from')     ? ( $f->('email_from') => $self->param('from') )         : () ),
        ( defined $self->param('reply_to') ? ( $f->('reply_to')   => $self->param('reply_to') )     : () ),
    );
    if ( defined $self->param('schedule') ) {
        $vals{ $f->('schedule_type') } = 'scheduled';
        $vals{ $f->('schedule_date') } = Odoo::Ops::Mailing::Common::datetime( 'mailing.create', 'schedule', $self->param('schedule') );
    }
    $plan->note( $note->() );
    $plan->note( $text_part->() );
    $plan->note($_) for @sent_before;
    $plan->note('a draft: nothing is sent until mailing.send; test it first with mailing.test');
    $plan->add( bucket => 'mailing-create', action => 'create', model => $p->model_name('mailing'), key => $key, vals => \%vals,
        readback => [ map { $f->($_) } qw(subject state total email_from reply_to lists model) ],
        reason => 'a draft mailing to ' . scalar(@ids) . ' list(s)' );
    return $plan;
}

# Mailings in any state but draft that carry this subject and exactly these
# lists, newest first (archived ones too: a cleaned-up send is still a send).
sub _sent_before ($self, $ids) {
    my $f = sub ($lf) { $self->profile->field( mailing => $lf ) };
    my %want = map { $_ => 1 } @$ids;
    my $rows = $self->model('mailing')->search_read(
        [ [ $f->('state'), '!=', 'draft' ], [ $f->('subject'), '=', $self->param('subject') ],
          [ $f->('active'), 'in', [ JSON::PP::true, JSON::PP::false ] ] ],
        [ map { $f->($_) } qw(subject state lists sent_date updated) ], order => 'id desc', limit => 20 );
    my @note;
    for my $m (@$rows) {
        my %have = map { $_ => 1 } @{ $m->{ $f->('lists') } // [] };
        next if keys %have != keys %want || grep { !$have{$_} } keys %want;
        my $when = Odoo::Ops::Mailing::Common::text( $m->{ $f->('sent_date') } ) || Odoo::Ops::Mailing::Common::text( $m->{ $f->('updated') } );
        $when = substr( $when, 0, 16 ) if length $when > 16;
        push @note, "sent before: mailing $m->{id} ($m->{ $f->('state') }" . ( length $when ? ", $when" : '' ) . ') has this subject and these lists; this plan makes a new draft';
        last if @note >= 3;
    }
    return @note;
}

sub _body ($self) {
    my ( $file, $text ) = ( $self->param('body_file'), $self->param('body') );
    Odoo::Error->throw( kind => 'usage', message => 'mailing.create: give body_file or body, not both' ) if defined $file && defined $text;
    return $text if defined $text;
    return undef if !defined $file;
    open my $fh, '<:raw', $file or Odoo::Error->throw( kind => 'usage', message => "mailing.create: cannot read $file: $!", fix => 'check the path exists and this user can read it' );
    my $raw = do { local $/; <$fh> };
    close $fh;
    my $html = eval { Encode::decode( 'UTF-8', $raw, Encode::FB_CROAK ) }
        // Odoo::Error->throw( kind => 'usage', message => "mailing.create: $file is not valid UTF-8", fix => 'correct the file; oom-ops describe <op> shows what it holds' );
    Odoo::Error->throw( kind => 'usage', message => "mailing.create: $file is empty" ) if $html !~ /\S/;
    return $html;
}

1;
