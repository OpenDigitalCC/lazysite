package Odoo::Test::HelpdeskFixture;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use JSON::PP ();

use Odoo::Ops::Profile;
use Odoo::Test::FakeOdoo;

# A small helpdesk world for the offline tests of docs/specs/helpdesk-1.md: the OCA helpdesk_mgmt models of Odoo 16 or 18
# as the profiles map them, two teams, four stages (one closed, one that requires a category and tags), three tickets, and a
# message_post that records what it was sent. The fake does not compute what Odoo computes (numbers, stages from teams), so
# a test of those is a live one (t/130-helpdesk-live.t).
#
#   my $fake = Odoo::Test::HelpdeskFixture->new( series => 18 );
#   $fake->{posts}      the message_post calls made: [ { ids, kw } ]

my %M2O = (
    'helpdesk.ticket'          => { partner_id => 'res.partner', commercial_partner_id => 'res.partner', team_id => 'helpdesk.ticket.team', user_id => 'res.users',
        stage_id => 'helpdesk.ticket.stage', category_id => 'helpdesk.ticket.category', channel_id => 'helpdesk.ticket.channel', company_id => 'res.company' },
    'helpdesk.ticket.team'     => { user_id => 'res.users', company_id => 'res.company', resource_calendar_id => 'resource.calendar', parent_id => 'helpdesk.ticket.team' },
    'helpdesk.ticket.stage'    => { mail_template_id => 'mail.template', company_id => 'res.company' },
    'helpdesk.ticket.category' => { company_id => 'res.company', default_team_id => 'helpdesk.ticket.team', parent_id => 'helpdesk.ticket.category' },
    'res.partner'              => { parent_id => 'res.partner', commercial_partner_id => 'res.partner' },
    'res.users'                => { partner_id => 'res.partner' },
    'mail.message'             => { author_id => 'res.partner', subtype_id => 'mail.message.subtype' },
    'helpdesk.sla'             => { stage_id => 'helpdesk.ticket.stage' },
);
my %M2M = (
    'helpdesk.ticket'          => { tag_ids => 'helpdesk.ticket.tag', message_partner_ids => 'res.partner', message_ids => 'mail.message', ticket_sla_ids => 'helpdesk.ticket.sla' },
    'helpdesk.ticket.team'     => { user_ids => 'res.users', category_ids => 'helpdesk.ticket.category' },
    'helpdesk.ticket.stage'    => { team_ids => 'helpdesk.ticket.team', validate_field_ids => 'ir.model.fields' },
    'mail.message'             => { attachment_ids => 'ir.attachment', partner_ids => 'res.partner' },
    'helpdesk.sla'             => { team_ids => 'helpdesk.ticket.team', category_ids => 'helpdesk.ticket.category', tag_ids => 'helpdesk.ticket.tag', ignore_stage_ids => 'helpdesk.ticket.stage', stage_ids => 'helpdesk.ticket.stage' },
);
my %BOOL = map { $_ => 1 } qw(active closed unattended show_in_portal close_from_portal fold sla_expired expired);

sub new ( $class, %o ) {
    my $series = $o{series} // 16;
    my %fields = (
        'res.company' => { name => { type => 'char', store => 1 } },
        'ir.model.fields' => { name => { type => 'char', store => 1 }, ttype => { type => 'char', store => 1 }, model => { type => 'char', store => 1 } },
        'ir.model.data' => { name => { type => 'char', store => 1 } },
        'ir.module.module' => { name => { type => 'char', store => 1 }, state => { type => 'char', store => 1 } },
        'mail.message.subtype' => { name => { type => 'char', store => 1 }, internal => { type => 'boolean', store => 1 } },
        'mail.template' => { name => { type => 'char', store => 1 } },
        'resource.calendar' => { name => { type => 'char', store => 1 } },
        'helpdesk.ticket.sla' => {},
    );
    my $p = Odoo::Ops::Profile->load( pack => 'helpdesk', series => $series );
    for my $lm ( $p->models ) {
        my $model = $p->model_name($lm);
        for my $f ( @{ $p->physical_fields($lm) } ) {
            $fields{$model}{$f} = $M2O{$model}{$f} ? { type => 'many2one', relation => $M2O{$model}{$f}, store => 1 }
                : $M2M{$model}{$f} ? { type => ( $f =~ /sla_ids/ ? 'one2many' : 'many2many' ), relation => $M2M{$model}{$f}, store => 1 }
                : $BOOL{$f} ? { type => 'boolean', store => 1 }
                : { type => 'char', store => 1 };
            $fields{$model}{$f}{string} = ucfirst( $f =~ s/_ids?\z//r ) if $model eq 'helpdesk.ticket';
        }
    }
    $fields{'helpdesk.ticket'}{priority} = { type => 'selection', store => 1, selection => [ [ 0, 'Low' ], [ 1, 'Medium' ], [ 2, 'High' ], [ 3, 'Very High' ] ] };
    $fields{'helpdesk.ticket'}{category_id}{string} = 'Category';
    $fields{'res.users'}{company_id} = { type => 'many2one', relation => 'res.company', store => 1 };
    $fields{"helpdesk.ticket"}{message_partner_ids} = { type => "many2many", relation => "res.partner", store => 1 };
    $fields{'helpdesk.ticket'}{tag_ids}{string} = 'Tags';
    $fields{'mail.message'}{$_} //= { type => 'char', store => 1 } for qw(model res_id body message_type date);
    my $T = JSON::PP::true;
    my $fake = Odoo::Test::FakeOdoo->new(
        series => $series,
        fields => \%fields,
        records => {
            'res.company' => [ { id => 1, name => 'Example' } ],
            'res.partner' => [
                { id => 7,  name => 'Test User', email => 'tester@ours.example', commercial_partner_id => 7 },
                { id => 10, name => 'Acme Ltd', commercial_partner_id => 10 },
                { id => 11, name => 'Cora Customer', email => 'cora@acme.example', parent_id => 10, commercial_partner_id => 10 },
                { id => 12, name => 'Other Co', commercial_partner_id => 12 },
            ],
            'res.users' => [
                { id => 2, login => 'tester', name => 'Test User', partner_id => 7, company_id => 1 },
                { id => 3, login => 'ann@support.example', name => 'Ann Agent', partner_id => 13 },
                { id => 4, login => 'bob@support.example', name => 'Bob Other', partner_id => 14 },
            ],
            'ir.module.module' => [ map { { name => $_, state => 'installed' } } qw(helpdesk_mgmt helpdesk_mgmt_sla helpdesk_mgmt_stage_validation) ],
            'mail.message.subtype' => [ { id => 1, name => 'Discussions', internal => 0 }, { id => 2, name => 'Note', internal => $T } ],
            'mail.template' => [ { id => 5, name => 'Helpdesk Closed Ticket Notification Email' } ],
            'ir.model.fields' => [ { id => 101, model => 'helpdesk.ticket', name => 'category_id', ttype => 'many2one' }, { id => 102, model => 'helpdesk.ticket', name => 'tag_ids', ttype => 'many2many' } ],
            'helpdesk.ticket.team' => [
                { id => 1, name => 'Support', user_ids => [3], show_in_portal => $T, alias_name => 'help', todo_ticket_count => 2, category_ids => [1], use_sla => $T },
                { id => 2, name => 'Billing', user_ids => [], show_in_portal => $T, todo_ticket_count => 1 },
            ],
            'helpdesk.ticket.stage' => [
                { id => 1, name => 'New', sequence => 1 },
                { id => 2, name => 'In Progress', sequence => 2 },
                { id => 3, name => 'Done', sequence => 4, closed => $T, close_from_portal => $T, mail_template_id => 5, fold => $T },
                { id => 4, name => 'Checked', sequence => 5, validate_field_ids => [ 101, 102 ] },
                { id => 5, name => 'Billing only', sequence => 6, team_ids => [2] },
            ],
            'helpdesk.ticket.category' => [ { id => 1, name => 'Hardware' } ],
            'helpdesk.ticket.tag' => [ { id => 1, name => 'urgent' }, { id => 2, name => 'printer' } ],
            'helpdesk.ticket.channel' => [ { id => 1, name => 'Phone' } ],
            'helpdesk.ticket' => [
                { id => 1, number => 'HT00001', name => 'Printer jams', description => '<p>jams</p>', partner_id => 11, commercial_partner_id => 10, team_id => 1, stage_id => 1, priority => '1', tag_ids => [], create_date => '2026-10-01 09:00:00', last_stage_update => '2026-10-01 09:00:00', message_partner_ids => [2] },
                { id => 2, number => 'HT00002', name => 'Old question', description => '<p>q</p>', partner_id => 11, commercial_partner_id => 10, team_id => 1, stage_id => 3, closed => $T, priority => '2', category_id => 1, tag_ids => [1], user_id => 3, create_date => '2026-09-01 09:00:00', last_stage_update => '2026-09-05 09:00:00', closed_date => '2026-09-05 09:00:00' },
                { id => 3, number => 'HT00003', name => 'Invoice wrong', description => '<p>inv</p>', partner_id => 12, commercial_partner_id => 12, team_id => 2, stage_id => 1, priority => '3', tag_ids => [], create_date => '2026-10-02 09:00:00', last_stage_update => '2026-10-02 09:00:00' },
            ],
        },
        methods => {
            # the xml id of a record (the portal channel the raise uses is the Phone channel here)
            'ir.model.data.check_object_reference' => sub ($f, $a, $k) { return [ 'helpdesk.ticket.channel', 1 ] },
            # the ticket's closed flag follows its stage (a related field in the module), so a move to a closed stage reads back closed
            'helpdesk.ticket.write' => sub ($f, $a, $k) {
                my ($ids, $vals) = @$a;
                for my $id (@$ids) {
                    my $r = $f->{data}{'helpdesk.ticket'}{$id} or die "record $id gone";
                    $f->_assign( 'helpdesk.ticket', $r, $vals );
                    $r->{closed} = $f->{data}{'helpdesk.ticket.stage'}{ $r->{stage_id} }{closed} ? JSON::PP::true : JSON::PP::false if exists $vals->{stage_id} && $r->{stage_id};
                }
                return JSON::PP::true;
            },
            'helpdesk.ticket.message_post' => sub ( $f, $a, $k ) {
                push @{ $f->{posts} }, { ids => $a->[0], kw => $k };
                return $f->insert( 'mail.message', { model => 'helpdesk.ticket', res_id => $a->[0][0], body => $k->{body}, message_type => $k->{message_type},
                    subtype_id => ( ( $k->{subtype_xmlid} // '' ) eq 'mail.mt_note' ? 2 : 1 ), author_id => $k->{author_id} // 7, attachment_ids => $k->{attachment_ids} // [], partner_ids => $k->{partner_ids} // [] } );
            },
        },
    );
    $fake->insert( 'res.partner', { id => 13, name => 'Ann Agent' } );
    $fake->insert( 'res.partner', { id => 14, name => 'Bob Other' } );
    return $fake;
}

1;
