package Odoo::Test::MockTransport;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Scalar::Util qw(blessed);

# Test double for the transport interface: records every call and
# answers from a queue (values, coderefs, or Odoo::Error objects to
# throw) or from a dispatch handler.

sub new ($class, %args) {
    return bless {
        queue   => [],
        calls   => [],
        handler => $args{handler},
    }, $class;
}

sub name ($self) { 'mock' }

sub expect ($self, @results) {
    push @{ $self->{queue} }, @results;
    return $self;
}

sub calls ($self) { $self->{calls} }

sub call ($self, $service, $method, @args) {
    push @{ $self->{calls} }, [ $service, $method, @args ];
    if ($self->{handler}) {
        return $self->{handler}->($service, $method, @args);
    }
    die "mock transport: no queued response for $service.$method\n"
        if !@{ $self->{queue} };
    my $r = shift @{ $self->{queue} };
    die $r if blessed($r) && $r->isa('Odoo::Error');
    return $r->($service, $method, @args) if ref $r eq 'CODE';
    return $r;
}

1;
