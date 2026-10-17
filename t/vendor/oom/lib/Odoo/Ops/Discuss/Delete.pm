package Odoo::Ops::Discuss::Delete;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops;
use Odoo::Ops::Discuss::Common;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Discuss::Delete - delete a channel message the way Odoo's client does

=head1 SYNOPSIS

    oom-ops run discuss.delete --conf ops.conf --set message=120

=head1 DESCRIPTION

C<discuss.delete>: removes what a channel message says. Odoo 16's own client does
not unlink the record: it empties the body and removes the attachments, at the
web route C</mail/message/update_content> (the method behind it,
C<_message_update_content>, is private, so apply runs over a web session as the
login; see L<Odoo::Ops::Discuss::Common>). The message record stays on the
channel, with its author, date and parent; its body reads empty and its
attachments are deleted for good. Apply reads the message back and says that in
Odoo's terms: C<body and attachments removed; the message record stays>.

Odoo's own rule decides who may: the route answers 404 Not Found unless the
login wrote the message or is an administrator (Access Rights). A plain RPC
C<unlink> or C<write> of a channel message is allowed by Odoo to any internal
user who can reach the channel, so it is not the path used here. Odoo also
refuses a message that is not a C<comment> (a join or a leave notification),
in its words. The plan names the message's author and type and leaves the
decision to Odoo.

    delete             the body and attachments are removed
    already-empty      the message has no body and no attachment - skipped
    unknown-message    this login can read no message with that id - held
    not-a-channel-message  the message is on a record's chatter, not on a channel - held

It is irreversible: a revert holds it, saying the body and attachments are gone.
The revert of C<discuss.post> uses this operation. Series: written for Odoo 16;
another series is refused by name.

=cut

sub op_name ($class) { 'discuss.delete' }
sub summary ($class) { 'Delete a Discuss channel message (empties it, as Odoo\'s client does)' }
sub pack    ($class) { 'discuss' }
sub buckets ($class) {
    return [
        { name => 'delete', meaning => 'the message\'s body and attachments are removed over Odoo\'s own web route; the record stays' },
        { name => 'already-empty', meaning => 'the message has no body and no attachment' },
    ];
}
sub holds ($class) {
    return [
        { name => 'unknown-message', meaning => 'this login can read no message with that id' },
        { name => 'not-a-channel-message', meaning => 'the message is on a record\'s chatter, not on a channel' },
    ];
}

sub params ($class) {
    { message => { type => 'int', required => 1, help => 'the message id (discuss.messages prints it)' } };
}
sub read_scope ($class) {
    { channel => ['search_read'], message => ['search_read'], attachment => ['search_read'] };
}
# The write is a web route, not an RPC call, so there is no method to name for it:
# the scope holds the read-back of the message, which makes this a write operation.
sub write_scope ($class) { { message => ['read'] } }

sub plan ($self) {
    my $p = Odoo::Ops::Discuss::Common::ready($self);
    my $f = sub ( $lm, $lf ) { $p->field( $lm => $lf ) };
    my $plan = $self->new_plan( input_count => 1 );
    my $mid  = $self->param('message');
    my $key  = "message:$mid";
    my $hold = sub ( $bucket, $why ) { $plan->add( bucket => $bucket, action => 'hold', key => $key, reason => $why ); return $plan };

    my $m = Odoo::Ops::Discuss::Common::message_row( $self, $mid )
        or return $hold->( 'unknown-message', "message $mid is not readable by this login" );
    return $hold->( 'not-a-channel-message', "message $mid is not on a channel; Discuss messages are channel messages" )
        if !defined $m->{channel};
    my @att = @{ $m->{attachments} };
    my $empty = !( defined $m->{body} && length $m->{body} ) && !@att;
    if ($empty) {
        $plan->add( bucket => 'already-empty', action => 'skip', key => $key, id => $mid + 0, reason => "message $mid has no body and no attachment" );
        return $plan;
    }
    my $names = '';
    if (@att) {
        my $rows = $self->model('attachment')->search_read( [ [ 'id', 'in', \@att ] ], [ $f->( attachment => 'name' ) ] );
        $names = join ', ', map { $_->{ $f->( attachment => 'name' ) } } @$rows;
    }
    my $ch = Odoo::Ops::Discuss::Common::channel_row( $self, $m->{channel} );
    $plan->add(
        bucket => 'delete', action => 'custom', handler => $self->op_name, kind => 'delete',
        model  => $p->model_name('message'), id => $mid + 0, key => $key,
        before => { $f->( message => 'body' ) => $m->{body}, $f->( message => 'attachments' ) => \@att },
        vals   => { message => $mid + 0, channel => $m->{channel} + 0 },
        line   => "empty message $mid of channel $m->{channel}" . ( $ch ? " ($ch->{name})" : '' )
            . ( length $m->{author_name} ? ", written by $m->{author_name}" : '' ) . ", type $m->{type}: "
            . 'body' . ( @att ? ' and ' . scalar(@att) . ' attachment' . ( @att == 1 ? '' : 's' ) . " ($names)" : '' )
            . ' removed for good; the message record stays',
        reason => 'Odoo removes the body and the attachments and keeps the message; Odoo decides whether this login may',
    );
    return $plan;
}

=head2 apply_custom($class, $client, $change)

Called by the runner: the web route as the login, then the message read back.
The read-back holds when the body is empty, no attachment is left and the
message is still on its channel.

=cut

sub apply_custom ($class, $client, $c) {
    Odoo::Error->throw( kind => 'usage', message => "discuss.delete cannot apply kind '" . ( $c->{kind} // '' ) . "'" ) if ( $c->{kind} // '' ) ne 'delete';
    my $p = Odoo::Ops::Discuss::Common::profile_for( $client, 'discuss.delete' );
    my $f = sub ($lf) { $p->field( message => $lf ) };
    my $v = $c->{vals};
    Odoo::Ops::Discuss::Common::web_call( $client, $p->action('empty_route'), { message_id => $v->{message}, body => '', attachment_ids => [] } );
    my $left = $client->model( $p->model_name('message') )->read_one( $v->{message}, [ map { $f->($_) } qw(model res_id body attachments) ] );
    Odoo::Error->throw( kind => 'fault', message => "message $v->{message} is gone after the route answered; Odoo was expected to keep the record" ) if !$left;
    my %after = (
        id => $v->{message}, channel => $left->{ $f->('res_id') },
        $f->('body') => $left->{ $f->('body') } // '', $f->('attachments') => [ @{ $left->{ $f->('attachments') } // [] } ],
    );
    my $ok = !( defined $left->{ $f->('body') } && length $left->{ $f->('body') } ) && !@{ $after{ $f->('attachments') } }
        && ( $left->{ $f->('res_id') } // 0 ) == $v->{channel};
    return {
        reported => 'write',
        returned => {
            method => 'update_content',
            says   => "message $v->{message} of channel $v->{channel}: body and attachments removed; the message record stays",
            left   => { body => '', attachments => 0, record => JSON::PP::true },
        },
        after => $ok ? \%after : undef,
    };
}

=head2 undo_custom($class, $entry)

None: the revert holds the row. Odoo removes the body and deletes the
attachments for good, so there is nothing to put back.

=cut

sub undo_custom ($class, $e) {
    my $mid = ref $e->{vals} eq 'HASH' ? $e->{vals}{message} : undef;
    return ( undef, 'message' . ( defined $mid ? " $mid" : '' ) . ": Odoo removed its body and deleted its attachments for good, so there is nothing to put back (the record stays, emptied)" );
}

1;
