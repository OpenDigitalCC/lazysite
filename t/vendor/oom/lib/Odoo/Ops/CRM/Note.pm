package Odoo::Ops::CRM::Note;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::CRM::Note - log reviewed internal notes on leads' chatter

=head1 DESCRIPTION

C<crm.note>: C<file> is JSON lines, one note per lead:

    {"id": 89, "title": "Follow-up outline", "body": "<p>...</p>"}

Each becomes an internal note (subtype "Note") in the lead's chatter,
authored by the configured user, notifying no one. The note is written
as a C<mail.message> directly: C<message_post> refuses a note from a
user without an email address, and the internal log path is not
reachable over RPC. The body is prefixed with the C<title> in bold; a
lead whose chatter already holds a note with that title is
C<unchanged>, so re-runs add nothing. Leads carrying C<block_tag>
(default "OCA - do not canvass") are held.

=cut

sub op_name ($class) { 'crm.note' }
sub summary ($class) { 'Log reviewed internal notes on lead chatter' }
sub pack    ($class) { 'crm' }
sub params ($class) {
    {   file      => { type => 'path', required => 1, help => 'JSON lines: {id, title, body}' },
        block_tag => { type => 'str', default => 'OCA - do not canvass', help => 'leads with this tag are held' },
    };
}
sub read_scope ($class) {
    {   lead                   => [qw(search_read read)],
        tag                    => ['search_read'],
        'mail.message'         => ['search_read'],
        'mail.message.subtype' => ['search_read'],
    };
}
sub write_scope ($class) { { 'mail.message' => ['create'], lead => ['message_post'] } }

# How a note is logged is the lead's behaviour (route log_note); a
# behaviour with no such route gets today's literal, the direct create.
sub _via ($self, $model) {
    my $route = $self->ctx->behaviour($model)->route('log_note');
    my $via   = $route ? ( $route->{via} // 'mail.message.create' ) : 'mail.message.create';
    Odoo::Error->throw( kind => 'config',
        message => "behaviour route log_note of $model names '$via'; crm.note can log through mail.message.create or message_post" )
        if $via ne 'mail.message.create' && $via ne 'message_post';
    return $via;
}

sub plan ($self) {
    my $p     = $self->profile;
    my @rows  = $self->_read_file( $self->param('file') );
    my $model = $p->model_name('lead');
    my $via   = $self->_via($model);
    my $tags_f = $p->field( lead => 'tags' );
    my %lead = map { $_->{id} => $_ } @{ $self->model('lead')->read( [ map { 0 + $_->{id} } @rows ], [$tags_f] ) };
    my $nf = $p->field( tag => 'name' );
    my ($block) = map { $_->{id} } @{ $self->model('tag')->search_read( [ [ $nf, '=ilike', $self->param('block_tag') ] ], [$nf] ) };
    my $note;
    if ( $via eq 'mail.message.create' ) {
        ($note) = @{ $self->model('mail.message.subtype')->search_read(
            [ [ 'name', '=', 'Note' ], [ 'internal', '=', JSON::PP::true ] ], ['id'] ) };
        Odoo::Error->throw( kind => 'config', message => 'no internal "Note" message subtype found' ) if !$note;
    }

    my $plan = $self->new_plan( input_count => scalar @rows );
    for my $r (@rows) {
        my $key = "lead:$r->{id}";
        Odoo::Error->throw( kind => 'usage', message => "lead $r->{id}: needs title and body" ) if !$r->{title} || !$r->{body};
        my $l = $lead{ $r->{id} };
        if ( !$l ) { $plan->add( bucket => 'lead-gone', action => 'hold', key => $key, reason => 'lead not readable' ); next }
        if ( $block && grep { $_ == $block } @{ $l->{$tags_f} // [] } ) {
            $plan->add( bucket => 'blocked', action => 'hold', key => $key, reason => 'tagged ' . $self->param('block_tag') );
            next;
        }
        my $dup = $self->model('mail.message')->search_read(
            [ [ 'model', '=', $model ], [ 'res_id', '=', 0 + $r->{id} ], [ 'body', 'ilike', $r->{title} ] ], ['id'], limit => 1 );
        if (@$dup) { $plan->add( bucket => 'unchanged', action => 'skip', id => $r->{id}, key => $key, reason => 'note already logged' ); next }
        my $body = '<p><strong>' . _esc( $r->{title} ) . '</strong></p>' . $r->{body};
        if ( $via eq 'message_post' ) {
            # the lead's own message_post as an internal note (subtype Note),
            # read back as a comment on this lead; Odoo returns the message id
            $plan->add(
                bucket => 'note', action => 'call', model => $model, id => 0 + $r->{id}, ids => [ 0 + $r->{id} ],
                method => 'message_post', key => $key,
                kwargs => { body => $body, message_type => 'comment', subtype_xmlid => 'mail.mt_note' },
                verify => { model => 'mail.message', fields => { model => $model, res_id => 0 + $r->{id}, message_type => 'comment' } },
            );
            next;
        }
        $plan->add(
            bucket => 'note', action => 'create', model => 'mail.message', key => $key,
            vals => {
                model        => $model,
                res_id       => 0 + $r->{id},
                message_type => 'comment',
                subtype_id   => $note->{id},
                is_internal  => JSON::PP::true,
                body         => $body,
            },
            readback => [qw(model res_id message_type)],
        );
    }
    return $plan;
}

sub _esc ($s) { $s =~ s/&/&amp;/gr =~ s/</&lt;/gr =~ s/>/&gt;/gr }

sub _read_file ($self, $path) {
    open my $fh, '<:raw', $path or Odoo::Error->throw( kind => 'config', message => "cannot read $path: $!" );
    my @rows;
    while ( my $line = <$fh> ) {
        next if $line !~ /\S/;
        my $r = eval { Odoo::Ops::json()->decode($line) }
            // Odoo::Error->throw( kind => 'config', message => "$path line $.: not JSON" );
        Odoo::Error->throw( kind => 'config', message => "$path line $.: needs a numeric id" ) if ( $r->{id} // '' ) !~ /^\d+\z/;
        push @rows, $r;
    }
    close $fh;
    return @rows;
}

1;
