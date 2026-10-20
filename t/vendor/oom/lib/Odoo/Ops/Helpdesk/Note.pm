package Odoo::Ops::Helpdesk::Note;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;
use Odoo::Ops::Helpdesk::Common qw(ready id_of ticket_row reason_text html_body files_for post_change apply_post);

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Helpdesk::Note - an internal note on a ticket

=head1 SYNOPSIS

    oom-ops run helpdesk.note --conf ops.conf --set ticket=HT00012 --set body="Called the customer, no answer"

=head1 DESCRIPTION

C<helpdesk.note>: a note on the ticket's conversation from the login the config runs as, posted through Odoo's
C<message_post> as a C<comment> with the C<mail.mt_note> subtype: Odoo mails no one, and a customer's login does
not see it. C<body> is plain text, put in a paragraph with its markup escaped, or HTML when C<html> is on.
C<files> (at most 10; C<--file files=PATH>) are put on the ticket and on the note. Apply reads the message back and
names it. A note cannot be taken back: the revert holds it C<irreversible>. A reply to the customer is
C<helpdesk.reply>. Odoo refuses a note from a user with no email address in its own words. Series 16 and 18.

=cut

sub op_name ($class) { 'helpdesk.note' }
sub summary ($class) { 'An internal note on a ticket (no mail), with optional files' }
sub pack    ($class) { 'helpdesk' }

sub buckets ($class) { return [ { name => 'note', meaning => 'an internal note is posted to the ticket; no one is mailed' } ] }
sub holds ($class) {
    return [
        { name => 'unknown-ticket', meaning => 'no ticket of that id or number that this login can read' },
        { name => 'invalid',        meaning => 'no body and no file' },
    ];
}

sub params ($class) {
    {   ticket => { type => 'str',  required => 1, help => 'the ticket id or number (HT00012)' },
        body   => { type => 'str',  help => 'the note; plain text unless html is on' },
        html   => { type => 'bool', default => 0, help => 'body is already HTML' },
        files  => { type => 'files', max => 10, max_bytes => 25 * 1024 * 1024, help => 'files for the note: --file files=PATH (repeatable) on the command line' },
    };
}
sub read_scope ($class) { { ticket => [qw(search_read read)], message => ['read'] } }
sub write_scope ($class) { { ticket => ['message_post'], attachment => [ 'create', 'unlink' ] } }

sub plan ($self) {
    ready($self);
    my $plan = $self->new_plan( input_count => 1 );
    my $spec = $self->param('ticket');
    my $key = "ticket:$spec";
    my $hold = sub ( $bucket, $why ) { $plan->add( bucket => $bucket, action => 'hold', key => $key, reason => $why ); return $plan };
    my @files = files_for( $self, $plan, $self->param('files') );
    my $body = $self->param('body');
    return $hold->( 'invalid', 'a note needs a body or a file' ) if ( !defined $body || $body !~ /\S/ ) && !@files;
    my ( $t, $why ) = ticket_row( $self, $spec, qw(title) );
    return $hold->( 'unknown-ticket', reason_text( $why, 'ticket', $spec ) ) if !$t;
    post_change( $self, $plan, { ticket => $t->{id}, key => $key, kind => 'note', bucket => 'note', handler => $self->op_name,
        body => ( defined $body && $body =~ /\S/ ? html_body( $body, $self->param('html') ) : '' ), files => \@files } );
    return $plan;
}

sub apply_custom ($class, $client, $change) { return apply_post( $class, $client, $change ) }

1;
