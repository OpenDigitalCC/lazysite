package Odoo::Ops::Helpdesk::Raise;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops::Helpdesk::Common qw(ready id_of name_of look reason_text html_body files_for first_stage_for add_ticket apply_ticket_change undo_ticket);

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Helpdesk::Raise - a customer raises a ticket

=head1 SYNOPSIS

    oom-ops run helpdesk.raise --conf customer.conf --set team=Support --set subject="Printer jams" \
        --set description="Tray 2 jams" --file files=./photo.jpg

=head1 DESCRIPTION

C<helpdesk.raise>: a ticket for the person the request is for, made the way the module's own portal form makes
one. A portal login may not create a ticket, so the service login named in the config (C<act_as_conf>) creates
it; the customer is the person Odoo knows the request's own credential as, never a parameter. The ticket's partner
is the customer's partner (name and email from it), its channel is Web, its company the customer's, and the
customer is a follower from the start. The ticket is made in the first stage its team may use (the stage Odoo's
C<_get_applicable_stages> puts first), sent in the create as the module's portal form does on 16, so Odoo mails that
stage's template to the customer: the acknowledgement the portal sends (the plan line says which template). The series' way of leaving the ticket unassigned is the profile's: 18 sends
C<user_id> false, as the portal form does (18 gives a new ticket to its creator otherwise); 16 leaves it to the
module. C<team> and C<category> are an id or a name, read as the customer (a portal login reads only the teams that
are shown on the portal). C<files> (at most 10) are put on the ticket. The plan names the person and the
service login; only that person may apply it. Apply reads the ticket back with its number.

    raise            the ticket is made
    attach           a file is put on it (a support row)
    unknown-team, unknown-category, invalid   waits for a person, with the cause

The revert never deletes the ticket: the service login holds "User: Team tickets", which Odoo does not let delete one, so the
revert moves it to the team's closed stage (else the first closed stage the team may use), and the plan line says so. Odoo
mails the closed stage's template to the customer if it has one. Series 16 and 18.

=cut

sub op_name ($class) { 'helpdesk.raise' }
sub summary ($class) { 'A customer raises a ticket (the service login makes it for the verified person)' }
sub pack    ($class) { 'helpdesk' }
sub acts_for ($class) { 1 }

sub buckets ($class) {
    return [
        { name => 'raise',  meaning => 'the ticket is made for the customer by the service login' },
        { name => 'attach', meaning => 'a file is put on the new ticket (a support row)' },
    ];
}
sub holds ($class) {
    return [
        { name => 'unknown-team',     meaning => 'no team of that id or name that the customer\'s login can read' },
        { name => 'unknown-category', meaning => 'no category of that id or name that the customer\'s login can read' },
        { name => 'invalid',          meaning => 'the ticket lacks a subject or a description' },
    ];
}

sub params ($class) {
    {   subject     => { type => 'str',  required => 1, help => 'the subject' },
        description => { type => 'str',  required => 1, help => 'the description; plain text unless html is on' },
        html        => { type => 'bool', default => 0, help => 'description is already HTML' },
        team        => { type => 'str',  help => 'a team (an id or a name)' },
        category    => { type => 'str',  help => 'a category (an id or a name)' },
        files       => { type => 'files', max => 10, max_bytes => 25 * 1024 * 1024, help => 'files for the ticket: --file files=PATH (repeatable) on the command line' },
    };
}
sub read_scope ($class) { { team => [qw(search_read read)], category => [qw(search_read read)], stage => ['search_read'], partner => ['read'], 'ir.model.data' => ['check_object_reference'] } }
sub write_scope ($class) { { ticket => [qw(create write)], attachment => ['create'] } }

sub plan ($self) {
    my $p = ready($self);
    my $f = sub ($lf) { $p->field( ticket => $lf ) };
    my $plan = $self->new_plan( input_count => 1 );
    my $me = $self->person;
    my $hold = sub ( $bucket, $why ) { $plan->add( bucket => $bucket, action => 'hold', key => 'raise', reason => $why ); return $plan };
    return $hold->( 'invalid', 'a ticket needs a subject and a description' ) if $self->param('subject') !~ /\S/ || $self->param('description') !~ /\S/;
    my %vals = ( $f->('title') => $self->param('subject'), $f->('description') => html_body( $self->param('description'), $self->param('html') ),
        $f->('partner') => $me->{partner_id} );
    my $pr = $self->model('partner')->read_one( $me->{partner_id}, [ $p->field( partner => 'name' ), $p->field( partner => 'email' ) ] );
    $vals{ $f->('partner_name') }  = $pr->{ $p->field( partner => 'name' ) };
    $vals{ $f->('partner_email') } = $pr->{ $p->field( partner => 'email' ) } || undef;
    if ( defined $self->param('team') ) {
        my ( $row, $why, @many ) = look( $self, team => $self->param('team') );
        return $hold->( 'unknown-team', reason_text( $why, 'team', $self->param('team'), @many ) ) if !$row;
        $vals{ $f->('team') } = $row->{id};
    }
    if ( defined $self->param('category') ) {
        my ( $row, $why, @many ) = look( $self, category => $self->param('category') );
        return $hold->( 'unknown-category', reason_text( $why, 'category', $self->param('category'), @many ) ) if !$row;
        $vals{ $f->('category') } = $row->{id};
    }
    # the first stage the team may use, sent in the create as the module's portal form does, so that Odoo mails the stage's template
    my ( $first, $ack ) = first_stage_for( $self, $self->service_client, $vals{ $f->('team') }, $vals{ $f->('category') } );
    $vals{ $f->('stage') } = $first if $first;
    my ( $mod, $web ) = split
 /\./, $p->action('channel_web'), 2;
    my $ref = $self->service_client->execute_kw( 'ir.model.data', 'check_object_reference', [ $mod, $web ] );
    $vals{ $f->('channel') } = $ref->[1] if ref $ref eq 'ARRAY' && $ref->[1];
    my $co = $self->client->model('res.users')->read_one( $me->{uid}, ['company_id'] );
    $vals{ $f->('company') } = id_of( $co->{company_id} ) if $co && id_of( $co->{company_id} );
    $vals{ $f->('user') } = JSON::PP::false if $p->action('raise_user') eq 'none';
    $vals{message_partner_ids} = [ [ 4, $me->{partner_id} ] ];  # the follower field is not in a portal login's fields_get, so it is not in the profile
    add_ticket( $self, $plan, bucket => 'raise', key => 'raise', ref => 'raised', vals => \%vals,
        readback => [ ( grep { defined } map { $f->($_) } qw(number team stage user partner channel) ), 'message_partner_ids' ],
        reason => "made for $me->{login} by the service login; $me->{login} follows it" . ( $ack ? "; $ack" : '' ) );
    for my $file ( files_for( $self, $plan, $self->param('files') ) ) {
        $plan->add( bucket => 'attach', action => 'create', model => $p->model_name('attachment'), key => "raise:file:$file->{name}", support => 1,
            vals => { map { $p->field( attachment => $_->[0] ) => $_->[1] } [ name => $file->{name} ], [ res_model => $p->model_name('ticket') ],
                [ res_id => { '$ref' => 'raised' } ], [ datas => $file->{datas} ], ( $file->{mimetype} ? ( [ mimetype => $file->{mimetype} ] ) : () ) },
            reason => "file $file->{name} ($file->{size} bytes, sha256 $file->{sha256}) goes on the ticket" );
    }
    return $plan;
}

sub apply_custom ($class, $client, $c) { return apply_ticket_change( $class, $client, $c ) }
sub undo_custom ($class, $entry) { return undo_ticket( $class, $entry ) }

1;
