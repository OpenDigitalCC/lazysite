package Odoo::Ops::Helpdesk::Create;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops::Helpdesk::Common qw(ready id_of name_of rows_of look user_row partner_row reason_text html_body members_of_team files_for spec_list first_stage_for pick_stage add_ticket apply_ticket_change undo_ticket);
use Odoo::Ops::Helpdesk::TicketList;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Helpdesk::Create - make tickets

=head1 SYNOPSIS

    oom-ops run helpdesk.create --conf ops.conf --set title="Printer jams" --set description="Tray 2 jams" \
        --set partner=ann@client.example --set team=Support --set category=Hardware --set tags=urgent
    oom-ops run helpdesk.create --conf ops.conf --set sender_email=una@client.example --set sender_name="Una" \
        --set title="Question" --set description="Hello" --file files=./screenshot.png
    oom-ops run helpdesk.create --conf ops.conf --rows rows=tickets.json

=head1 DESCRIPTION

C<helpdesk.create>: a ticket made as the login the config runs as, through Odoo's own C<create>, so the
module gives it its number, its stage and, on the series that does so, its user. The plan holds one
C<create> for each ticket (and one C<create> of an attachment for each file). Apply reads the ticket
back and names what Odoo made: its number, team, stage, user, partner and the SLA fields.

One ticket from C<title> and C<description> (plain text, put in a paragraph with its markup escaped;
C<html> says it is HTML already), or many from C<rows> (at most 100; each row has C<title> and
C<description> and any of the other keys, with the same words). C<partner> is an id, an email address or an
exact name. A sender Odoo does not know is C<sender_email> (and C<sender_name>): as the module's mail gateway does,
a partner whose email is that address is the ticket's partner when exactly one is, and otherwise the
ticket keeps the name and the address and has no partner (OOM makes no partner). C<team>, C<category>,
C<channel> are an id or a name; C<stage> (an id or a name) is the stage the ticket is made in; C<tags> a list of ids or names; C<priority> is C<0> to C<3> or C<Low>, C<Medium>,
C<High>, C<Very High>; C<user> is an id, a login or a name, and a user who is not a member of the named team is
held C<not-a-member>. C<files> (one ticket only, at most 10; C<--file files=PATH> on the command line)
are put on the ticket.

    create           the ticket is made
    attach           a file is put on it (a support row)
    unknown-team, unknown-category, unknown-tag, unknown-stage, unknown-channel, unknown-user, unknown-partner,
    ambiguous-partner, not-a-member, invalid   a row waits for a person, with the cause

The ticket is made in the first stage its team may use (the stage Odoo's C<_get_applicable_stages> puts first), sent in the
create exactly as C<helpdesk.raise> does, unless C<stage> names one: on 16 this is what makes Odoo mail that stage's template
to the ticket's partner (the acknowledgement the portal sends), and 18 does it already. The plan line says which template Odoo
mails, or that the stage has none. A ticket with no team, or whose team has no stage, is made without a stage.

The revert removes the files and never deletes the ticket: the service login holds "User: Team tickets", which Odoo does not
let delete one, so the revert moves the ticket to the team's closed stage (else the first closed stage the team may use),
and the plan line says so. Odoo mails the closed stage's template to the ticket's partner if it has one. Series 16 and 18.

=cut

sub op_name ($class) { 'helpdesk.create' }
sub summary ($class) { 'Make tickets: partner or sender, team, category, tags, priority, channel, description, files' }
sub pack    ($class) { 'helpdesk' }

sub buckets ($class) {
    return [
        { name => 'create', meaning => 'the ticket is made through Odoo\'s create' },
        { name => 'attach', meaning => 'a file is put on the new ticket (a support row)' },
    ];
}
sub holds ($class) {
    return [
        { name => 'unknown-team',      meaning => 'no team of that id or name' },
        { name => 'unknown-category',  meaning => 'no category of that id or name' },
        { name => 'unknown-tag',       meaning => 'no tag of that id or name' },
        { name => 'unknown-stage',     meaning => 'no stage of that id or name, or a name that several stages the team may use carry' },
        { name => 'unknown-channel',   meaning => 'no channel of that id or name' },
        { name => 'unknown-user',      meaning => 'no user of that id, login or name' },
        { name => 'unknown-partner',   meaning => 'no partner of that id, email address or name' },
        { name => 'ambiguous-partner', meaning => 'the partner or the sender\'s address matches several partners' },
        { name => 'not-a-member',      meaning => 'the user is not a member of the team the ticket is for' },
        { name => 'invalid',           meaning => 'the row lacks a title or a description, or names a priority Odoo has not' },
    ];
}

my %ROW = ( title => 'str?', description => 'str?', html => 'bool?', partner => 'str?', sender_name => 'str?', sender_email => 'str?',
    team => 'str?', category => 'str?', tags => 'str?', priority => 'str?', channel => 'str?', user => 'str?', stage => 'str?' );

sub params ($class) {
    {   title        => { type => 'str',  help => 'the subject' },
        description  => { type => 'str',  help => 'the description; plain text unless html is on' },
        html         => { type => 'bool', default => 0, help => 'description is already HTML' },
        partner      => { type => 'str',  help => 'the customer: an id, an email address or an exact name' },
        sender_name  => { type => 'str',  help => 'for a sender Odoo has no partner for: the name kept on the ticket' },
        sender_email => { type => 'str',  help => 'the sender\'s address: its partner when exactly one has it, else kept on the ticket' },
        team         => { type => 'str',  help => 'a team (an id or a name)' },
        category     => { type => 'str',  help => 'a category (an id or a name)' },
        tags         => { type => 'list', help => 'tags (ids or names), comma separated' },
        priority     => { type => 'str',  help => '0 to 3 or Low, Medium, High, Very High' },
        channel      => { type => 'str',  help => 'a channel (an id or a name)' },
        stage        => { type => 'str',  help => 'the stage the ticket is made in (an id or a name); the team\'s first stage when not given' },
        user         => { type => 'str',  help => 'the assigned user (an id, a login or a name)' },
        files        => { type => 'files', max => 10, max_bytes => 25 * 1024 * 1024, help => 'files for the one ticket: --file files=PATH (repeatable) on the command line' },
        rows         => { type => 'rows', max => 100, row => {%ROW}, help => 'many tickets: a flat object each, with the keys of the parameters above (tags comma separated)' },
    };
}

sub read_scope ($class) {
    { team => [qw(search_read read)], stage => ['search_read'], category => [qw(search_read read)], tag => ['search_read'], channel => ['search_read'], user => ['search_read'],
      partner => ['search_read'] };
}
sub write_scope ($class) { { ticket => [qw(create write)], attachment => ['create'] } }

sub plan ($self) {
    my $p = ready($self);
    my @give = grep { defined $self->param($_) } qw(title description html partner sender_name sender_email team category tags priority channel user stage);
    my $rows = $self->param('rows');
    Odoo::Error->throw( kind => 'usage', message => 'helpdesk.create: give rows or the parameters of one ticket, not both' ) if $rows && grep { $_ ne 'html' || $self->param('html') } @give;
    Odoo::Error->throw( kind => 'usage', message => 'helpdesk.create: files go with one ticket, not with rows' ) if $rows && @{ $self->param('files') // [] };
    Odoo::Error->throw( kind => 'usage', message => 'helpdesk.create: give a title and a description, or rows' ) if !$rows && !defined $self->param('title');
    $rows ||= [ { map { $_ => $self->param($_) } grep { defined $self->param($_) } qw(title description html partner sender_name sender_email team category priority channel user stage), ( $self->param('tags') ? ( tags => join( ',', @{ $self->param('tags') } ) ) : () ) } ];
    my $plan = $self->new_plan( input_count => scalar @$rows );
    my $n = 0;
    my $f = sub ($lf) { $p->field( ticket => $lf ) };
    for my $r (@$rows) {
        $n++;
        my $key = "ticket:$n";
        my $hold = sub ( $bucket, $why ) { $plan->add( bucket => $bucket, action => 'hold', key => $key, reason => ( @$rows > 1 ? "row $n: " : '' ) . $why ); 1 };
        next if ( !defined $r->{title} || $r->{title} !~ /\S/ || !defined $r->{description} || $r->{description} !~ /\S/ ) && $hold->( 'invalid', 'a ticket needs a title and a description' );
        my %vals = ( $f->('title') => $r->{title}, $f->('description') => html_body( $r->{description}, $r->{html} ) );
        my @note;
        # the customer
        if ( defined $r->{partner} ) {
            my ( $row, $why, @many ) = partner_row( $self, $r->{partner} );
            next if !$row && $hold->( $why eq 'none' ? 'unknown-partner' : 'ambiguous-partner', reason_text( $why, 'partner', $r->{partner}, @many ) );
            @vals{ $f->('partner'), $f->('partner_name'), $f->('partner_email') } = ( $row->{id}, $row->{ $p->field( partner => 'name' ) }, $row->{ $p->field( partner => 'email' ) } || undef );
        }
        elsif ( defined $r->{sender_email} || defined $r->{sender_name} ) {
            my $found;
            if ( defined $r->{sender_email} ) {
                next if $r->{sender_email} !~ /\@/ && $hold->( 'invalid', "sender_email '$r->{sender_email}' is not an email address" );
                my ( $row, $why, @many ) = partner_row( $self, $r->{sender_email} );
                next if !$row && $why eq 'many' && $hold->( 'ambiguous-partner', reason_text( $why, 'partner', $r->{sender_email}, @many ) );
                $found = $row;
            }
            if ($found) {
                @vals{ $f->('partner'), $f->('partner_name'), $f->('partner_email') } = ( $found->{id}, $found->{ $p->field( partner => 'name' ) }, $found->{ $p->field( partner => 'email' ) } || undef );
                push @note, "partner $found->{id} has the address $r->{sender_email}";
            }
            else {
                $vals{ $f->('partner_name') }  = $r->{sender_name}  if defined $r->{sender_name};
                $vals{ $f->('partner_email') } = $r->{sender_email} if defined $r->{sender_email};
                push @note, 'no partner has that address: the ticket keeps the name and the address, as the mail gateway keeps an unknown sender';
            }
        }
        # team, category, tags, channel
        my ( $team_id, $team_name );
        if ( defined $r->{team} ) {
            my ( $row, $why, @many ) = look( $self, team => $r->{team}, fields => ['name'] );
            next if !$row && $hold->( 'unknown-team', reason_text( $why, 'team', $r->{team}, @many ) );
            $team_id = $vals{ $f->('team') } = $row->{id};
            $team_name = $row->{ $p->field( team => 'name' ) };
        }
        if ( defined $r->{category} ) {
            my ( $row, $why, @many ) = look( $self, category => $r->{category} );
            next if !$row && $hold->( 'unknown-category', reason_text( $why, 'category', $r->{category}, @many ) );
            $vals{ $f->('category') } = $row->{id};
        }
        if ( defined $r->{channel} ) {
            my ( $row, $why, @many ) = look( $self, channel => $r->{channel} );
            next if !$row && $hold->( 'unknown-channel', reason_text( $why, 'channel', $r->{channel}, @many ) );
            $vals{ $f->('channel') } = $row->{id};
        }
        if ( defined $r->{tags} && length $r->{tags} ) {
            my @tid;
            my $bad;
            for my $t ( spec_list( $r->{tags} ) ) {
                my ( $row, $why, @many ) = look( $self, tag => $t );
                if ( !$row ) { $bad = reason_text( $why, 'tag', $t, @many ); last }
                push @tid, $row->{id};
            }
            next if $bad && $hold->( 'unknown-tag', $bad );
            $vals{ $f->('tags') } = [ [ 6, 0, \@tid ] ];
        }
        if ( defined $r->{priority} ) {
            my $v = eval { Odoo::Ops::Helpdesk::TicketList::priority_value( $self, $r->{priority} ) };
            next if !defined $v && $hold->( 'invalid', "priority '$r->{priority}' is not one of 0 to 3 or Low, Medium, High, Very High" );
            $vals{ $f->('priority') } = $v;
        }
        if ( defined $r->{user} ) {
            my ( $row, $why, @many ) = user_row( $self, $r->{user} );
            next if !$row && $hold->( 'unknown-user', reason_text( $why, 'user', $r->{user}, @many ) );
            if ($team_id) {
                my $members = members_of_team( $self, $team_id );
                next if !exists $members->{ $row->{id} } && $hold->( 'not-a-member', "user '$r->{user}' is not a member of team '$team_name'" . ( %$members ? ' (members: ' . join( ', ', map { $members->{$_} } sort { $a <=> $b } keys %$members ) . ')' : ' (it has no members)' ) );
            }
            $vals{ $f->('user') } = $row->{id};
        }
        # the stage: the one named, else the team's first, sent in the create so that Odoo mails the stage's template
        my ( $first, $ack );
        if ( defined $r->{stage} ) {
            my ( $row, $why, @many ) = pick_stage( $self, $r->{stage}, $team_id );
            next if !$row && $hold->( 'unknown-stage', reason_text( $why, 'stage', $r->{stage}, @many ) );
            $first = $row->{id};
            push @note, "the ticket is made in the stage named, $r->{stage}";
        }
        else {
            ( $first, $ack ) = first_stage_for( $self, $self->client, $team_id, $vals{ $f->('category') } );
            push @note, $ack if $ack;
        }
        $vals{ $f->('stage') } = $first if $first;
        my $ref = "ticket$n";
        add_ticket( $self, $plan, bucket => 'create', key => $key, ref => $ref, vals => \%vals,
            readback => [ grep { defined } map { $f->($_) } qw(number team stage user partner priority sla_deadline sla_expired sla_rows) ],
            ( @note ? ( reason => join( '; ', @note ) ) : () ) );
        for my $file ( files_for( $self, $plan, $self->param('files') ) ) {
            $plan->add( bucket => 'attach', action => 'create', model => $p->model_name('attachment'), key => "$key:file:$file->{name}", support => 1,
                vals => { map { $p->field( attachment => $_->[0] ) => $_->[1] } [ name => $file->{name} ], [ res_model => $p->model_name('ticket') ],
                    [ res_id => { '$ref' => $ref } ], [ datas => $file->{datas} ], ( $file->{mimetype} ? ( [ mimetype => $file->{mimetype} ] ) : () ) },
                reason => "file $file->{name} ($file->{size} bytes, sha256 $file->{sha256}) goes on the ticket" );
        }
    }
    return $plan;
}

sub apply_custom ($class, $client, $c) { return apply_ticket_change( $class, $client, $c ) }
sub undo_custom ($class, $entry) { return undo_ticket( $class, $entry ) }

1;
