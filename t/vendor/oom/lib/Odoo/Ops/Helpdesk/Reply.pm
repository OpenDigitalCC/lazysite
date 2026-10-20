package Odoo::Ops::Helpdesk::Reply;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;
use Odoo::Ops::Helpdesk::Common qw(ready id_of ticket_row reason_text html_body files_for post_change apply_post);

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Helpdesk::Reply - a message to the customer

=head1 SYNOPSIS

    oom-ops run helpdesk.reply --conf ops.conf --set ticket=HT00012 --set body="We have shipped a replacement"
    oom-ops run helpdesk.reply --conf ops.conf --set ticket=HT00012 --set body="See the guide" --file files=./guide.pdf

=head1 DESCRIPTION

C<helpdesk.reply>: a message on the ticket's conversation from the login the config runs as, posted through Odoo's
C<message_post> as a C<comment> with the C<mail.mt_comment> (Discussions) subtype, which Odoo mails to the
followers. The customer is not a follower of a ticket made through the API, so the ticket's partner is also named as
a recipient (C<partner_ids>) unless C<to_customer> is off; a ticket with no partner is replied to for its followers
only, and the plan says so. C<body> is plain text, put in a paragraph with its markup escaped, or HTML when
C<html> is on. C<files> (at most 10; C<--file files=PATH>) are put on the ticket and on the message. Apply reads the
message back and names it (C<made: mail.message N>).

A message cannot be unsent: the revert holds it C<irreversible>. For an internal note, with no mail, see
C<helpdesk.note>. Series 16 and 18.

=cut

sub op_name ($class) { 'helpdesk.reply' }
sub summary ($class) { 'Reply to the customer on a ticket (mailed), with optional files' }
sub pack    ($class) { 'helpdesk' }

sub buckets ($class) { return [ { name => 'reply', meaning => 'a message is posted to the ticket and mailed to its followers and the customer' } ] }
sub holds ($class) {
    return [
        { name => 'unknown-ticket', meaning => 'no ticket of that id or number that this login can read' },
        { name => 'invalid',        meaning => 'no body and no file' },
    ];
}

sub params ($class) {
    {   ticket      => { type => 'str',  required => 1, help => 'the ticket id or number (HT00012)' },
        body        => { type => 'str',  help => 'the message; plain text unless html is on' },
        html        => { type => 'bool', default => 0, help => 'body is already HTML' },
        to_customer => { type => 'bool', default => 1, help => 'name the ticket\'s partner as a recipient, so the customer is mailed' },
        files       => { type => 'files', max => 10, max_bytes => 25 * 1024 * 1024, help => 'files for the message: --file files=PATH (repeatable) on the command line' },
    };
}
sub read_scope ($class) { { ticket => [qw(search_read read)], message => ['read'] } }
sub write_scope ($class) { { ticket => ['message_post'], attachment => [ 'create', 'unlink' ] } }

sub plan ($self) {
    my $p = ready($self);
    my $plan = $self->new_plan( input_count => 1 );
    my $spec = $self->param('ticket');
    my $key = "ticket:$spec";
    my $hold = sub ( $bucket, $why ) { $plan->add( bucket => $bucket, action => 'hold', key => $key, reason => $why ); return $plan };
    my @files = files_for( $self, $plan, $self->param('files') );
    my $body = $self->param('body');
    return $hold->( 'invalid', 'a reply needs a body or a file' ) if ( !defined $body || $body !~ /\S/ ) && !@files;
    my ( $t, $why ) = ticket_row( $self, $spec, qw(partner) );
    return $hold->( 'unknown-ticket', reason_text( $why, 'ticket', $spec ) ) if !$t;
    my $partner = id_of( $t->{f}{partner} );
    my @partners = $self->param('to_customer') && $partner ? ($partner) : ();
    $plan->note("ticket $t->{id} has no partner: the reply is mailed to its followers only") if $self->param('to_customer') && !$partner;
    post_change( $self, $plan, { ticket => $t->{id}, key => $key, kind => 'reply', bucket => 'reply', handler => $self->op_name,
        body => ( defined $body && $body =~ /\S/ ? html_body( $body, $self->param('html') ) : '' ), partners => \@partners, files => \@files } );
    return $plan;
}

sub apply_custom ($class, $client, $change) { return apply_post( $class, $client, $change ) }

1;
