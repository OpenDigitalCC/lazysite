package My::Overlay::ResPartner;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

# Behaviour overlay fixture for res.partner: business methods live in
# hand-written code like this; field plumbing never does.

sub display_label ($self) {
    return $self->get('name') . '!';
}

# Deliberately shadows the 'name' field accessor: real methods win.
sub name ($self) {
    return uc $self->get('name');
}

1;
