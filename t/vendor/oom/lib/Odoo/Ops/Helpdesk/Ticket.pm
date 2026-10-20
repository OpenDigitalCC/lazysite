package Odoo::Ops::Helpdesk::Ticket;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops::Discuss::Common ();
use Odoo::Ops::Helpdesk::Common qw(ready id_of name_of flag text ticket_row fields_block fields_list reason_text);
use Odoo::Ops::Helpdesk::TicketList;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Helpdesk::Ticket - one ticket in full

=head1 SYNOPSIS

    oom-ops run helpdesk.ticket --conf ops.conf --set ticket=HT00012

=head1 DESCRIPTION

C<helpdesk.ticket>: the ticket named by C<ticket> (an id or a number such as C<HT00012>) as one
row: the fields of C<helpdesk.tickets> and C<description> (HTML) and C<description_text>,
C<company>, C<kanban_state>, C<unattended>, on 18 C<notes>; C<followers>
(C<< [ { id, name } ] >>); C<sla> (C<< { deadline, expired } >>, and on 18 C<rows>, one per rule:
C<name>, C<state>, C<deadline>, C<hours>, C<consumed>, C<expected_stage>); C<messages> (oldest first: C<id>, C<date>, C<author>,
C<author_id>, C<kind> C<reply> for a message to the customer, C<note> for an internal one,
C<email> or C<notification> for what Odoo recorded itself, C<subtype>, C<body_text>, C<body_html>,
C<attachments> as names); and C<attachments> (C<< [ { id, name, size, mimetype } ] >>, all the files
on the ticket). A ticket this login cannot read is refused C<unknown-ticket>, saying nothing of
whether it exists. Series 16 and 18.

=cut

sub op_name ($class) { 'helpdesk.ticket' }
sub summary ($class) { 'One ticket in full: fields, SLA, the conversation with its attachments, followers' }
sub pack    ($class) { 'helpdesk' }

my @COLS = (
    @Odoo::Ops::Helpdesk::TicketList::COLS_OPERATOR,
    [ description => 'html', 'The description (HTML)' ], [ description_text => 'text', 'The description as text' ],
    [ company => 'text', 'Company' ], [ kanban_state => 'text', 'Kanban state' ], [ unattended => 'boolean', 'The stage is an unattended one' ],
    [ notes => 'html', 'Internal notes (18)' ],
    [ followers => 'json', 'Followers: [ { id, name } ]' ],
    [ sla => 'json', 'SLA: { deadline, expired, rows } (rows on 18: name, state, deadline, hours, consumed, expected_stage)' ],
    [ messages => 'json', 'The conversation, oldest first' ], [ attachments => 'json', 'Files on the ticket: [ { id, name, size, mimetype } ]' ],
);
sub fields ($class) { fields_list( \@COLS ) }

sub params ($class) { { ticket => { type => 'str', required => 1, help => 'the ticket id or number (HT00012)' } } }
sub read_scope ($class) {
    {   ticket => [qw(search_read read)], message => ['search_read'], attachment => ['search_read'], partner => ['read'], tag => ['read'],
        'mail.message.subtype' => ['read'], 'helpdesk.ticket.sla' => ['search_read'], 'helpdesk.sla' => ['read'],
    };
}

# what kind of message a row is: the subtype says whether Odoo keeps it internal
sub _kind ( $type, $internal ) {
    return 'note' if $internal && $type eq 'comment';
    return 'reply' if $type eq 'comment';
    return $type =~ /\Aemail/ ? 'email' : 'notification';
}

sub report ($self) {
    my $p = ready($self);
    my $f = sub ($lf) { $p->field( ticket => $lf ) };
    my $spec = $self->param('ticket');
    my @lf = ( Odoo::Ops::Helpdesk::TicketList::fields_to_read($self), grep { defined $f->($_) } qw(description company kanban_state unattended notes sla_rows) );
    my ( $t, $why ) = ticket_row( $self, $spec, @lf );
    Odoo::Error->throw( kind => 'refused', code => 'unknown-record', message => "No ticket '$spec' that this login can read",
        fix => 'oom-ops run helpdesk.tickets finds tickets' ) if !$t;
    my $id = $t->{id};
    my $raw = { id => $id, map { $f->($_) => $t->{f}{$_} } keys %{ $t->{f} } };
    my ($row) = @{ Odoo::Ops::Helpdesk::TicketList::shape( $self, [$raw] ) };

    # followers
    my @fids = @{ $self->model('ticket')->read_one( $id, ['message_partner_ids'] )->{message_partner_ids} // [] };
    my $pn = $p->field( partner => 'name' );
    my %pname = @fids ? ( map { $_->{id} => $_->{$pn} } @{ $self->model('partner')->read( \@fids, [$pn] ) } ) : ();

    # the files on the ticket, and the conversation
    my $af = sub ($lf) { $p->field( attachment => $lf ) };
    my $atts = $self->model('attachment')->search_read( [ [ $af->('res_model'), '=', $p->model_name('ticket') ], [ $af->('res_id'), '=', $id ] ],
        [ map { $af->($_) } qw(name size mimetype) ], order => 'id' );
    my %aname = map { $_->{id} => $_->{ $af->('name') } } @$atts;
    my $mf = sub ($lf) { $p->field( message => $lf ) };
    my $msgs = $self->model('message')->search_read( [ [ $mf->('model'), '=', $p->model_name('ticket') ], [ $mf->('res_id'), '=', $id ] ],
        [ map { $mf->($_) } qw(author date body type subtype attachments) ], order => 'id' );
    my %internal;
    for my $sid ( keys %{ { map { id_of( $_->{ $mf->('subtype') } ) => 1 } grep { id_of( $_->{ $mf->('subtype') } ) } @$msgs } } ) {
        my $s = eval { $self->client->model('mail.message.subtype')->read_one( $sid, ['internal'] ) };
        $internal{$sid} = $s && $s->{internal} ? 1 : 0;
    }
    my @conv = map {
        my $m = $_;
        my $sub = id_of( $m->{ $mf->('subtype') } );
        my $html = $m->{ $mf->('body') } // '';
        +{
            id => $m->{id}, date => text( $m->{ $mf->('date') } ), author => name_of( $m->{ $mf->('author') } ) || undef, author_id => id_of( $m->{ $mf->('author') } ),
            kind => _kind( $m->{ $mf->('type') } // '', $sub && $internal{$sub} ), type => $m->{ $mf->('type') }, subtype => name_of( $m->{ $mf->('subtype') } ) || undef,
            body_text => Odoo::Ops::Discuss::Common::html_text($html), body_html => $html,
            attachments => [ map { $aname{$_} // $_ } @{ $m->{ $mf->('attachments') } // [] } ],
        };
    } @$msgs;

    # the SLA
    my %sla = ( deadline => $row->{sla_deadline}, expired => $row->{sla_expired} );
    if ( defined $f->('sla_rows') ) {
        my $sf = sub ($lf) { $p->field( ticket_sla => $lf ) };
        $sla{rows} = [ map { +{ name => text( $_->{ $sf->('name') } ), state => $_->{ $sf->('state') }, deadline => text( $_->{ $sf->('deadline') } ),
                hours => $_->{ $sf->('hours') }, consumed => $_->{ $sf->('consumed') }, expected_stage => name_of( $_->{ $sf->('expected_stage') } ) || undef } }
            @{ $self->model('ticket_sla')->search_read( [ [ $sf->('ticket'), '=', $id ] ], [ map { $sf->($_) } qw(name state deadline hours consumed expected_stage) ], order => 'id' ) } ];
    }

    my $desc = $t->{f}{description} // '';
    my %out = (
        %$row,
        description => $desc, description_text => Odoo::Ops::Discuss::Common::html_text($desc),
        company => name_of( $t->{f}{company} ) || undef, kanban_state => text( $t->{f}{kanban_state} ), unattended => flag( $t->{f}{unattended} ),
        ( defined $f->('notes') ? ( notes => text( $t->{f}{notes} ) ) : () ),
        followers => [ map { { id => $_, name => $pname{$_} } } @fids ],
        sla => \%sla, messages => \@conv,
        attachments => [ map { +{ id => $_->{id}, name => $_->{ $af->('name') }, size => $_->{ $af->('size') }, mimetype => text( $_->{ $af->('mimetype') } ) } } @$atts ],
    );
    return { count => 1, rows => [ \%out ], fields => fields_block( \@COLS ) };
}

1;
