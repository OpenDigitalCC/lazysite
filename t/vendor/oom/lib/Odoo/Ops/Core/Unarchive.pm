package Odoo::Ops::Core::Unarchive;

use strict;
use warnings;
use feature qw(signatures);
no warnings 'experimental::signatures';

use Odoo::Ops::Core::Archive;

use parent 'Odoo::Ops::Core::Archive';

=head1 NAME

Odoo::Ops::Core::Unarchive - bring archived records of any model back

=head1 SYNOPSIS

    oom-ops run core.unarchive --conf ops.conf --set model=res.partner --set record=ref=C001
    oom-ops run core.unarchive --conf ops.conf --set model=product.product --set ids=99,100

=head1 DESCRIPTION

The mirror of L<Odoo::Ops::Core::Archive>: C<action_unarchive> on records
that are inactive, found with archived records included. The parameters
are the same. One change per record in bucket C<unarchive>; the holds are
C<already> (the record is active), C<unknown-record> and
C<no-active-field>. The undo of an unarchive is C<action_archive>.

=cut

sub op_name ($class) { 'core.unarchive' }
sub summary ($class) { 'Plan bringing archived records of any model back through Odoo\'s action_unarchive' }
sub buckets ($class) {
    [ { name => 'unarchive', meaning => 'the archived record is brought back through action_unarchive; undo is action_archive' } ];
}
sub holds ($class) {
    [
        { name => 'already',         meaning => 'the record is active already' },
        { name => 'unknown-record',  meaning => 'no record has that id, or matches that field=value' },
        { name => 'no-active-field', meaning => 'the model has no active field: there is nothing to bring back' },
    ];
}
sub _mode ($class) { { bucket => 'unarchive', method => 'action_unarchive', to => 1, opposite => 'core.archive' } }

1;
