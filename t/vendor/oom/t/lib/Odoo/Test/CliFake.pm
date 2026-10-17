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

# the fake as a web session sees it (a person's session id is the credential): it answers who is calling
{
    package Odoo::Test::CliFake::Session;
    our @ISA = ('Odoo::Test::FakeOdoo');
    sub session_id { "fake-session" }
    sub identity   { { uid => 2, login => "tester" } }
}

sub context_args {
    my ($class, %o) = @_;
    my $c = sub { { type => 'char', store => 1 } };
    my $fake = ( $o{session} ? 'Odoo::Test::CliFake::Session' : 'Odoo::Test::FakeOdoo' )->new(
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
    return ( ( $o{session} ? () : ( credential => { login => 'tester', api_key => 'k' } ) ), transport => $fake, retries => [0] );
}

# what one process wrote is what the next one reads; a resident process (oomd) calls finish after each request
sub finish {
    return unless $STATE && $FAKE;
    # written whole to a name of its own and renamed over the state, so a process reading it at that moment (two
    # oomd workers at once) sees the old file or the new one, never an empty one
    my $tmp = "$STATE.$$.tmp";
    open my $fh, '>', $tmp or die "$tmp: $!";
    print {$fh} JSON::PP->new->canonical->encode( { data => $FAKE->{data}, next_id => $FAKE->{next_id} } );
    close $fh or die "$tmp: $!";
    rename $tmp, $STATE or die "$STATE: $!";
    # a resident process must not write this copy again after another process changed the file
    $FAKE = undef;
}

END { finish() }

1;
