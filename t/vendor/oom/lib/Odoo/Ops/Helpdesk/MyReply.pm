package Odoo::Ops::Helpdesk::MyReply;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;
use Odoo::Ops::Helpdesk::Common qw(ready id_of ticket_row reason_text html_body files_for post_change apply_post);

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Helpdesk::MyReply - a customer's public message on a ticket

=head1 SYNOPSIS

    oom-ops run helpdesk.my_reply --conf customer.conf --set ticket=HT00012 --set body="It still jams" --file files=./photo.jpg

=head1 DESCRIPTION

C<helpdesk.my_reply>: a public message on a ticket the customer may see, posted as the customer. Whether the
ticket may be seen is Odoo's answer to the customer's own read of it (a ticket the login cannot read is held
C<unknown-ticket>, saying nothing of whether it exists). The message itself is made by the service login named in
the config (C<act_as_conf>) with the customer's partner as its author, as Odoo's own portal chatter does: on 16
a portal login's own C<message_post> is refused (C<Access Denied>), on 18 it works but a portal login cannot attach
a file on either series, so one path serves both. The message is a comment with the C<mail.mt_comment> subtype,
never a note; Odoo mails the ticket's followers. C<body> is plain text, or HTML when C<html> is on; C<files> (at
most 10) go on the ticket and the message. Only the person who planned may apply the plan. A message cannot be
unsent: the revert holds it C<irreversible>. Series 16 and 18.

=cut

sub op_name ($class) { 'helpdesk.my_reply' }
sub summary ($class) { 'A customer\'s public message on a ticket they can see, with files (never a note)' }
sub pack    ($class) { 'helpdesk' }
sub acts_for ($class) { 1 }

sub buckets ($class) { return [ { name => 'reply', meaning => 'a public message is posted to the ticket with the customer as its author' } ] }
sub holds ($class) {
    return [
        { name => 'unknown-ticket', meaning => 'the customer\'s login can read no ticket of that id or number' },
        { name => 'invalid',        meaning => 'no body and no file' },
    ];
}

sub params ($class) {
    {   ticket => { type => 'str',  required => 1, help => 'the ticket id or number (HT00012)' },
        body   => { type => 'str',  help => 'the message; plain text unless html is on' },
        html   => { type => 'bool', default => 0, help => 'body is already HTML' },
        files  => { type => 'files', max => 10, max_bytes => 25 * 1024 * 1024, help => 'files: --file files=PATH (repeatable) on the command line' },
    };
}
sub read_scope ($class) { { ticket => [qw(search_read read)], message => ['read'] } }
sub write_scope ($class) { { ticket => ['message_post'], attachment => [ 'create', 'unlink' ] } }

sub plan ($self) {
    ready($self);
    my $plan = $self->new_plan( input_count => 1 );
    my $me = $self->person;
    my $spec = $self->param('ticket');
    my $key = "ticket:$spec";
    my $hold = sub ( $bucket, $why ) { $plan->add( bucket => $bucket, action => 'hold', key => $key, reason => $why ); return $plan };
    my @files = files_for( $self, $plan, $self->param('files') );
    my $body = $self->param('body');
    return $hold->( 'invalid', 'a message needs a body or a file' ) if ( !defined $body || $body !~ /\S/ ) && !@files;
    my ( $t, $why ) = ticket_row( $self, $spec, qw(title) );
    return $hold->( 'unknown-ticket', "no ticket '$spec' that this login can read" ) if !$t;
    post_change( $self, $plan, { ticket => $t->{id}, key => $key, kind => 'reply', bucket => 'reply', handler => $self->op_name, author => $me->{partner_id},
        body => ( defined $body && $body =~ /\S/ ? html_body( $body, $self->param('html') ) : '' ), partners => [], files => \@files } );
    return $plan;
}

sub apply_custom ($class, $client, $change) { return apply_post( $class, $client, $change ) }

1;
