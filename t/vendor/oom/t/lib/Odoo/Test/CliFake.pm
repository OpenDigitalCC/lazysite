package Odoo::Test::CliFake;

use strict;
use warnings;

use Odoo::Test::FakeOdoo;
use JSON::PP ();

# A small res.partner world for driving bin/oom-ops without a server
# (OOM_OPS_TEST_TRANSPORT=Odoo::Test::CliFake). Every process builds the same
# seed, so a plan made in one command applies in the next. With
# OOM_OPS_TEST_STATE naming a file, what one process wrote is what the
# next one reads, so a revert finds the record an apply made.

my $STATE;
my $FAKE;

sub context_args {
    my $c = sub { { type => 'char', store => 1 } };
    my $fake = Odoo::Test::FakeOdoo->new(
        fields => {
            'res.partner' => {
                ref => $c->(), name => $c->(), email => $c->(),
                category_id => { type => 'many2many', relation => 'res.partner.category', store => 1 },
                active      => { type => 'boolean', store => 1 },
            },
            'res.partner.category' => { name => $c->() },
        },
        records => {
            'res.partner' => [
                { id => 1, ref => 'C001', name => 'ACME Ltd', email => '', category_id => [], active => 1 },
                { id => 2, ref => 'C002', name => 'Same', email => 'same@acme.example', category_id => [], active => 1 },
            ],
            'res.partner.category' => [],
        },
    );
    if ( $STATE = $ENV{OOM_OPS_TEST_STATE} ) {
        $FAKE = $fake;
        if ( open my $fh, '<', $STATE ) {
            local $/;
            my $s = JSON::PP->new->decode(<$fh>);
            $fake->{data}    = $s->{data};
            $fake->{next_id} = $s->{next_id};
        }
    }
    return ( credential => { login => 'tester', api_key => 'k' }, transport => $fake, retries => [0] );
}

END {
    return unless $STATE && $FAKE;
    open my $fh, '>', $STATE or die "$STATE: $!";
    print {$fh} JSON::PP->new->canonical->encode( { data => $FAKE->{data}, next_id => $FAKE->{next_id} } );
    close $fh;
}

1;
