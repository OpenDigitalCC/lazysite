package Odoo::Ops::Wire;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Scalar::Util qw(blessed);

use Odoo::Error;

=head1 NAME

Odoo::Ops::Wire - an answer's objects as plain data and back

=head1 DESCRIPTION

What a client of oomd needs to turn a response into the objects the same call
gives in-process, without loading the service: a plan and a result from their
hashes, and an L<Odoo::Error> from an error hash. L<Odoo::Ops::Service> uses
the same functions for the other direction's partner.

=head2 error_from_wire($hash)

The L<Odoo::Error> a response's C<error> hash describes. An C<internal> fault is
rethrown as the plain text it was.

=head2 from_wire($result)

The result of C<execute> with its plan and result as the objects they were.

=cut

sub error_from_wire ($h) {
    return "$h->{message}\n" if $h->{internal};
    return Odoo::Error->new( kind => $h->{kind}, code => ( ( $h->{code} // '' ) eq ( $h->{kind} // '' ) ? undef : $h->{code} ),
        message => $h->{message}, fix => $h->{fix}, fault_class => $h->{fault_class} );
}

sub from_wire ($class, $res) {
    my %r = %$res;
    # the plan and result classes are loaded only when an answer carries one
    if ( ref $r{plan} eq 'HASH' ) { require Odoo::Ops::Plan }
    if ( ref $r{result} eq 'HASH' ) { require Odoo::Ops::Result }
    $r{plan}   = Odoo::Ops::Plan->from_hash( $r{plan} ) if ref $r{plan} eq 'HASH';
    $r{result} = bless { %{ $r{result} } }, 'Odoo::Ops::Result' if ref $r{result} eq 'HASH' && !blessed $r{result};
    return \%r;
}

1;
