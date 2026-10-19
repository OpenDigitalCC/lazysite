#!/usr/bin/perl
# Run by t/100-json-encoders.t under a chosen encoder (ODOO_OOM_JSON):
#   seal-probe.pl write DIR   makes and saves a sealed plan carrying awkward values, prints its fingerprint
#   seal-probe.pl verify DIR  loads that plan (the seal is checked on load), prints its fingerprint
use v5.36;
use strict;
use warnings;
use lib 'lib';
use Odoo::JSON ();
use Odoo::Ops::Plan;

my ( $mode, $dir ) = @ARGV;
my $file = "$dir/plan.json";

if ( $mode eq 'write' ) {
    my $plan = Odoo::Ops::Plan->new( op => 't.seal', instance => { url => 'https://odoo.example', db => 'd', login => 'l' }, input_count => 2,
        scope => { 'res.partner' => [qw(write)] },
        params => { floats => Odoo::JSON->new->decode('[1.0,-0.0,100.0,1E2,2.50,0.0,-0,1e0]'), name => "caf\x{e9} \x{4e2d}\x{6587} \x{1F600}", list => [ 1, 'two', 3.5, 1e-7, 1e21, 0.1 ] } );
    $plan->add( bucket => 'write', action => 'write', model => 'res.partner', id => 7, key => 'k1',
        vals   => { name => "tab\there \"quote\" back\\slash \x{7f} \x{2028} \x{e9}", active => Odoo::JSON::true, city => Odoo::JSON::false,
                    n => 12, s => '12', f => 3.25, big => 1.5e300, small => 2.5e-12, third => 1 / 3, neg => -7, zero => 0, nothing => undef,
                    "k\x{e9}y" => 1, "Key" => 2, "_k" => 3, nest => { b => [], a => {}, c => [ { z => 1, y => [ 1, [ 2 ] ] } ] } },
        before => { name => 'x', active => 1, city => 0 } );
    $plan->add( bucket => 'write', action => 'hold', model => 'res.partner', id => 8, key => 'k2', reason => "held \x{e9}" );
    $plan->finalize;
    $plan->save($file);
    say $plan->fingerprint;
}
else {
    my $plan = Odoo::Ops::Plan->load($file);    # refuses 'fingerprint' when the seal does not hold
    say $plan->fingerprint;
}
