package Odoo::Test::CRMFixture;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Exporter 'import';
our @EXPORT_OK = qw(crm_fields);

# fields_get for the models profiles/crm/16.yaml maps, as the fake
# Odoo serves them. Types follow Odoo 16; only what the tests need.

sub crm_fields () {
    my $s = sub ($type, %x) { { type => $type, store => 1, %x } };
    return {
        'crm.lead' => {
            name             => $s->( 'char', required => 1, string => 'Opportunity' ),
            type             => $s->( 'selection', selection => [ [ 'lead', 'Lead' ], [ 'opportunity', 'Opportunity' ] ] ),
            contact_name     => $s->('char'),
            partner_name     => $s->('char'),
            function         => $s->('char'),
            email_from       => $s->('char'),
            phone            => $s->('char'),
            mobile           => $s->('char'),
            website          => $s->('char'),
            street           => $s->('char'),
            city             => $s->('char'),
            zip              => $s->('char'),
            country_id       => $s->( 'many2one', relation => 'res.country' ),
            lang_id          => $s->( 'many2one', relation => 'res.lang' ),
            description      => $s->('html'),
            tag_ids          => $s->( 'many2many', relation => 'crm.tag' ),
            stage_id         => $s->( 'many2one', relation => 'crm.stage' ),
            team_id          => $s->( 'many2one', relation => 'crm.team' ),
            user_id          => $s->( 'many2one', relation => 'res.users' ),
            partner_id       => $s->( 'many2one', relation => 'res.partner' ),
            source_id        => $s->( 'many2one', relation => 'utm.source' ),
            medium_id        => $s->( 'many2one', relation => 'utm.medium' ),
            campaign_id      => $s->( 'many2one', relation => 'utm.campaign' ),
            priority         => $s->('selection'),
            expected_revenue => $s->('monetary'),
            probability      => $s->('float'),
            date_deadline    => $s->('date'),
            active           => $s->('boolean'),
            create_date      => $s->('datetime'),
            create_uid       => $s->( 'many2one', relation => 'res.users' ),
            write_date       => $s->('datetime'),
            is_blacklisted   => { type => 'boolean', store => 0 },
        },
        'crm.tag'      => { name => $s->('char'), color => $s->('integer') },
        'crm.stage'    => { name => $s->('char'), sequence => $s->('integer'), is_won => $s->('boolean') },
        'crm.team'     => { name => $s->('char') },
        'utm.source'   => { name => $s->('char') },
        'utm.medium'   => { name => $s->('char') },
        'utm.campaign' => { name => $s->('char') },
        'res.country'  => { name => $s->('char'), code => $s->('char') },
        'res.partner'  => {
            name => $s->('char'), email => $s->('char'), vat => $s->('char'), street => $s->('char'),
            parent_id => $s->( 'many2one', relation => 'res.partner' ), is_company => $s->('boolean'),
            commercial_partner_id => $s->( 'many2one', relation => 'res.partner' ),
        },
    };
}

1;
