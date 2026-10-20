package Odoo::Ops::Helpdesk::Update;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Error;
use Odoo::Ops::Helpdesk::Common qw(ready id_of rows_of look reason_text html_body ticket_row spec_list);
use Odoo::Ops::Helpdesk::TicketList;

use parent 'Odoo::Ops::Operation';

=head1 NAME

Odoo::Ops::Helpdesk::Update - change a ticket's priority, category, tags, team, subject or description

=head1 SYNOPSIS

    oom-ops run helpdesk.update --conf ops.conf --set ticket=HT00012 --set priority=High --set tags=urgent,printer
    oom-ops run helpdesk.update --conf ops.conf --rows rows=changes.json

=head1 DESCRIPTION

C<helpdesk.update>: writes the named fields of a ticket (or of each row's ticket), with the ticket's
values as they are now kept as the before-image, so a plan made on a ticket that has changed since is
refused stale at apply. A field given as it already is is C<unchanged>. The fields: C<title>,
C<description> (plain text unless C<html>), C<priority> (C<0> to C<3> or C<Low>, C<Medium>, C<High>,
C<Very High>), C<category> and C<team> (an id or a name; an empty value clears it), C<tags> (ids or names,
replacing the tags the ticket has; an empty list clears them). The ticket is an id or a number
(C<HT00012>). A change of team has the effects the series gives it (see the behaviour file of
C<helpdesk.ticket>, shown on the plan): on 16 the ticket goes back to the new team's first stage; on 18 a
user who is not in the new team is removed. The user and the stage have their own operations,
C<helpdesk.assign> and C<helpdesk.stage>.

    update           the fields are written
    unchanged        the ticket already holds them
    unknown-ticket, unknown-team, unknown-category, unknown-tag, invalid   a row waits for a person

Series 16 and 18.

=cut

sub op_name ($class) { 'helpdesk.update' }
sub summary ($class) { 'Set a ticket\'s priority, category, tags, team, subject or description' }
sub pack    ($class) { 'helpdesk' }

sub buckets ($class) {
    return [
        { name => 'update',    meaning => 'the ticket\'s fields are written' },
        { name => 'unchanged', meaning => 'the ticket already holds these values' },
    ];
}
sub holds ($class) {
    return [
        { name => 'unknown-ticket',   meaning => 'no ticket of that id or number that this login can read' },
        { name => 'unknown-team',     meaning => 'no team of that id or name' },
        { name => 'unknown-category', meaning => 'no category of that id or name' },
        { name => 'unknown-tag',      meaning => 'no tag of that id or name' },
        { name => 'invalid',          meaning => 'a row changes nothing, or names a priority Odoo has not' },
    ];
}

my %ROW = ( ticket => 'str', title => 'str?', description => 'str?', html => 'bool?', priority => 'str?', category => 'str?', team => 'str?', tags => 'str?' );

sub params ($class) {
    {   ticket      => { type => 'str',  help => 'the ticket id or number (HT00012)' },
        title       => { type => 'str',  help => 'the new subject' },
        description => { type => 'str',  help => 'the new description; plain text unless html is on' },
        html        => { type => 'bool', default => 0, help => 'description is already HTML' },
        priority    => { type => 'str',  help => '0 to 3 or Low, Medium, High, Very High' },
        category    => { type => 'str',  help => 'a category (an id or a name); empty clears it' },
        team        => { type => 'str',  help => 'a team (an id or a name); empty clears it' },
        tags        => { type => 'list', help => 'the ticket\'s tags (ids or names), comma separated; an empty list clears them' },
        rows        => { type => 'rows', max => 100, row => {%ROW}, help => 'many tickets: a flat object each, ticket and any of the keys above (tags comma separated)' },
    };
}
sub read_scope ($class) { { ticket => [qw(search_read read)], team => ['search_read'], category => ['search_read'], tag => ['search_read'] } }
sub write_scope ($class) { { ticket => ['write'] } }

sub plan ($self) {
    my $p = ready($self);
    my $f = sub ($lf) { $p->field( ticket => $lf ) };
    my @single = grep { defined $self->param($_) } qw(title description priority category team tags);
    my $rows = $self->param('rows');
    Odoo::Error->throw( kind => 'usage', message => 'helpdesk.update: give rows or one ticket with the fields to change, not both' ) if $rows && ( defined $self->param('ticket') || @single );
    Odoo::Error->throw( kind => 'usage', message => 'helpdesk.update: give a ticket and the fields to change, or rows' ) if !$rows && !defined $self->param('ticket');
    $rows ||= [ { ticket => $self->param('ticket'), html => $self->param('html'), ( map { $_ => $self->param($_) } grep { $_ ne 'tags' } @single ), ( defined $self->param('tags') ? ( tags => join( ',', @{ $self->param('tags') } ) ) : () ) } ];
    my $plan = $self->new_plan( input_count => scalar @$rows );
    my $n = 0;
    my %seen;
    for my $r (@$rows) {
        $n++;
        my $key = "ticket:$r->{ticket}";
        my $hold = sub ( $bucket, $why ) { $plan->add( bucket => $bucket, action => 'hold', key => $key, reason => ( @$rows > 1 ? "row $n: " : '' ) . $why ); 1 };
        my @want = grep { defined $r->{$_} } qw(title description priority category team tags);
        next if !@want && $hold->( 'invalid', 'the row names no field to change' );
        my ( $t, $why ) = ticket_row( $self, $r->{ticket}, qw(title description priority category team tags) );
        next if !$t && $hold->( 'unknown-ticket', reason_text( $why, 'ticket', $r->{ticket} ) );
        next if $seen{ $t->{id} }++ && $hold->( 'invalid', "ticket $t->{id} is named by an earlier row; one row for each ticket" );
        my ( %vals, %before );
        my $set = sub ( $lf, $new ) {
            my $cur = $t->{f}{$lf};
            my $same = ref $new eq 'ARRAY' ? ( join( ',', sort { $a <=> $b } @{ $cur // [] } ) eq join( ',', sort { $a <=> $b } @$new ) )
                : $lf =~ /\A(?:category|team)\z/ ? ( ( id_of($cur) // 0 ) == ( $new // 0 ) )
                : ( ( $cur // '' ) eq ( $new // '' ) );
            return if $same;
            $vals{ $f->($lf) } = $new;
            $before{ $f->($lf) } = $cur;
        };
        $set->( title => $r->{title} ) if defined $r->{title};
        $set->( description => html_body( $r->{description}, $r->{html} ) ) if defined $r->{description};
        if ( defined $r->{priority} ) {
            my $v = eval { Odoo::Ops::Helpdesk::TicketList::priority_value( $self, $r->{priority} ) };
            next if !defined $v && $hold->( 'invalid', "priority '$r->{priority}' is not one of 0 to 3 or Low, Medium, High, Very High" );
            $set->( priority => $v );
        }
        for my $lm (qw(category team)) {
            next if !defined $r->{$lm};
            if ( !length $r->{$lm} ) { $set->( $lm => undef ); next }
            my ( $row, $why2, @many ) = look( $self, $lm => $r->{$lm} );
            next if !$row && $hold->( "unknown-$lm", reason_text( $why2, $lm, $r->{$lm}, @many ) );
            $set->( $lm => $row->{id} );
        }
        if ( defined $r->{tags} ) {
            my @tid;
            my $bad;
            for my $tg ( spec_list( $r->{tags} ) ) {
                my ( $row, $why2, @many ) = look( $self, tag => $tg );
                if ( !$row ) { $bad = reason_text( $why2, 'tag', $tg, @many ); last }
                push @tid, $row->{id};
            }
            next if $bad && $hold->( 'unknown-tag', $bad );
            $set->( tags => \@tid );
            $vals{ $f->('tags') } = [ [ 6, 0, \@tid ] ] if exists $vals{ $f->('tags') };
        }
        if (%vals) {
            $plan->add( bucket => 'update', action => 'write', model => $p->model_name('ticket'), id => $t->{id}, key => $key, vals => \%vals, before => \%before );
        }
        else {
            $plan->add( bucket => 'unchanged', action => 'skip', id => $t->{id}, key => $key, reason => "ticket $t->{id} already holds these values" );
        }
    }
    return $plan;
}

1;
