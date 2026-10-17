package Odoo::Test::ModulesFake;

use strict;
use warnings;

use Odoo::Test::FakeOdoo;

# A series 18 server with the HR modules and no mass_mailing, no fleet and no product_expiry,
# to drive bin/oom-ops (OOM_OPS_TEST_TRANSPORT=Odoo::Test::ModulesFake) the way hr18 is:
# `list --conf`, `describe --conf` and `matrix --conf` mark what its modules make applicable.

sub context_args {
    my $c = sub { { type => 'char', store => 1 } };
    my $fake = Odoo::Test::FakeOdoo->new(
        series => 18,
        fields => {
            'ir.module.module' => { name => $c->(), state => $c->() },
            'hr.leave'         => { name => $c->(), state => $c->() },
            'crm.lead'         => { name => $c->() },
        },
        records => {
            'ir.module.module' => [ map { { name => $_, state => 'installed' } } qw(base crm sale purchase account stock hr hr_holidays hr_expense) ],
        },
    );
    $fake->no_such_model('fleet.vehicle');
    return ( credential => { login => 'tester', api_key => 'k' }, transport => $fake, retries => [0] );
}

1;
