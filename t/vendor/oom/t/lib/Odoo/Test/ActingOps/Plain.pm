package Odoo::Test::ActingOps::Plain;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use parent 'Odoo::Ops::Operation';

# A test operation that does not declare acts_for and asks for the person: it must be refused.

sub op_name ($class) { 'acting.plain' }
sub summary ($class) { 'Test: an operation that does not act for a person' }
sub pack ($class) { undef }
sub params ($class) { {} }

sub report ($self) { return { person => $self->person } }

1;
