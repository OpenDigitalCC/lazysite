package Odoo::Ops::Helpdesk::MyTicket;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Error;
use Odoo::Ops::Discuss::Common ();
use Odoo::Ops::Helpdesk::Common qw(ready id_of name_of flag text ticket_row fields_block fields_list reason_text);
use Odoo::Ops::Helpdesk::TicketList;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Helpdesk::MyTicket - one ticket with its public conversation, for the customer

=head1 SYNOPSIS

    oom-ops run helpdesk.my_ticket --conf customer.conf --set ticket=HT00012

=head1 DESCRIPTION

C<helpdesk.my_ticket>: run as the customer's own login, with a service login named in the config
(C<act_as_conf>) for one read only. The ticket and its messages are read as the customer, so Odoo's
record rules decide whether the ticket and each message may be seen: a ticket the login cannot read
is refused C<unknown-ticket>, saying nothing of whether it exists, and Odoo gives a portal login the
comments (the replies and the emails), not the internal notes. The row has the fields of
C<helpdesk.my_tickets> and C<description>, C<description_text>, C<messages> (oldest first: C<id>,
C<date>, C<author>, C<body_text>, C<body_html>, C<attachments>) and C<attachments> (the files on the
messages: C<< { id, name, size, mimetype } >>). A portal login may not read a file's record, only its id on
a message, so the service login reads the names of exactly the files the customer's own read of the
messages returned. Series 16 and 18.

=cut

sub op_name ($class) { 'helpdesk.my_ticket' }
sub summary ($class) { 'One ticket with its public conversation and file names (as the customer)' }
sub pack    ($class) { 'helpdesk' }
sub acts_for ($class) { 1 }

my @COLS = (
    @Odoo::Ops::Helpdesk::TicketList::COLS_CUSTOMER,
    [ description => 'html', 'The description (HTML)' ], [ description_text => 'text', 'The description as text' ],
    [ messages => 'json', 'The public conversation, oldest first' ], [ attachments => 'json', 'Files on the messages: [ { id, name, size, mimetype } ]' ],
);
sub fields ($class) { fields_list( \@COLS ) }

sub params ($class) { { ticket => { type => 'str', required => 1, help => 'the ticket id or number (HT00012)' } } }
sub read_scope ($class) { { ticket => [qw(search_read read)], message => ['search_read'], attachment => ['read'], partner => ['read'] } }

sub report ($self) {
    my $p = ready($self);
    my $f = sub ($lf) { $p->field( ticket => $lf ) };
    my $spec = $self->param('ticket');
    my @lf = ( Odoo::Ops::Helpdesk::TicketList::fields_to_read( $self, customer => 1 ), 'description' );
    my ( $t, $why ) = ticket_row( $self, $spec, @lf );
    Odoo::Error->throw( kind => 'refused', code => 'unknown-record', message => "No ticket '$spec' that this login can read",
        fix => 'oom-ops run helpdesk.my_tickets lists the tickets' ) if !$t;
    my $raw = { id => $t->{id}, map { $f->($_) => $t->{f}{$_} } keys %{ $t->{f} } };
    my ($row) = @{ Odoo::Ops::Helpdesk::TicketList::shape( $self, [$raw], customer => 1 ) };
    my $mf = sub ($lf) { $p->field( message => $lf ) };
    my $msgs = $self->model('message')->search_read(
        [ [ $mf->('model'), '=', $p->model_name('ticket') ], [ $mf->('res_id'), '=', $t->{id} ], [ $mf->('type'), 'in', [ 'comment', 'email' ] ] ],
        [ map { $mf->($_) } qw(author date body attachments) ], order => 'id' );
    my @aids = keys %{ { map { $_ => 1 } map { @{ $_->{ $mf->('attachments') } // [] } } @$msgs } };
    my $af = sub ($lf) { $p->field( attachment => $lf ) };
    my %att = @aids ? ( map { $_->{id} => $_ } @{ $self->service_client->model( $p->model_name('attachment') )->read( \@aids, [ map { $af->($_) } qw(name size mimetype) ] ) } ) : ();
    my @conv = map { +{
        id => $_->{id}, date => text( $_->{ $mf->('date') } ), author => name_of( $_->{ $mf->('author') } ) || undef,
        body_text => Odoo::Ops::Discuss::Common::html_text( $_->{ $mf->('body') } ), body_html => $_->{ $mf->('body') } // '',
        attachments => [ map { $att{$_} ? $att{$_}{ $af->('name') } : $_ } @{ $_->{ $mf->('attachments') } // [] } ],
    } } @$msgs;
    my $desc = $t->{f}{description} // '';
    return { count => 1, rows => [ { %$row, description => $desc, description_text => Odoo::Ops::Discuss::Common::html_text($desc), messages => \@conv,
        attachments => [ map { +{ id => $_, name => $att{$_}{ $af->('name') }, size => $att{$_}{ $af->('size') }, mimetype => text( $att{$_}{ $af->('mimetype') } ) } } grep { $att{$_} } sort { $a <=> $b } @aids ] } ],
        fields => fields_block( \@COLS ) };
}

1;
